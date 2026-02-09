# Parameterized K3s Cluster Test Builder
#
# This function generates k3s cluster tests with different network profiles.
# It separates test logic from network configuration, enabling:
#   - Reusable test scripts
#   - Multiple network topologies (simple, vlans, bonding-vlans, dhcp-simple)
#   - Easy addition of new profiles without duplicating test code
#
# DHCP SUPPORT (Plan 019 Phase C):
#   DHCP profiles use a dedicated dhcp-server VM because NixOS test driver
#   VDE switches are NOT accessible from the host. See docs/DHCP-TEST-INFRASTRUCTURE.md
#   for full architectural rationale and upstream research.
#
# USAGE:
#   tests = {
#     k3s-simple = mkK3sClusterTest { networkProfile = "simple"; };
#     k3s-vlans = mkK3sClusterTest { networkProfile = "vlans"; };
#     k3s-bonding-vlans = mkK3sClusterTest { networkProfile = "bonding-vlans"; };
#   };
#
# PARAMETERS:
#   - networkProfile: Name of network profile to use (default: "simple")
#   - testName: Name of the test (default: "k3s-cluster-${networkProfile}")
#   - testScript: Custom test script (default: standard cluster formation test)
#   - extraNodeConfig: Additional config to merge into all nodes
#
# NETWORK PROFILES:
#   Defined in lib/network/profiles/ (unified location for both backends)
#   Each profile provides named parameter presets:
#     - ipAddresses: Per-node IP map (e.g., { server-1 = { cluster = "..."; }; })
#     - interfaces: Interface names (e.g., { cluster = "eth1"; trunk = "eth1"; })
#     - vlanIds: (optional) VLAN IDs for tagged networks
#     - bondConfig: (optional) Bonding configuration
#     - serverApi: Server API endpoint URL
#     - clusterCidr, serviceCidr: K3s network CIDRs
#
# K3S FLAGS:
#   Generated from profile data using lib/k3s/mk-k3s-flags.nix (Plan 012 R5-R6)
#   This eliminates duplication of k3sExtraFlags across profiles.
#
# ARCHITECTURE (Plan 012 Refactoring):
#   Profile presets provide raw parameter data. The unified mk-network-config.nix
#   transforms these parameters into NixOS modules (mkNixOSConfig) or ISAR file
#   content (mkSystemdNetworkdFiles). This eliminates duplication between backends.
#
# TEST SCRIPTS:
#   Shared test script snippets are in tests/lib/test-scripts/
#   The default test script uses mkDefaultClusterTestScript from test-scripts/default.nix

# Additional Parameters:
#   - useSystemdBoot: Enable systemd-boot bootloader (default: false)
#                     When true, uses UEFI firmware + systemd-boot instead of direct kernel boot.
#                     This increases boot time but provides bootloader parity with ISAR tests.
#                     See Plan 019 Phase B for rationale.
#
{ pkgs
, lib
, networkProfile ? "simple"
, testName ? null
, testScript ? null
, extraNodeConfig ? { }
, useSystemdBoot ? false
, ...
}:

let
  # Load network profile preset from unified lib/network/ location
  # Profiles are just named parameter presets, not a separate abstraction layer
  profilePreset = import ../../lib/network/profiles/${networkProfile}.nix { inherit lib; };

  # Load the unified network config generator (Plan 012 architecture)
  # This transforms parameters into NixOS modules, eliminating nodeConfig duplication
  mkNetworkConfig = import ../../lib/network/mk-network-config.nix { inherit lib; };

  # Load the unified k3s flags generator (Plan 012 R5-R6)
  # This transforms profile data into k3s extra flags, eliminating duplication across profiles
  mkK3sFlags = import ../../lib/k3s/mk-k3s-flags.nix { inherit lib; };

  # Extract network parameters from profile preset
  # These are the inputs to mkNixOSConfig - same parameters work for ISAR via mkSystemdNetworkdFiles
  networkParams = {
    nodes = profilePreset.ipAddresses;
    interfaces = profilePreset.interfaces;
    vlanIds = profilePreset.vlanIds or null;
    bondConfig = profilePreset.bondConfig or null;
  };

  # Detect if this is a bonding profile (needs virtualisation.vlans = [ 1 2 ])
  # This is test-specific config, not network config, so handled separately
  hasBonding = networkParams.bondConfig != null;

  # Detect if this is a DHCP profile (needs dhcp-server VM)
  # DHCP profiles have mode = "dhcp" and dhcpServer config
  # See docs/DHCP-TEST-INFRASTRUCTURE.md for architecture details
  isDhcpProfile = (profilePreset.mode or "static") == "dhcp";
  dhcpServerConfig = profilePreset.dhcpServer or null;

  # DHCP MAC Address Computation (Plan 019 Phase C)
  # ==============================================
  # The nixos-test-driver auto-generates MAC addresses using this formula:
  #   qemuNicMac = net: machine: "52:54:00:12:${zeroPad net}:${zeroPad machine}"
  # where 'net' is the VLAN number and 'machine' is the node number.
  #
  # Node numbers are assigned alphabetically. For our DHCP test:
  #   agent-1=1, dhcp-server=2, server-1=3, server-2=4
  #
  # We CANNOT override these MACs via virtualisation.interfaces.<name>.macAddress
  # because that option doesn't exist. Instead, we compute the actual MACs that
  # will be assigned and configure DHCP reservations accordingly.

  # Helper to zero-pad a number to 2 hex digits
  zeroPadHex = n:
    let hex = lib.toHexString n;
    in if builtins.stringLength hex == 1 then "0${hex}" else hex;

  # Compute MAC using nixos-test-driver scheme: 52:54:00:12:${vlan}:${nodeNum}
  computeTestDriverMac = vlan: nodeNum: "52:54:00:12:${zeroPadHex vlan}:${zeroPadHex nodeNum}";

  # All nodes that will exist in this test (sorted alphabetically for node number assignment)
  # Node numbers start at 1 and are assigned in sorted order
  allNodeNames = lib.sort lib.lessThan (
    [ "agent-1" "server-1" "server-2" ] ++ lib.optional isDhcpProfile "dhcp-server"
  );
  nodeNumberMap = lib.listToAttrs (
    lib.imap1 (idx: name: lib.nameValuePair name idx) allNodeNames
  );

  # Compute actual MACs based on VLAN 1 (cluster network) and node numbers
  # These are the MACs the test driver will assign, so DHCP reservations must use these
  computedMacs = lib.mapAttrs (name: _: computeTestDriverMac 1 nodeNumberMap.${name}) nodeNumberMap;

  # Build DHCP reservations using computed MACs + profile IPs
  # This maps profile IP addresses to the actual MACs the test driver will assign
  # Only include reservations for nodes that actually exist in this test
  dhcpReservations = lib.optionalAttrs isDhcpProfile (
    lib.filterAttrs (name: _: builtins.elem name allNodeNames) (
      lib.mapAttrs (name: res: {
        mac = computedMacs.${name} or null;  # null for nodes not in test
        ip = res.ip;
      }) (profilePreset.reservations or { })
    )
  );

  # Load shared test scripts
  testScripts = import ./test-scripts { inherit lib; };

  # Test name defaults to k3s-cluster-<profile>
  actualTestName = if testName != null then testName else "k3s-cluster-${networkProfile}";

  # Common k3s token for test cluster
  testToken = "${actualTestName}-test-token";

  # Common virtualisation settings for all nodes
  # When using systemd-boot/UEFI, disk needs to be larger to accommodate:
  # - EFI System Partition (ESP)
  # - OVMF firmware variable storage
  # - Additional bootloader overhead
  vmConfig = {
    memorySize = 3072; # 3GB RAM per node
    cores = 2;
    diskSize = if useSystemdBoot then 51200 else 20480; # 50GB with UEFI (large ESP + rootfs), 20GB otherwise
  } // lib.optionalAttrs useSystemdBoot {
    # Enable UEFI boot with systemd-boot (Plan 019 Phase B)
    # This provides bootloader parity with ISAR tests at cost of slower boot time.
    # Note: useBootLoader without useEFIBoot may hang on SeaBIOS (issue #200810)
    useBootLoader = true;
    useEFIBoot = true;
  };

  # Boot loader configuration for systemd-boot
  # Applied when useSystemdBoot is true
  #
  # DISK SIZE FIX (2026-02):
  # The underlying issue was that useBootLoader created backing disk images with
  # additionalSpace="0M" hardcoded in qemu-vm.nix, leaving ~0 bytes free after
  # the root filesystem was created. k3s etcd would fail with ENOSPC.
  #
  # FIX: nixpkgs fork (github:timblaktu/nixpkgs/vm-bootloader-disk-size) adds
  # virtualisation.bootDiskAdditionalSpace option (default: "512M") which provides
  # adequate space in the backing image. Upstream PR pending.
  #
  # WORKAROUND (now optional): boot.growPartition runs growpart + resize2fs at
  # boot to expand the root partition into qcow2 overlay space. This is kept as
  # defense-in-depth but no longer strictly required with the nixpkgs fix.
  #
  # TODO: Revert flake.nix nixpkgs input to nixos-25.05 once upstream PR merges.
  # See: docs/nixpkgs-vm-bootloader-disk-limitation.md, Plan 019 B2 investigation
  systemdBootConfig = lib.optionalAttrs useSystemdBoot {
    boot.loader.systemd-boot.enable = true;
    boot.loader.efi.canTouchEfiVariables = true;
    # Defense-in-depth: expand partition at boot if qcow2 overlay is larger
    boot.growPartition = true;
  };

  # Firewall rules for k3s servers
  serverFirewall = {
    enable = true;
    allowedTCPPorts = [
      6443 # Kubernetes API server
      2379 # etcd client
      2380 # etcd peer
      10250 # Kubelet API
      10251 # kube-scheduler
      10252 # kube-controller-manager
    ];
    allowedUDPPorts = [
      8472 # Flannel VXLAN
    ];
  };

  # Firewall rules for k3s agents
  agentFirewall = {
    enable = true;
    allowedTCPPorts = [
      10250 # Kubelet API
    ];
    allowedUDPPorts = [
      8472 # Flannel VXLAN
    ];
  };

  # Base NixOS configuration for all k3s nodes
  baseK3sConfig = { config, pkgs, ... }: {
    imports = [
      ../../backends/nixos/modules/common/base.nix
    ];

    # Essential kernel modules for k3s
    boot.kernelModules = [
      "overlay"
      "br_netfilter"
    ];

    # Essential kernel parameters for k3s networking
    boot.kernel.sysctl = {
      "net.ipv4.ip_forward" = 1;
      "net.bridge.bridge-nf-call-iptables" = 1;
      "fs.inotify.max_user_watches" = 524288;
      "fs.inotify.max_user_instances" = 8192;
    };

    # Enable k3s with airgap images
    # Note: airgapImages renamed to airgap-images in nixpkgs 24.11+
    services.k3s = {
      enable = true;
      images = [ pkgs.k3s.passthru."airgap-images" ];
    };

    # Test-friendly authentication
    # Clear all password options from base.nix/nixosTest to avoid "multiple password options" warning
    users.users.root.hashedPassword = lib.mkForce null;
    users.users.root.hashedPasswordFile = lib.mkForce null;
    users.users.root.password = lib.mkForce "test";
    services.openssh = {
      enable = true;
      settings = {
        PermitRootLogin = lib.mkForce "yes";
        PasswordAuthentication = lib.mkForce true;
      };
    };

    environment.systemPackages = with pkgs; [
      k3s
      kubectl
      jq
      curl
      iproute2
    ];
  };

  # DHCP server node configuration (Plan 019 Phase C)
  # This VM runs dnsmasq to provide DHCP for cluster nodes on DHCP profiles.
  # See docs/DHCP-TEST-INFRASTRUCTURE.md for why we use a service VM approach.
  #
  # NOTE: The DHCP server gets a static IP (192.168.1.254) configured via
  # networking.interfaces, NOT via DHCP. It serves DHCP to cluster nodes.
  # The test driver auto-assigns it a MAC based on its node number.
  mkDhcpServerConfig = lib.optionalAttrs isDhcpProfile {
    virtualisation = {
      memorySize = 512; # Minimal - just runs dnsmasq
      cores = 1;
      vlans = [ 1 ]; # Same VLAN as cluster nodes
      # NOTE: MAC is auto-assigned by test driver based on node number
      # Cannot override via virtualisation.interfaces.<name>.macAddress (option doesn't exist)
    };

    networking = {
      hostName = "dhcp-server";
      # Static IP for DHCP server (it doesn't use DHCP itself)
      # CRITICAL: Use mkForce to override the test driver's auto-assigned IP
      # (test driver assigns 192.168.1.${nodeIndex} based on alphabetical order)
      # Without mkForce, both IPs get merged, and dnsmasq DHCPOFFER to the
      # reserved IP goes to dhcp-server's own interface instead of the client.
      interfaces.eth1.ipv4.addresses = lib.mkForce [{
        address = dhcpServerConfig.ip;
        prefixLength = 24;
      }];
      firewall = {
        allowedUDPPorts = [ 53 67 68 ]; # DNS + DHCP
        allowedTCPPorts = [ 53 ];       # DNS over TCP (for large responses)
      };
    };

    services.dnsmasq = {
      enable = true;
      settings = {
        interface = "eth1";
        bind-interfaces = true;
        # Include netmask explicitly to ensure DHCP clients get proper subnet route
        # Format: start,end,netmask,lease - netmask ensures clients know the subnet scope
        dhcp-range = [ "${dhcpServerConfig.rangeStart},${dhcpServerConfig.rangeEnd},255.255.255.0,${dhcpServerConfig.leaseTime}" ];
        # MAC-based reservations for deterministic IPs
        # Uses computedMacs (based on test driver's MAC scheme) not profile MACs
        dhcp-host = lib.mapAttrsToList (name: res: "${res.mac},${name},${res.ip}") dhcpReservations;
        # DNS entries for cluster nodes (optional, for convenience)
        address = lib.mapAttrsToList (name: res: "/${name}.local/${res.ip}") dhcpReservations;
      };
    };
  };

  # DHCP network configuration for cluster nodes (Plan 019 Phase C)
  # This replaces mkNixOSConfig for DHCP profiles - uses DHCP instead of static IPs
  #
  # CRITICAL: RequiredForOnline = "routable" ensures network-online.target waits
  # for DHCP lease. Without this, k3s starts before IP is assigned and fails
  # with "network is unreachable".
  mkDhcpClientConfig = nodeName: {
    # Use systemd-networkd for DHCP
    networking.useDHCP = false;
    networking.useNetworkd = true;

    # Ensure systemd-networkd-wait-online waits for eth1 specifically
    systemd.network.wait-online = {
      anyInterface = false;  # Wait for ALL required interfaces, not just any one
      timeout = 60;          # Fail fast if DHCP doesn't work
    };

    systemd.network = {
      enable = true;
      networks."20-eth1" = {
        matchConfig.Name = "eth1";
        networkConfig = {
          DHCP = "ipv4";
          IPv6AcceptRA = false;
          LinkLocalAddressing = "no";
        };
        # CRITICAL: Mark this interface as required for online status
        # "routable" means: has an address AND a route to reach other networks
        linkConfig.RequiredForOnline = "routable";
        dhcpV4Config = {
          # Send hostname to DHCP server for DNS
          SendHostname = true;
          # Use hostname from system, not DHCP
          UseHostname = false;
        };
        # CRITICAL FIX (Plan 020 B4): Add explicit on-link route for subnet
        # Without gateway, systemd-networkd doesn't add subnet route automatically
        # This allows inter-node communication on 192.168.1.0/24
        routes = [
          {
            # Note: routeConfig is deprecated - use top-level attributes
            Destination = "192.168.1.0/24";
            Scope = "link";
          }
        ];
      };
    };
  };

  # Build node configuration by merging:
  #   1. Base k3s config
  #   2. Network config: mkNixOSConfig for static, mkDhcpClientConfig for DHCP
  #   3. Test-specific config (virtualisation.vlans for bonding)
  #   4. Systemd-boot config (when useSystemdBoot = true)
  #   5. Extra node config
  #   6. K3s service config
  mkNodeConfig = nodeName: role: lib.recursiveUpdate
    (lib.recursiveUpdate
      (lib.recursiveUpdate
        (lib.recursiveUpdate
          (lib.recursiveUpdate
            {
              imports = [
                baseK3sConfig
              ] ++ lib.optional (!isDhcpProfile) (mkNetworkConfig.mkNixOSConfig networkParams nodeName);
              virtualisation = vmConfig;
              networking.hostName = nodeName;
            }
            # For DHCP profiles, use DHCP client config instead of static
            (lib.optionalAttrs isDhcpProfile (mkDhcpClientConfig nodeName)))
          # For bonding profiles, add extra NIC for bond members
          # This is test-specific (nixosTest virtualisation), not network config
          (lib.optionalAttrs hasBonding {
            virtualisation.vlans = [ 1 2 ];
          }))
        # Systemd-boot configuration (Plan 019 Phase B)
        systemdBootConfig)
      extraNodeConfig)
    {
      services.k3s = {
        role = role;
        tokenFile = pkgs.writeText "k3s-token" testToken;
        # Flags are generated from profile data using shared k3s flags generator (Plan 012 R5-R6)
        extraFlags = lib.filter (x: x != null) ([
          (if role == "server" then "--write-kubeconfig-mode=0644" else null)
          (if role == "server" then "--disable=traefik" else null)
          (if role == "server" then "--disable=servicelb" else null)
          (if role == "server" then "--cluster-cidr=${profilePreset.clusterCidr}" else null)
          (if role == "server" then "--service-cidr=${profilePreset.serviceCidr}" else null)
          "--node-name=${nodeName}"
        ] ++ (mkK3sFlags.mkExtraFlags { profile = profilePreset; inherit nodeName role; }));
      };

      networking.firewall = if role == "server" then serverFirewall else agentFirewall;
    };

  # Default test script using shared snippets
  # Uses mkDefaultClusterTestScript from test-scripts/default.nix
  defaultTestScript = testScripts.mkDefaultClusterTestScript {
    profile = networkProfile;
    nodes = {
      primary = "server_1";
      secondary = "server_2";
      agent = "agent_1";
    } // lib.optionalAttrs isDhcpProfile {
      dhcpServer = "dhcp_server";
    };
    nodeNames = {
      primary = "server-1";
      secondary = "server-2";
      agent = "agent-1";
    };
    # Pass DHCP reservations for DHCP profiles
    dhcpReservations = if isDhcpProfile then dhcpReservations else null;
  };

  # For DHCP profiles, joining nodes (server-2, agent-1) need unlimited restarts
  # because they may start before server-1's API is ready (Plan 020 B4 timing fix)
  # The k3s module already sets Restart="always", we just need to disable rate limiting
  joiningNodeK3sRestartConfig = lib.optionalAttrs isDhcpProfile {
    systemd.services.k3s = {
      # Disable start rate limiting so service keeps retrying until server-1 is ready
      startLimitIntervalSec = 0;
      serviceConfig = {
        # Add delay between retries to avoid hammering server-1
        RestartSec = lib.mkForce "10s";
      };
    };
  };

in
pkgs.testers.runNixOSTest {
  name = actualTestName;

  nodes = {
    # Primary k3s server (cluster init)
    server-1 = lib.recursiveUpdate (mkNodeConfig "server-1" "server") {
      services.k3s.clusterInit = true;
    };

    # Secondary k3s server (joins cluster)
    server-2 = lib.recursiveUpdate
      (lib.recursiveUpdate (mkNodeConfig "server-2" "server") {
        services.k3s.serverAddr = profilePreset.serverApi;
      })
      joiningNodeK3sRestartConfig;

    # k3s agent (worker node)
    agent-1 = lib.recursiveUpdate
      (lib.recursiveUpdate (mkNodeConfig "agent-1" "agent") {
        services.k3s.serverAddr = profilePreset.serverApi;
      })
      joiningNodeK3sRestartConfig;
  } // lib.optionalAttrs isDhcpProfile {
    # DHCP server (only for DHCP profiles)
    # Must start before cluster nodes - see test script boot sequence
    dhcp-server = mkDhcpServerConfig;
  };

  skipTypeCheck = true;

  testScript = if testScript != null then testScript else defaultTestScript;
}
