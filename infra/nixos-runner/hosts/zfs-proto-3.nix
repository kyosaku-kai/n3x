# ZFS cluster prototype - Node 3
#
# Intel N100 mini PC, third node in 3-node ZFS binary cache prototype.
# Cluster IP: 10.99.0.13
{ config, lib, ... }:

{
  imports = [ ./zfs-proto-common.nix ];

  networking.hostName = "zfs-proto-3";
  n3x.disko-zfs.hostId = "a1b2c303"; # Unique per host (ZFS requirement)

  # Cluster network: static IP
  systemd.network.networks."20-cluster".address = [ "10.99.0.13/24" ];

  # Substituters: fetch from the other two cluster nodes
  n3x.nix-config.extraSubstituters = [
    "https://cache.zfs-proto-1.n3x.internal?priority=10"
    "https://cache.zfs-proto-2.n3x.internal?priority=10"
  ];
}
