# Parameterized K3s Cluster Test Builder
#
# This function generates k3s cluster tests with different network profiles.
# It separates test logic from network configuration, enabling:
#   - Reusable test scripts
#   - Multiple network topologies (simple, vlans, bonding-vlans)
#   - Easy addition of new profiles without duplicating test code
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
#   Defined in tests/lib/network-profiles/
#   Each profile provides:
#     - nodeConfig: Function returning per-node network configuration
#     - k3sExtraFlags: Function returning k3s-specific flags for node
#     - serverApi: Server API endpoint URL
#     - clusterCidr, serviceCidr: K3s network CIDRs
#
# TEST SCRIPTS:
#   Shared test script snippets are in tests/lib/test-scripts/
#   The default test script uses mkDefaultClusterTestScript from test-scripts/default.nix

{ pkgs
, lib
, networkProfile ? "simple"
, testName ? null
, testScript ? null
, extraNodeConfig ? { }
, ...
}:

let
  # Load network profile
  profile = import ./network-profiles/${networkProfile}.nix { inherit lib; };

  # Load shared test scripts
  testScripts = import ./test-scripts { inherit lib; };

  # Test name defaults to k3s-cluster-<profile>
  actualTestName = if testName != null then testName else "k3s-cluster-${networkProfile}";

  # Common k3s token for test cluster
  testToken = "${actualTestName}-test-token";

  # Common virtualisation settings for all nodes
  vmConfig = {
    memorySize = 3072; # 3GB RAM per node
    cores = 2;
    diskSize = 20480; # 20GB disk
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
    services.k3s = {
      enable = true;
      images = [ pkgs.k3s.passthru.airgapImages ];
    };

    # Test-friendly authentication
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

  # Build node configuration by merging:
  #   1. Base k3s config
  #   2. Network profile config
  #   3. Extra node config
  mkNodeConfig = nodeName: role: lib.recursiveUpdate
    (lib.recursiveUpdate
      {
        imports = [ baseK3sConfig (profile.nodeConfig nodeName) ];
        virtualisation = vmConfig;
        networking.hostName = nodeName;
      }
      extraNodeConfig)
    {
      services.k3s = {
        role = role;
        tokenFile = pkgs.writeText "k3s-token" testToken;
        extraFlags = lib.filter (x: x != null) ([
          (if role == "server" then "--write-kubeconfig-mode=0644" else null)
          (if role == "server" then "--disable=traefik" else null)
          (if role == "server" then "--disable=servicelb" else null)
          (if role == "server" then "--cluster-cidr=${profile.clusterCidr}" else null)
          (if role == "server" then "--service-cidr=${profile.serviceCidr}" else null)
          "--node-name=${nodeName}"
        ] ++ (profile.k3sExtraFlags nodeName));
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
    };
    nodeNames = {
      primary = "server-1";
      secondary = "server-2";
      agent = "agent-1";
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
    server-2 = lib.recursiveUpdate (mkNodeConfig "server-2" "server") {
      services.k3s.serverAddr = profile.serverApi;
    };

    # k3s agent (worker node)
    agent-1 = lib.recursiveUpdate (mkNodeConfig "agent-1" "agent") {
      services.k3s.serverAddr = profile.serverApi;
    };
  };

  skipTypeCheck = true;

  testScript = if testScript != null then testScript else defaultTestScript;
}
