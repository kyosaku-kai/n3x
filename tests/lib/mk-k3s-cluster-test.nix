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
# Experimental CI Tolerance Controls (Plan 032):
#   These controls improve test reliability under I/O-constrained CI runners where
#   4 concurrent QEMU VMs cause etcd WAL write starvation and leader election storms.
#   Both are disabled by default and harmless when enabled on fast machines.
#
#   - etcdHeartbeatInterval: etcd heartbeat interval in ms (default: null = etcd default 100ms)
#                            Recommended CI value: 500 (5x default, per etcd tuning guide)
#   - etcdElectionTimeout: etcd election timeout in ms (default: null = etcd default 1000ms)
#                          Must be 5-10x heartbeat. Recommended CI value: 5000
#   - sequentialJoin: When true, joining nodes (server-2, agent-1) do NOT auto-start k3s.
#                     The test script starts k3s on each joining node one at a time, waiting
#                     for etcd health between joins. This eliminates the concurrent member-add
#                     I/O storm that causes etcd starvation under CI resource pressure.
#                     (default: false)
#   - shutdownDhcpAfterLeases: When true, shut down the DHCP server VM after lease verification.
#                              Frees 512MB RAM and removes one QEMU VM from I/O contention.
#                              Safe because DHCP leases are 12h, test completes in <30 min.
#                              Only applies to DHCP profiles. (default: false)
#   - etcdTmpfs: When true, mount tmpfs at etcd data dir on server nodes. Eliminates
#                etcd WAL I/O contention entirely by keeping WAL in RAM. Changes test
#                semantics (production etcd writes to disk) but reasonable since we test
#                cluster formation, not etcd durability. (default: false)
#
# QEMU-Level Tuning — Evaluated and Rejected (Plan 032 T5.7.4):
#   The following QEMU tuning parameters were investigated and found unnecessary:
#
#   - qemuDiskTmpfs (redirect qcow2 overlays to tmpfs): REJECTED. The NixOS test
#     driver places overlays in tmp_dir/vm-state-{name}/ (controlled by XDG_RUNTIME_DIR
#     or /tmp). etcdTmpfs already removes the hottest write path (etcd WAL fsyncs) from
#     the overlay entirely — etcd writes go to guest RAM, never reaching the host qcow2.
#     Remaining overlay writes (journals, boot ops) are sequential and not contention-sensitive.
#
#   - qemuMemory (override per-VM RAM): REJECTED. Standard GitHub runners provide 16 GB
#     RAM. With 3 VMs × 3072 MB = 9 GB + host overhead, ~3-4 GB headroom remains.
#     No evidence of memory pressure. Reducing VM RAM risks k3s OOM.
#
#   - qemuVirtioNetQueues (virtio-net multi-queue): REJECTED. Inter-VM networking uses
#     VDE switches (userspace, single-threaded Unix domain sockets). The VDE switch is the
#     throughput bottleneck, not the virtio ring buffer. Multi-queue adds at most 1 extra
#     queue with 2 vCPUs per VM — negligible. Would require fragile override of
#     virtualisation.qemu.networkingOptions.
#
#   - qemuCpuCores (override vCPU count): REJECTED. 3 VMs × 2 cores = 6 vCPU on a
#     4 vCPU runner is well-handled by the Linux CFS scheduler. Reducing to 1 core
#     would halve k3s startup CPU budget, likely increasing total test time. Sequential
#     VM boot (if needed) is a better lever for peak CPU contention.
#
{ pkgs
, lib
, networkProfile ? "simple"
, testName ? null
, testScript ? null
, extraNodeConfig ? { }
, useSystemdBoot ? false
, etcdHeartbeatInterval ? null
, etcdElectionTimeout ? null
, sequentialJoin ? false
, shutdownDhcpAfterLeases ? false
, etcdTmpfs ? false
  # Network readiness gate (T5.7.1): seconds to wait for cluster interface IP
  # before k3s starts. null = disabled (default). When set, adds an ExecStartPre
  # script to k3s.service that polls the cluster interface for an IPv4 address.
  # Recommended: 120 for bonding-vlans, 60 for vlans/dhcp-simple, null for simple.
, networkReadyTimeout ? null
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

  # Network readiness gate (T5.7.1)
  # Determines which interface to check based on network profile:
  #   simple/dhcp-simple: eth1 (flat cluster network)
  #   vlans:              eth1.200 (cluster VLAN)
  #   bonding-vlans:      bond0.200 (cluster VLAN on bond)
  clusterIface =
    if networkProfile == "bonding-vlans" then "bond0.200"
    else if networkProfile == "vlans" then "eth1.200"
    else "eth1";

  # Shell script that polls for IPv4 address on the cluster interface.
  # For bonding profiles, also checks bond0 carrier first.
  # Runs as ExecStartPre on k3s.service — blocks k3s startup until ready.
  ip = "${pkgs.iproute2}/bin/ip";
  grep = "${pkgs.gnugrep}/bin/grep";

  waitForNetworkScript = pkgs.writeShellScript "wait-for-network" ''
    IFACE="${clusterIface}"
    TIMEOUT="${toString networkReadyTimeout}"
    INTERVAL=2
    ELAPSED=0

    ${lib.optionalString hasBonding ''
    # Wait for bond0 carrier (underlying bond must be active before VLAN works)
    echo "wait-for-network: waiting for bond0 carrier..."
    while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
      CARRIER=$(cat /sys/class/net/bond0/carrier 2>/dev/null || echo 0)
      if [ "$CARRIER" = "1" ]; then
        echo "wait-for-network: bond0 carrier UP after ''${ELAPSED}s"
        break
      fi
      sleep "$INTERVAL"
      ELAPSED=$((ELAPSED + INTERVAL))
    done
    if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
      echo "wait-for-network: TIMEOUT waiting for bond0 carrier after ''${TIMEOUT}s"
      exit 1
    fi
    ''}

    echo "wait-for-network: waiting for IPv4 address on $IFACE..."
    while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
      if ${ip} -4 addr show "$IFACE" 2>/dev/null | ${grep} -q 'inet '; then
        echo "wait-for-network: $IFACE has IPv4 address after ''${ELAPSED}s"
        exit 0
      fi
      sleep "$INTERVAL"
      ELAPSED=$((ELAPSED + INTERVAL))
    done
    echo "wait-for-network: TIMEOUT waiting for $IFACE IPv4 after ''${TIMEOUT}s"
    exit 1
  '';

  # Config overlay that adds the network readiness ExecStartPre to k3s.service
  networkReadyConfig = lib.optionalAttrs (networkReadyTimeout != null) {
    systemd.services.k3s.serviceConfig.ExecStartPre = lib.mkBefore [
      "+${waitForNetworkScript}"
    ];
  };

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
      lib.mapAttrs
        (name: res: {
          mac = computedMacs.${name} or null; # null for nodes not in test
          ip = res.ip;
        })
        (profilePreset.reservations or { })
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
  # See: docs/nixos-vm-bootloader-disk-limitation.md, Plan 019 B2 investigation
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
        allowedTCPPorts = [ 53 ]; # DNS over TCP (for large responses)
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
      anyInterface = false; # Wait for ALL required interfaces, not just any one
      timeout = 60; # Fail fast if DHCP doesn't work
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
        ]
        ++ (mkK3sFlags.mkExtraFlags { profile = profilePreset; inherit nodeName role; })
        # Experimental: etcd timeout tuning for CI I/O tolerance (Plan 032)
        ++ lib.optionals (role == "server" && etcdHeartbeatInterval != null) [
          "--etcd-arg=heartbeat-interval=${toString etcdHeartbeatInterval}"
        ]
        ++ lib.optionals (role == "server" && etcdElectionTimeout != null) [
          "--etcd-arg=election-timeout=${toString etcdElectionTimeout}"
        ]);
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
    # Forward experimental controls to test script (Plan 032)
    inherit sequentialJoin shutdownDhcpAfterLeases;
  };

  # Restart resilience for ALL k3s nodes (T5.7.2, extends Plan 020 B4).
  # All VMs boot simultaneously but k3s services start in parallel — any node
  # may fail transiently under CI I/O pressure (etcd WAL write timeout, API
  # server not ready, port binding race). Applied to ALL nodes including
  # server-1 (init node), which previously used systemd defaults that would
  # enter permanent "failed" state after 5 rapid failures.
  #
  # Uses systemd v254+ native backoff (RestartSteps + RestartMaxDelaySec)
  # to ramp restart delays from 5s → 30s over 5 attempts, then cap at 30s.
  # Restart sequence: 5s, 10s, 15s, 20s, 25s, 30s, 30s, ...
  k3sRestartConfig = {
    systemd.services.k3s = {
      startLimitIntervalSec = 0; # Unlimited restarts (no rate limiting)
      serviceConfig = {
        RestartSec = lib.mkForce "5s"; # Initial delay (matches upstream default)
        RestartMaxDelaySec = "30s"; # Cap delay at 30s
        RestartSteps = 5; # Ramp from 5s → 30s over 5 restarts
      };
    };
  };

  # Experimental: Sequential join - disable k3s auto-start on joining nodes (Plan 032)
  # The test script will start k3s manually, one node at a time, with etcd health
  # gates between joins. This eliminates the concurrent member-add I/O storm.
  joiningNodeSequentialConfig = lib.optionalAttrs sequentialJoin {
    systemd.services.k3s.wantedBy = lib.mkForce [ ];
  };

  # Experimental: tmpfs for etcd data dir on server nodes (Plan 032)
  # Eliminates etcd WAL I/O contention by keeping all etcd data in RAM.
  # k3s stores etcd data at /var/lib/rancher/k3s/server/db/etcd/.
  # We mount tmpfs at the parent /var/lib/rancher/k3s/server/db/ to cover
  # both WAL and snap directories. 512M is ample for a 3-node test cluster.
  etcdTmpfsConfig = lib.optionalAttrs etcdTmpfs {
    fileSystems."/var/lib/rancher/k3s/server/db" = {
      device = "tmpfs";
      fsType = "tmpfs";
      options = [ "size=512M" "mode=0700" ];
    };
  };

in
pkgs.testers.runNixOSTest {
  name = actualTestName;

  nodes = {
    # Primary k3s server (cluster init)
    server-1 = lib.recursiveUpdate
      (lib.recursiveUpdate
        (lib.recursiveUpdate
          (lib.recursiveUpdate (mkNodeConfig "server-1" "server") {
            services.k3s.clusterInit = true;
          })
          k3sRestartConfig)
        etcdTmpfsConfig)
      networkReadyConfig;

    # Secondary k3s server (joins cluster)
    server-2 = lib.recursiveUpdate
      (lib.recursiveUpdate
        (lib.recursiveUpdate
          (lib.recursiveUpdate
            (lib.recursiveUpdate (mkNodeConfig "server-2" "server") {
              services.k3s.serverAddr = profilePreset.serverApi;
            })
            k3sRestartConfig)
          joiningNodeSequentialConfig)
        etcdTmpfsConfig)
      networkReadyConfig;

    # k3s agent (worker node)
    agent-1 = lib.recursiveUpdate
      (lib.recursiveUpdate
        (lib.recursiveUpdate
          (lib.recursiveUpdate (mkNodeConfig "agent-1" "agent") {
            services.k3s.serverAddr = profilePreset.serverApi;
          })
          k3sRestartConfig)
        joiningNodeSequentialConfig)
      networkReadyConfig;
  } // lib.optionalAttrs isDhcpProfile {
    # DHCP server (only for DHCP profiles)
    # Must start before cluster nodes - see test script boot sequence
    dhcp-server = mkDhcpServerConfig;
  };

  skipTypeCheck = true;

  testScript = if testScript != null then testScript else defaultTestScript;
}
