# Getting Started with n3x

n3x is a declarative framework for K3s clusters on embedded Linux. It supports both NixOS and Debian backends (the latter using ISAR as the build framework) with unified test infrastructure.

## Quick Start: Find Your Path

### "I want to add an application package"

**Level 0** - Work in `backends/debian/packages/`

```bash
cp -r backends/debian/packages/template backends/debian/packages/my-app
# Edit debian/control, add your code
nix build '.#packages.x86_64-linux.my-app'
```

**See**: [packages/README.md](../backends/debian/packages/README.md)

**Prerequisites**: Git, basic Debian packaging

---

### "I want to modify the BSP or image"

**Level 1** - Work in `backends/debian/`

```bash
nix develop .#debian
cd backends/debian
kas-build kas/base.yml:kas/machine/qemu-amd64.yml:kas/image/k3s-server.yml:...
```

**See**: [backends/debian/README.md](../backends/debian/README.md), [BSP-GUIDE.md](../backends/debian/BSP-GUIDE.md)

**Prerequisites**: Git, BitBake/kas basics

---

### "I want to understand or run the tests"

**Level 2** - Look at `tests/`

```bash
nix build '.#checks.x86_64-linux.k3s-cluster-simple' -L
```

**See**: [tests/README.md](../tests/README.md)

**Prerequisites**: Git, Nix basics

---

### "I want to modify platform infrastructure"

**Level 3** - Full repo access needed

This includes: network config generation, test framework, Nix derivations.

**See**: [README.md](../README.md), `lib/` directories

**Prerequisites**: Git, Nix fluency, system architecture understanding

---

## Prerequisites by Level

| Level | Git | Debian Pkg | BitBake | Nix | Python |
|-------|:---:|:----------:|:-------:|:---:|:------:|
| 0 | Yes | Basic | - | - | - |
| 1 | Yes | - | Basic | - | - |
| 2 | Yes | - | - | Basic | Basic |
| 3 | Yes | - | - | Fluent | Basic |

## Repository Structure

```
n3x/
├── backends/debian/packages/  # Level 0: Debian packages (most developers)
├── backends/debian/           # Level 1: ISAR build system, BSP
├── tests/              # Level 2: VM test infrastructure
├── lib/                # Level 3: Shared abstractions
├── docs/               # Documentation
└── flake.nix           # Nix flake definition
```

## Next Steps

1. Identify your task from the paths above
2. Read the linked documentation for your level
3. Ask questions if stuck
