# =============================================================================
# mk-network-config.nix - Unified network configuration generator
# =============================================================================
#
# This module transforms network parameters into backend-specific configurations.
# It eliminates duplication between NixOS module syntax and ISAR file generation.
#
# DESIGN PRINCIPLE (Architecture Review 2026-01-27):
#   - NO "profile detection" - callers provide parameters, functions transform them
#   - Profiles are just named parameter presets, not a separate abstraction layer
#   - Same parameters → same output, regardless of which "profile" they came from
#
# USAGE:
#   mkNetworkConfig = import ./mk-network-config.nix { inherit lib; };
#
#   # For NixOS backend (test VMs, nixosConfigurations, any NixOS image)
#   nodeModule = mkNetworkConfig.mkNixOSConfig {
#     nodes = { "server-1" = { cluster = "192.168.200.1"; }; };
#     interfaces = { cluster = "eth1.200"; trunk = "eth1"; };
#     vlanIds = { cluster = 200; };
#   } "server-1";
#
#   # For ISAR backend (systemd-networkd file content)
#   files = mkNetworkConfig.mkSystemdNetworkdFiles {
#     nodes = { "server-1" = { cluster = "192.168.200.1"; }; };
#     interfaces = { cluster = "eth1.200"; trunk = "eth1"; };
#     vlanIds = { cluster = 200; };
#   } "server-1";
#
# =============================================================================

{ lib }:

let
  # Import existing ISAR file generator for backward compatibility
  mkSystemdNetworkd = import ./mk-systemd-networkd.nix { inherit lib; };

in
rec {
  # Re-export existing ISAR functions for backward compatibility
  inherit (mkSystemdNetworkd) generateProfileFiles generateAllNodeFiles;

  # ===========================================================================
  # mkNixOSConfig - Generate NixOS module from network parameters
  # ===========================================================================
  #
  # SIGNATURE:
  #   { nodes, interfaces, vlanIds?, bondConfig? } -> nodeName -> NixOS module
  #
  # PARAMETERS:
  #   nodes      - Per-node IP map: { "server-1" = { cluster = "192.168.200.1"; storage = "..."; }; ... }
  #   interfaces - Interface name map: { cluster = "eth1.200"; storage = "eth1.100"; trunk = "eth1"; }
  #   vlanIds    - VLAN ID map: { cluster = 200; storage = 100; } or null for simple network
  #   bondConfig - Bonding params: { members = ["eth1" "eth2"]; mode = "active-backup"; ... } or null
  #
  # OUTPUT:
  #   NixOS module function for ALL NixOS-backend systems:
  #     - Test VMs (nixosTest)
  #     - Physical deployments (nixosConfigurations)
  #     - Any NixOS-based image
  #
  # DOES NOT INCLUDE (separate concerns):
  #   - Shell aliases (add in test/deployment config if needed)
  #   - K3s flags (handled by separate mk-k3s-flags.nix)
  #   - virtualisation.vlans (test-specific, not network config)
  #
  mkNixOSConfig = { nodes, interfaces, vlanIds ? null, bondConfig ? null }: nodeName:
    { config, pkgs, lib, ... }:
    let
      nodeIPs = nodes.${nodeName} or { };
      hasVlans = vlanIds != null;
      hasBond = bondConfig != null;

      # Extract interface names
      clusterIface = interfaces.cluster or "eth1";
      storageIface = interfaces.storage or null;
      trunkIface = interfaces.trunk or (if hasBond then "bond0" else "eth1");

      # Extract VLAN IDs if present
      clusterVlanId = if vlanIds != null then vlanIds.cluster or 200 else null;
      storageVlanId = if vlanIds != null then vlanIds.storage or null else null;

      # Extract bond config if present
      bondMembers = if bondConfig != null then bondConfig.members or [ "eth1" "eth2" ] else [ ];
      bondMode = if bondConfig != null then bondConfig.mode or "active-backup" else null;
      bondMiimon = if bondConfig != null then bondConfig.miimon or 100 else null;
      bondPrimary = if bondConfig != null then bondConfig.primary or (builtins.head bondMembers) else null;

      # Common network config (DHCP off, no IPv6)
      commonNetworkConfig = {
        DHCP = "no";
        IPv6AcceptRA = false;
        LinkLocalAddressing = "no";
      };

    in
    lib.mkMerge [
      # -------------------------------------------------------------------------
      # SIMPLE NETWORK: Single interface with direct IP
      # -------------------------------------------------------------------------
      # Used when: no VLANs, no bonding
      # Example: eth1 gets 192.168.1.1/24
      (lib.mkIf (!hasVlans && !hasBond) {
        # Ensure systemd-networkd is used exclusively
        networking.useDHCP = false;
        networking.useNetworkd = true;

        systemd.network = {
          enable = true;
          networks."20-${clusterIface}" = {
            matchConfig.Name = clusterIface;
            address = [ "${nodeIPs.cluster or "0.0.0.0"}/24" ];
            networkConfig = commonNetworkConfig;
          };
        };
      })

      # -------------------------------------------------------------------------
      # VLAN NETWORK: Trunk interface + VLAN interfaces
      # -------------------------------------------------------------------------
      # Used when: has VLANs, no bonding
      # Example: eth1 (trunk) → eth1.200 (cluster), eth1.100 (storage)
      (lib.mkIf (hasVlans && !hasBond) {
        # Enable 802.1Q VLAN kernel support
        boot.kernelModules = [ "8021q" ];

        # Ensure systemd-networkd is used exclusively
        networking.useDHCP = false;
        networking.useNetworkd = true;

        systemd.network = {
          enable = true;

          # VLAN netdevs
          netdevs = {
            # Cluster VLAN netdev
            "20-vlan-cluster" = {
              netdevConfig = {
                Kind = "vlan";
                Name = clusterIface;
              };
              vlanConfig.Id = clusterVlanId;
            };
          } // lib.optionalAttrs (storageIface != null && storageVlanId != null) {
            # Storage VLAN netdev (optional)
            "20-vlan-storage" = {
              netdevConfig = {
                Kind = "vlan";
                Name = storageIface;
              };
              vlanConfig.Id = storageVlanId;
            };
          };

          # Network configurations
          networks = {
            # Trunk interface (carries VLANs, no IP)
            "15-${trunkIface}" = {
              matchConfig.Name = trunkIface;
              vlan = [ clusterIface ] ++ lib.optional (storageIface != null) storageIface;
              networkConfig = commonNetworkConfig;
            };

            # Cluster VLAN interface
            "20-vlan-cluster" = {
              matchConfig.Name = clusterIface;
              address = [ "${nodeIPs.cluster or "0.0.0.0"}/24" ];
              networkConfig = commonNetworkConfig;
            };
          } // lib.optionalAttrs (storageIface != null) {
            # Storage VLAN interface (optional)
            "20-vlan-storage" = {
              matchConfig.Name = storageIface;
              address = [ "${nodeIPs.storage or "0.0.0.0"}/24" ];
              networkConfig = commonNetworkConfig;
            };
          };
        };
      })

      # -------------------------------------------------------------------------
      # BONDING + VLAN NETWORK: Bond interface + VLAN interfaces on top
      # -------------------------------------------------------------------------
      # Used when: has VLANs AND bonding
      # Example: eth1+eth2 → bond0 (trunk) → bond0.200 (cluster), bond0.100 (storage)
      (lib.mkIf (hasVlans && hasBond) {
        # Enable bonding and 802.1Q VLAN kernel support
        boot.kernelModules = [ "bonding" "8021q" ];

        systemd.network = {
          enable = true;

          netdevs = {
            # Bond netdev
            "10-${trunkIface}" = {
              netdevConfig = {
                Kind = "bond";
                Name = trunkIface;
              };
              bondConfig = {
                Mode = bondMode;
                MIIMonitorSec = "${toString bondMiimon}ms";
                # PrimaryReselectPolicy for active-backup mode
                PrimaryReselectPolicy = if bondMode == "active-backup" then "always" else "better";
                # Additional settings for robustness
                UpDelaySec = "200ms";
                DownDelaySec = "200ms";
              };
            };

            # Cluster VLAN netdev
            "20-vlan-cluster" = {
              netdevConfig = {
                Kind = "vlan";
                Name = clusterIface;
              };
              vlanConfig.Id = clusterVlanId;
            };
          } // lib.optionalAttrs (storageIface != null && storageVlanId != null) {
            # Storage VLAN netdev (optional)
            "20-vlan-storage" = {
              netdevConfig = {
                Kind = "vlan";
                Name = storageIface;
              };
              vlanConfig.Id = storageVlanId;
            };
          };

          networks = {
            # Bond trunk interface (carries VLANs, no IP)
            "20-${trunkIface}" = {
              matchConfig.Name = trunkIface;
              vlan = [ clusterIface ] ++ lib.optional (storageIface != null) storageIface;
              networkConfig = commonNetworkConfig;
              linkConfig.RequiredForOnline = false; # VLANs will be online
            };

            # Cluster VLAN interface
            "30-vlan-cluster" = {
              matchConfig.Name = clusterIface;
              address = [ "${nodeIPs.cluster or "0.0.0.0"}/24" ];
              networkConfig = commonNetworkConfig;
              linkConfig.RequiredForOnline = true; # Primary network
            };
          }
          # Bond slave interfaces
          // lib.listToAttrs (lib.imap0
            (i: member: {
              name = "10-${member}";
              value = {
                matchConfig.Name = member;
                networkConfig = {
                  Bond = trunkIface;
                  # Disable DHCP on slave interfaces
                  DHCP = "no";
                  IPv6AcceptRA = false;
                  LinkLocalAddressing = "no";
                } // lib.optionalAttrs (member == bondPrimary && bondMode == "active-backup") {
                  # Mark primary interface for active-backup mode
                  # PrimarySlave goes in slave's networkConfig, not bond's bondConfig
                  PrimarySlave = true;
                };
                linkConfig.RequiredForOnline = false;
              };
            })
            bondMembers)
          // lib.optionalAttrs (storageIface != null) {
            # Storage VLAN interface (optional)
            "30-vlan-storage" = {
              matchConfig.Name = storageIface;
              address = [ "${nodeIPs.storage or "0.0.0.0"}/24" ];
              networkConfig = commonNetworkConfig;
              linkConfig.RequiredForOnline = false; # Secondary network
            };
          };
        };

        # Ensure systemd-networkd is used
        networking.useDHCP = false;
        networking.useNetworkd = true;
      })
    ];

  # ===========================================================================
  # mkSystemdNetworkdFiles - Generate file content strings (for ISAR backend)
  # ===========================================================================
  #
  # SIGNATURE:
  #   { nodes, interfaces, vlanIds?, bondConfig? } -> nodeName -> { filename = content; }
  #
  # Same parameter signature as mkNixOSConfig for consistency.
  # Wraps existing mk-systemd-networkd.nix functionality.
  #
  # OUTPUT:
  #   { "20-eth1.network" = "..."; "20-vlan-cluster.netdev" = "..."; ... }
  #
  mkSystemdNetworkdFiles = { nodes, interfaces, vlanIds ? null, bondConfig ? null }: nodeName:
    let
      # Construct profile-like structure for backward compatibility with existing generator
      profile = {
        ipAddresses = nodes;
        inherit interfaces;
      } // lib.optionalAttrs (vlanIds != null) { inherit vlanIds; }
      // lib.optionalAttrs (bondConfig != null) { inherit bondConfig; };
    in
    mkSystemdNetworkd.generateProfileFiles profile nodeName;
}
