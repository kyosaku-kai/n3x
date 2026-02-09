# NVIDIA Out-of-Tree (OOT) Kernel Modules

This directory is a placeholder for future NVIDIA out-of-tree kernel module recipes.

## Current Status

**Not needed for initial bring-up.** The linux-tegra 6.12 LTS kernel recipe
uses mainline drivers for all required peripherals. GPU/display support is
explicitly excluded from this project.

## Potential Future OOT Modules

### nvethernetrm

The upstream stmmac/DWMAC driver supports Tegra MGBE Ethernet in mainline.
If advanced features (PTP hardware timestamping, multi-queue optimization)
are needed beyond what mainline provides, NVIDIA's `nvethernetrm` OOT module
may be required.

**Status**: Monitor mainline stmmac performance; add only if insufficient.

### SPE (Sensor Processing Engine)

The Tegra234 SPE runs on a dedicated R5F core for sensor aggregation.
Communicating with SPE from Linux requires OOT drivers not yet in mainline.

**Status**: Not urgent. Add when sensor hub integration is needed.

### Audio (if mainline proves insufficient)

The mainline ASoC Tegra stack (AHUB, ADMAIF, I2S, DMIC, DSPK) is enabled
in the kernel config fragment. If specific audio features require NVIDIA's
OOT audio drivers, they would go here.

**Status**: Mainline expected to be sufficient. Validate on hardware.

## References

- Analysis document: `docs/jetson-orin-nano-kernel6-analysis-revised.md`
  (Section 7: Module Compatibility Matrix)
- NVIDIA OOT sources: https://github.com/NVIDIA/linux-nv-oot
- OE4T meta-tegra OOT recipes: https://github.com/OE4T/meta-tegra
