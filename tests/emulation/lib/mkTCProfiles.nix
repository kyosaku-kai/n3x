# mkTCProfiles.nix - Traffic control profiles generator for network simulation
#
# Generates bash script for applying traffic control (tc) rules to simulate
# network constraints: latency, packet loss, bandwidth limits, jitter.
# Extracted and refactored from vsim/embedded-system-emulator.nix
#
# USAGE:
#   environment.etc."tc-simulate-constraints.sh" = mkTCProfiles { inherit pkgs; };
#
# SCRIPT USAGE:
#   /etc/tc-simulate-constraints.sh [profile]
#
#   Profiles:
#     default     - Remove all constraints (full speed)
#     constrained - Embedded system limits (10-100Mbps + latency)
#     lossy       - Unreliable network (packet loss + jitter)
#     status      - Show current tc configuration
#
# RETURNS:
#   Attribute set suitable for environment.etc.* with mode and text
#
# NOTES:
#   - Script dynamically detects VM interfaces via virsh
#   - Uses tc qdisc for traffic shaping
#   - tbf (token bucket filter) for bandwidth limits
#   - netem (network emulator) for delay/loss/jitter
#   - VMs must be running for interfaces to exist
#
# VM NAME MAPPING:
#   The script operates on n3x inner VMs:
#   - n100-1:   Primary k3s server (control plane leader)
#   - n100-2:   Secondary k3s server (HA control plane)
#   - n100-3:   k3s agent with extra storage disk (x86_64)
#   - jetson-1: k3s agent (aarch64 via QEMU TCG emulation)

{ pkgs, ... }:

{
  mode = "0755";
  text = ''
    #!/usr/bin/env bash
    #
    # Network Constraint Simulation Script
    #
    # Usage: tc-simulate-constraints.sh [profile]
    #
    # Profiles:
    #   default     - Remove all constraints (full speed)
    #   constrained - Embedded system limits (10-100Mbps + latency)
    #   lossy       - Unreliable network (packet loss + jitter)
    #   status      - Show current tc configuration
    #
    # VM Targets:
    #   n100-1   - Primary k3s server (x86_64)
    #   n100-2   - Secondary k3s server (x86_64)
    #   n100-3   - k3s agent (x86_64)
    #   jetson-1 - k3s agent (aarch64, TCG emulation)
    #

    set -euo pipefail

    PROFILE=''${1:-default}

    # Define the VMs to target (n3x inner VMs)
    VMS=(n100-1 n100-2 n100-3 jetson-1)

    # Get active VM interface names from libvirt
    # Returns the vnet interface name(s) for a given VM
    # Note: We avoid pipefail issues by capturing virsh output first,
    # then grepping it separately. Each step has its own error handling.
    get_vm_interfaces() {
      local output
      # Capture virsh output, ignoring errors for non-existent/stopped VMs
      output=$(${pkgs.libvirt}/bin/virsh domiflist "$1" 2>/dev/null) || output=""
      # Extract vnet interface names if any
      if [ -n "$output" ]; then
        echo "$output" | ${pkgs.gnugrep}/bin/grep -oP 'vnet\d+' || true
      fi
    }

    # Apply tc rule to a VM's interface
    # Returns 0 always - missing VMs are not errors, just informational
    apply_tc() {
      local vm="$1"
      local rule="$2"
      local desc="$3"
      local iface
      iface=$(get_vm_interfaces "$vm")
      if [ -n "$iface" ]; then
        ${pkgs.iproute2}/bin/tc qdisc replace dev "$iface" root $rule
        echo "  $vm ($iface): $desc"
      else
        echo "  $vm: not running (skipped)"
      fi
      # Always return 0 - VM not running is informational, not an error
      return 0
    }

    # Clear tc rules from a VM's interface
    clear_tc() {
      local vm="$1"
      local iface
      iface=$(get_vm_interfaces "$vm")
      if [ -n "$iface" ]; then
        ${pkgs.iproute2}/bin/tc qdisc del dev "$iface" root 2>/dev/null || true
        echo "  $vm ($iface): constraints removed"
      else
        echo "  $vm: not running (skipped)"
      fi
    }

    case $PROFILE in
      constrained)
        echo "Applying constrained embedded network profile..."
        echo ""

        # n100-1 (primary server): 100Mbps with 5ms latency (good connection)
        apply_tc "n100-1" "tbf rate 100mbit latency 5ms burst 1540" "100Mbps, 5ms latency"

        # n100-2 (secondary server): 100Mbps with 10ms latency (slightly worse)
        apply_tc "n100-2" "tbf rate 100mbit latency 10ms burst 1540" "100Mbps, 10ms latency"

        # n100-3 (agent/worker): 50Mbps with 20ms latency (constrained worker)
        apply_tc "n100-3" "tbf rate 50mbit latency 20ms burst 1540" "50Mbps, 20ms latency"

        # jetson-1 (ARM64 agent): 10Mbps with 50ms latency (embedded edge device)
        apply_tc "jetson-1" "tbf rate 10mbit latency 50ms burst 1540" "10Mbps, 50ms latency"

        echo ""
        echo "Constrained profile applied"
        ;;

      lossy)
        echo "Applying lossy network profile for resilience testing..."
        echo ""

        # n100-1: Minimal loss (control plane stability)
        apply_tc "n100-1" "netem loss 0.1% delay 5ms 2ms distribution normal" "0.1% loss, 5±2ms delay"

        # n100-2: Moderate loss (test HA failover scenarios)
        apply_tc "n100-2" "netem loss 1% delay 20ms 10ms distribution normal" "1% loss, 20±10ms delay"

        # n100-3: Higher loss (test pod rescheduling)
        apply_tc "n100-3" "netem loss 2% delay 50ms 20ms distribution normal" "2% loss, 50±20ms delay"

        # jetson-1: Edge device loss (test ARM64 agent resilience)
        apply_tc "jetson-1" "netem loss 3% delay 100ms 50ms distribution normal" "3% loss, 100±50ms delay"

        echo ""
        echo "Lossy profile applied"
        ;;

      default|clear)
        echo "Removing all network constraints..."
        echo ""
        for vm in "''${VMS[@]}"; do
          clear_tc "$vm"
        done
        echo ""
        echo "Default profile (no constraints)"
        ;;

      status)
        echo "Current tc configuration:"
        echo ""
        for vm in "''${VMS[@]}"; do
          iface=$(get_vm_interfaces "$vm")
          if [ -n "$iface" ]; then
            echo "  $vm ($iface):"
            ${pkgs.iproute2}/bin/tc qdisc show dev "$iface" 2>/dev/null | ${pkgs.gnused}/bin/sed 's/^/    /'
          else
            echo "  $vm: not running"
          fi
        done
        ;;

      *)
        echo "Unknown profile: $PROFILE"
        echo "Available profiles: default, constrained, lossy, status"
        exit 1
        ;;
    esac
  '';
}
