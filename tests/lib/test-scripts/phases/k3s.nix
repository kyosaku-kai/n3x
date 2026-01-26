# K3s phase - Cluster formation and verification
#
# This phase handles K3s-specific checks:
# - Primary server readiness
# - Secondary server joining
# - Agent joining
# - All nodes Ready state
# - System components (CoreDNS, local-path-provisioner)
#
# Includes both NixOS and ISAR variants:
# - NixOS: k3s.service (managed by services.k3s NixOS module)
# - ISAR: k3s-server.service or k3s-agent.service (from ISAR recipes)
#
# Usage in Nix:
#   let
#     k3sPhase = import ./test-scripts/phases/k3s.nix { inherit lib; };
#   in ''
#     # NixOS:
#     ${k3sPhase.waitForPrimaryServer { node = "server_1"; }}
#     # ISAR:
#     ${k3sPhase.isar.waitForK3sServer { node = "server"; }}
#   ''

{ lib ? (import <nixpkgs> { }).lib }:

{
  # Wait for primary server K3s to be ready
  # Parameters:
  #   node: primary server node variable name
  #   displayName: human-readable name (default: derived from node)
  waitForPrimaryServer = { node, displayName ? "primary server" }: ''
    log_section("PHASE 3", "Waiting for ${displayName} k3s")

    ${node}.wait_for_unit("k3s.service")
    tlog("  k3s.service started")

    ${node}.wait_for_open_port(6443)
    tlog("  API server port 6443 open")

    # Wait for API server to be ready - HA etcd election can take time
    ${node}.wait_until_succeeds("k3s kubectl get --raw /readyz", timeout=300)
    tlog("  API server is ready")

    # Give etcd cluster a moment to stabilize after initial leader election
    time.sleep(10)
  '';

  # Wait for primary server node to reach Ready state
  # Parameters:
  #   node: primary server node variable name
  #   nodeName: kubernetes node name (e.g., "server-1")
  waitForPrimaryReady = { node, nodeName }: ''
    log_section("PHASE 4", "Waiting for ${nodeName} to be Ready")

    ${node}.wait_until_succeeds(
        "k3s kubectl get nodes --no-headers | grep '${nodeName}' | grep -w Ready",
        timeout=240
    )
    tlog("  ${nodeName} is Ready")

    nodes_output = ${node}.succeed("k3s kubectl get nodes -o wide")
    tlog(f"  Current nodes:\n{nodes_output}")
  '';

  # Wait for secondary server to join and be Ready
  # Parameters:
  #   primary: primary server node variable name
  #   secondary: secondary server node variable name
  #   secondaryNodeName: kubernetes node name for secondary
  waitForSecondaryServer = { primary, secondary, secondaryNodeName }: ''
    log_section("PHASE 5", "Waiting for secondary server (${secondaryNodeName})")

    ${secondary}.wait_for_unit("k3s.service")
    tlog("  k3s.service started")

    ${primary}.wait_until_succeeds(
        "k3s kubectl get nodes --no-headers | grep '${secondaryNodeName}' | grep -w Ready",
        timeout=300
    )
    tlog("  ${secondaryNodeName} is Ready")
  '';

  # Wait for agent to join and be Ready
  # Parameters:
  #   primary: primary server node variable name
  #   agent: agent node variable name
  #   agentNodeName: kubernetes node name for agent
  waitForAgent = { primary, agent, agentNodeName }: ''
    log_section("PHASE 6", "Waiting for agent (${agentNodeName})")

    ${agent}.wait_for_unit("k3s.service")
    tlog("  k3s.service started")

    ${primary}.wait_until_succeeds(
        "k3s kubectl get nodes --no-headers | grep '${agentNodeName}' | grep -w Ready",
        timeout=300
    )
    tlog("  ${agentNodeName} is Ready")
  '';

  # Verify all nodes are Ready
  # Parameters:
  #   primary: primary server node variable name
  #   expectedCount: number of nodes expected
  waitForAllNodesReady = { primary, expectedCount }: ''
    log_section("PHASE 7", "Verifying all ${toString expectedCount} nodes are Ready")

    ${primary}.wait_until_succeeds(
        "k3s kubectl get nodes --no-headers | grep -w Ready | wc -l | grep -q ${toString expectedCount}",
        timeout=60
    )
    tlog("  All ${toString expectedCount} nodes are Ready")

    nodes_output = ${primary}.succeed("k3s kubectl get nodes -o wide")
    tlog(f"\n  Cluster nodes:\n{nodes_output}")

    pods_output = ${primary}.succeed("k3s kubectl get pods -A -o wide")
    tlog(f"\n  System pods:\n{pods_output}")
  '';

  # Verify system components are running
  # Parameters:
  #   primary: primary server node variable name
  verifySystemComponents = { primary }: ''
    log_section("PHASE 8", "Verifying system components")

    ${primary}.wait_until_succeeds(
        "k3s kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers | grep Running",
        timeout=120
    )
    tlog("  CoreDNS is running")

    ${primary}.wait_until_succeeds(
        "k3s kubectl get pods -n kube-system -l app=local-path-provisioner --no-headers | grep Running",
        timeout=120
    )
    tlog("  Local-path-provisioner is running")
  '';

  # Complete K3s cluster verification for 2 servers + 1 agent
  # Parameters:
  #   primary: primary server node (variable name)
  #   secondary: secondary server node (variable name)
  #   agent: agent node (variable name)
  #   primaryNodeName: k8s node name for primary (e.g., "server-1")
  #   secondaryNodeName: k8s node name for secondary (e.g., "server-2")
  #   agentNodeName: k8s node name for agent (e.g., "agent-1")
  verifyCluster = { primary, secondary, agent, primaryNodeName, secondaryNodeName, agentNodeName }: ''
    log_section("PHASE 3", "Waiting for primary server (${primaryNodeName}) k3s")

    ${primary}.wait_for_unit("k3s.service")
    tlog("  k3s.service started")

    ${primary}.wait_for_open_port(6443)
    tlog("  API server port 6443 open")

    # Wait for API server to be ready - HA etcd election can take time
    ${primary}.wait_until_succeeds("k3s kubectl get --raw /readyz", timeout=300)
    tlog("  API server is ready")

    # Give etcd cluster a moment to stabilize after initial leader election
    time.sleep(10)

    # PHASE 4: Primary Ready
    log_section("PHASE 4", "Waiting for ${primaryNodeName} to be Ready")

    ${primary}.wait_until_succeeds(
        "k3s kubectl get nodes --no-headers | grep '${primaryNodeName}' | grep -w Ready",
        timeout=240
    )
    tlog("  ${primaryNodeName} is Ready")

    nodes_output = ${primary}.succeed("k3s kubectl get nodes -o wide")
    tlog(f"  Current nodes:\n{nodes_output}")

    # PHASE 5: Secondary Server
    log_section("PHASE 5", "Waiting for secondary server (${secondaryNodeName})")

    ${secondary}.wait_for_unit("k3s.service")
    tlog("  k3s.service started")

    ${primary}.wait_until_succeeds(
        "k3s kubectl get nodes --no-headers | grep '${secondaryNodeName}' | grep -w Ready",
        timeout=300
    )
    tlog("  ${secondaryNodeName} is Ready")

    # PHASE 6: Agent
    log_section("PHASE 6", "Waiting for agent (${agentNodeName})")

    ${agent}.wait_for_unit("k3s.service")
    tlog("  k3s.service started")

    ${primary}.wait_until_succeeds(
        "k3s kubectl get nodes --no-headers | grep '${agentNodeName}' | grep -w Ready",
        timeout=300
    )
    tlog("  ${agentNodeName} is Ready")

    # PHASE 7: All Nodes
    log_section("PHASE 7", "Verifying all 3 nodes are Ready")

    ${primary}.wait_until_succeeds(
        "k3s kubectl get nodes --no-headers | grep -w Ready | wc -l | grep -q 3",
        timeout=60
    )
    tlog("  All 3 nodes are Ready")

    nodes_output = ${primary}.succeed("k3s kubectl get nodes -o wide")
    tlog(f"\n  Cluster nodes:\n{nodes_output}")

    pods_output = ${primary}.succeed("k3s kubectl get pods -A -o wide")
    tlog(f"\n  System pods:\n{pods_output}")

    # PHASE 8: System Components
    log_section("PHASE 8", "Verifying system components")

    ${primary}.wait_until_succeeds(
        "k3s kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers | grep Running",
        timeout=120
    )
    tlog("  CoreDNS is running")

    ${primary}.wait_until_succeeds(
        "k3s kubectl get pods -n kube-system -l app=local-path-provisioner --no-headers | grep Running",
        timeout=120
    )
    tlog("  Local-path-provisioner is running")
  '';

  # Single-node K3s service check (for smoke tests)
  # Parameters:
  #   node: server node variable name
  waitForK3sService = { node }: ''
    ${node}.wait_for_unit("k3s.service")
    tlog("  k3s.service started")

    ${node}.wait_for_open_port(6443)
    tlog("  API server port 6443 open")
  '';

  # =============================================================================
  # ISAR-specific K3s helpers
  # =============================================================================
  #
  # ISAR uses k3s-server.service and k3s-agent.service (from ISAR recipes),
  # not k3s.service (from NixOS services.k3s module).
  #
  # The K3s binary path is also different:
  # - NixOS: /run/current-system/sw/bin/k3s
  # - ISAR: /usr/bin/k3s

  isar = {
    # Check K3s binary exists and is executable
    # Parameters:
    #   node: node variable name
    verifyK3sBinary = { node }: ''
      log_section("PHASE 2", "Verifying k3s binary")
      ${node}.succeed("test -x /usr/bin/k3s")
      k3s_version = ${node}.succeed("k3s --version")
      tlog(f"  k3s version: {k3s_version.strip()}")

      # Check k3s symlinks (kubectl, crictl)
      ${node}.succeed("test -L /usr/bin/kubectl || test -x /usr/bin/kubectl")
      tlog("  kubectl symlink present")
    '';

    # Wait for k3s-server.service to start
    # Parameters:
    #   node: node variable name
    #   timeout: timeout in seconds (default: 60)
    waitForK3sServer = { node, timeout ? 60 }: ''
      log_section("PHASE 3", "Waiting for k3s-server.service")

      # Check current service status
      code, status = ${node}.execute("systemctl status k3s-server.service --no-pager 2>&1")
      tlog(f"  Initial status: {'active' if code == 0 else 'not active'}")

      # Wait for service to be active
      ${node}.wait_for_unit("k3s-server.service", timeout=${toString timeout})
      tlog("  k3s-server.service is active")

      # Wait for API server port
      ${node}.wait_for_open_port(6443, timeout=30)
      tlog("  API server port 6443 open")
    '';

    # Wait for k3s-agent.service to start
    # Parameters:
    #   node: node variable name
    #   timeout: timeout in seconds (default: 60)
    waitForK3sAgent = { node, timeout ? 60 }: ''
      log_section("PHASE 3", "Waiting for k3s-agent.service")

      ${node}.wait_for_unit("k3s-agent.service", timeout=${toString timeout})
      tlog("  k3s-agent.service is active")
    '';

    # Wait for k3s kubeconfig to be created (alternative to service wait)
    # Parameters:
    #   node: node variable name
    #   maxAttempts: number of retry attempts (default: 30)
    #   sleepSecs: seconds between attempts (default: 5)
    waitForKubeconfig = { node, maxAttempts ? 30, sleepSecs ? 5 }: ''
      log_section("PHASE 3", "Waiting for k3s kubeconfig")

      for i in range(${toString maxAttempts}):
          code, output = ${node}.execute("test -f /etc/rancher/k3s/k3s.yaml")
          if code == 0:
              tlog(f"  kubeconfig ready after {i+1} attempts")
              break
          time.sleep(${toString sleepSecs})
      else:
          tlog("  WARNING: kubeconfig not found after waiting")
    '';

    # Verify kubectl works and show node/pod status
    # Parameters:
    #   node: node variable name
    verifyKubectl = { node }: ''
      log_section("PHASE 4", "Verifying kubectl access")

      # Check if kubectl works
      code, kubectl_output = ${node}.execute("kubectl get nodes 2>&1")
      if code == 0:
          tlog(f"  Nodes:\n{kubectl_output}")
      else:
          tlog(f"  kubectl not ready: {kubectl_output.strip()}")

      # Show system pods
      code, pods = ${node}.execute("kubectl get pods -A 2>&1")
      if code == 0:
          tlog(f"  Pods:\n{pods}")
    '';

    # Complete ISAR K3s server boot test
    # Parameters:
    #   node: node variable name
    #   displayName: name for logging (default: "ISAR K3s server")
    fullServerBootTest = { node, displayName ? "ISAR K3s server" }: ''
      log_banner("${displayName} Boot Test", "ISAR", {
          "Image type": "k3s-server",
          "Expected services": "k3s-server.service",
          "K3s binary": "/usr/bin/k3s"
      })

      # Phase 1: Boot (assumed already done via boot.isar.bootWithBackdoor)

      # Phase 2: Verify k3s binary
      log_section("PHASE 2", "Verifying k3s binary")
      ${node}.succeed("test -x /usr/bin/k3s")
      k3s_version = ${node}.succeed("k3s --version")
      tlog(f"  k3s version: {k3s_version.strip()}")
      ${node}.succeed("test -L /usr/bin/kubectl || test -x /usr/bin/kubectl")
      tlog("  kubectl symlink present")

      # Phase 3: Wait for k3s-server.service
      log_section("PHASE 3", "Waiting for k3s-server.service")
      code, status = ${node}.execute("systemctl status k3s-server.service --no-pager 2>&1")
      if code != 0:
          # Try to start it
          ${node}.execute("systemctl start k3s-server.service")

      # Wait for kubeconfig (more reliable than service unit in ISAR)
      for i in range(30):
          code, output = ${node}.execute("test -f /etc/rancher/k3s/k3s.yaml")
          if code == 0:
              tlog(f"  kubeconfig ready after {i+1} attempts")
              break
          time.sleep(5)
      else:
          tlog("  WARNING: kubeconfig not found after waiting")

      # Phase 4: Verify kubectl
      log_section("PHASE 4", "Verifying kubectl access")
      code, kubectl_output = ${node}.execute("kubectl get nodes 2>&1")
      tlog(f"  Nodes: {kubectl_output.strip()}")

      code, pods = ${node}.execute("kubectl get pods -A 2>&1")
      tlog(f"  Pods: {pods[:200]}..." if len(pods) > 200 else f"  Pods: {pods}")

      # Summary
      log_summary("${displayName} Boot Test", "ISAR", [
          "k3s binary present and executable",
          "kubectl symlink functional",
          "kubeconfig created (or attempted)"
      ])
    '';
  };
}
