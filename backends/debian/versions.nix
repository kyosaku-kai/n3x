# Version pins for n3x project
# Single source of truth for all version information
{
  # ISAR build version (update after each significant build)
  isar = {
    version = "2026.01.23";
    # Git commit of n3x at build time
    commit = "";
  };

  # L4T version (must match meta-n3x/recipes-bsp/nvidia-l4t/*.bb)
  l4t = {
    version = "36.4.4";
    jetpackVersion = "6.1";
  };

  # Kernel versions (must match meta-n3x/recipes-kernel/linux/*.bb)
  kernel = {
    tegra = {
      version = "6.12.69";
      lts = true;
    };
  };

  # k3s version (must match meta-n3x/recipes-core/k3s/*.bb)
  k3s = {
    version = "1.32.0";
  };

  # Target machines supported by this project
  machines = [ "qemu-amd64" "amd-v3c18i" "jetson-orin-nano" ];
}
