# Version pins for isar-k3s project
# Single source of truth for all version information
{
  # ISAR build version (update after each significant build)
  isar = {
    version = "2026.01.23";
    # Git commit of isar-k3s at build time (filled by update-artifact-hashes.sh)
    commit = "";
  };

  # L4T version (must match meta-isar-k3s/recipes-bsp/nvidia-l4t/*.bb)
  l4t = {
    version = "36.4.4";
    jetpackVersion = "6.1";
  };

  # k3s version (must match meta-isar-k3s/recipes-core/k3s/*.bb)
  k3s = {
    version = "1.32.0";
  };

  # Target machines supported by this project
  machines = [ "qemu-amd64" "amd-v3c18i" "jetson-orin-nano" ];
}
