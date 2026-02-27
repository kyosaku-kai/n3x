# n3x — K3s Edge Cluster Platform

n3x builds and tests Kubernetes clusters for edge hardware. It currently supports two embedded linux build system "backends": **[NixOS](https://nixos.org)** for reproducible infrastructure, and **[ISAR](https://github.com/ilbers/isar)** for Debian-based development and image assembly. A shared nix abstraction layer defines common system elements as profiles for machine, network/k3s topology and configuration, and package mappings. The output of these nix derivations is consumed by backend processes to produce consistent, VM-tested final images ready for rapid local development without hardware, or bare-metal deployment.

## Architecture

```mermaid
flowchart TD
    subgraph lib["lib/ — Shared Abstraction Layer"]
        net["lib/network/\nNetwork profiles → config files"]
        k3s["lib/k3s/\nK3s flags + cluster topology"]
        deb_lib["lib/debian/\nPackage mapping + verification"]
    end

    subgraph nixos["NixOS Backend"]
        nx_mods["backends/nixos/modules/\nComposable NixOS modules"]
        nx_cfg["nixosConfigurations\n(NixOS closures)"]
        nx_mods --> nx_cfg
    end

    subgraph debian["Debian Backend"]
        pkgs["backends/debian/packages/\nDebian source packages"]
        kas["backends/debian/kas/\nkas overlays → BitBake/ISAR"]
        wic[".wic disk images"]
        pkgs --> kas --> wic
    end

    subgraph test["Unified Test Infrastructure"]
        driver["NixOS test driver\n(QEMU multi-node VMs)"]
        profiles["simple · vlans · bonding · dhcp"]
        driver --- profiles
    end

    lib --> nx_mods
    lib --> kas
    nx_cfg --> driver
    wic --> driver
```

The `lib/` directory is the architectural center: it defines network profiles, K3s topology, and package requirements once, then each backend consumes them in its native format. Both backends converge at the test infrastructure, where identical test scenarios validate cluster formation across network profiles.

| Abstraction | NixOS Backend | Debian Backend |
|-------------|---------------|----------------|
| **Machine** | `system` + `hardware/<machine>.nix` | `MACHINE` + `recipes-bsp/` |
| **Role** | `modules/roles/k3s-server.nix` | `classes/k3s-server.bbclass` |
| **System** | `nixosConfigurations.<name>` | `kas/<overlays>.yml` + image recipe |
| **Network** | NixOS systemd-networkd module | `.network`/`.netdev` config files |
| **K3s Binary** | nixpkgs `k3s` package | Static binary from GitHub releases |
| **Test Harness** | nixosTest (native) | nixosTest (with .wic images) |

Shared configuration libraries ([`lib/network/`](lib/network/README.md), [`lib/k3s/`](lib/k3s/README.md)) transform profile data for both backends.

## Repository Structure

```
n3x/
├── backends/
│   ├── debian/                  # Debian backend — ISAR/BitBake image assembly
│   │   ├── packages/            #   Developer interface — Debian source packages
│   │   │   ├── k3s/             #     K3s binary + systemd service
│   │   │   └── k3s-system-config/ #   K3s cluster configuration
│   │   ├── kas/                 #   kas configuration overlays
│   │   │   ├── base.yml         #     Base ISAR config
│   │   │   ├── machine/         #     Target hardware definitions
│   │   │   ├── image/           #     Image roles (server, agent)
│   │   │   ├── network/         #     Network profiles
│   │   │   └── node/            #     Per-node identity
│   │   └── meta-n3x/            #   BitBake layer (recipes, WIC templates)
│   │
│   └── nixos/                   # NixOS backend — host infrastructure
│       ├── hosts/               #   Per-node configs (n100-1..3, jetson-1..2)
│       ├── modules/             #   Composable NixOS modules
│       ├── disko/               #   Disk partitioning layouts
│       └── vms/                 #   VM test configurations
│
├── lib/                         # Shared abstraction layer
│   ├── network/                 #   Network config generation (NixOS + Debian)
│   ├── k3s/                     #   K3s flag generation from topology profiles
│   └── debian/                  #   Package mapping + kas verification
│
├── tests/                       # VM test infrastructure
│   ├── nixos/                   #   NixOS backend tests (cluster, smoke, network)
│   ├── debian/                  #   Debian backend tests (cluster, boot, swupdate)
│   └── lib/                     #   Shared test builders and phase scripts
│
├── infra/                       # CI/CD infrastructure
│   ├── nixos-runner/            #   NixOS runner configurations
│   └── pulumi/                  #   AWS EC2 provisioning
│
├── manifests/                   # Kubernetes manifests
├── secrets/                     # Encrypted secrets (SOPS)
└── docs/                        # Documentation
```

## Getting Started

Choose your entry point based on what you want to do:

| Goal | Start Here |
|------|------------|
| Add an application package | [`backends/debian/packages/README.md`](backends/debian/packages/README.md) |
| Build Debian disk images | [`backends/debian/README.md`](backends/debian/README.md) |
| Configure NixOS infrastructure | [`backends/nixos/README.md`](backends/nixos/README.md) |
| Run VM tests | [`tests/README.md`](tests/README.md) |
| Modify network profiles or K3s topology | [`docs/GETTING-STARTED.md`](docs/GETTING-STARTED.md) |

For a guided walkthrough covering all paths, see [`docs/GETTING-STARTED.md`](docs/GETTING-STARTED.md).

## Building

### Debian Backend

The build matrix has 16 variants across 4 machines (42 total artifacts). The primary workflow builds images and registers them in the Nix store:

```bash
# Build and register ALL 16 variants
nix run '.'

# List all variants in the build matrix
nix run '.' -- --list

# Build one specific variant
nix run '.' -- --variant server-simple-server-1

# Build all variants for one machine
nix run '.' -- --machine qemuamd64

# Preview what would be built
nix run '.' -- --dry-run
```

Each variant is assembled from stacked kas overlays:

| Overlay          | Purpose                    | Examples                        |
|------------------|----------------------------|---------------------------------|
| `machine/`       | Target hardware            | `qemu-amd64`, `qemu-arm64`     |
| `packages/`      | Package sets               | `k3s-core`, `debug`            |
| `image/`         | Cluster role               | `k3s-server`, `k3s-agent`      |
| `network/`       | Network topology           | `simple`, `vlans`, `bonding`   |
| `node/`          | Per-node identity (IP, ID) | `server-1`, `agent-1`          |

For lower-level builds without Nix store registration:

```bash
nix develop
cd backends/debian
kas-build kas/base.yml:kas/machine/qemu-amd64.yml:kas/packages/k3s-core.yml:kas/packages/debug.yml:kas/image/k3s-server.yml:kas/network/simple.yml:kas/node/server-1.yml
```

See [`backends/debian/README.md`](backends/debian/README.md) for the full Debian build guide.

### NixOS Backend

NixOS host configurations are built and deployed using standard Nix tooling:

```bash
# Build a host configuration
nix build '.#nixosConfigurations.n100-1.config.system.build.toplevel'

# Deploy to a running host
nixos-rebuild switch --flake '.#n100-1' --target-host root@n100-1
```

See [`backends/nixos/README.md`](backends/nixos/README.md) for module composition and deployment.

## Testing

The test infrastructure emulates multi-node k3s clusters in VMs — booting real images, configuring networking, and validating cluster formation automatically. Tests run identically on developer laptops and CI, requiring only KVM. No physical hardware or cloud dependencies needed.

Both backends converge at the same test harness: the NixOS test driver, which orchestrates QEMU/KVM multi-node topologies via Python test scripts. Each network profile is tested independently on both backends to ensure parity.

```bash
# Run ALL Debian tests (18 tests)
nix build '.#checks.x86_64-linux.debian-all'

# Run a single Debian test
nix build '.#checks.x86_64-linux.debian-cluster-simple' -L

# Run a NixOS backend test
nix build '.#checks.x86_64-linux.k3s-cluster-simple'

# Validate all artifact hashes without running tests
nix build '.#checks.x86_64-linux.debian-artifact-validation'
```

### Cluster Test Parity Matrix

| Network Profile | NixOS | Debian |
|-----------------|-------|--------|
| Simple (flat) | `k3s-cluster-simple` | `debian-cluster-simple` |
| 802.1Q VLANs | `k3s-cluster-vlans` | `debian-cluster-vlans` |
| Bonding + VLANs | `k3s-cluster-bonding-vlans` | `debian-cluster-bonding-vlans` |
| DHCP | `k3s-cluster-dhcp-simple` | `debian-cluster-dhcp-simple` |

Additional backend-specific tests cover boot validation, service startup, network debugging, OTA updates (Debian), and storage/failover scenarios (NixOS). See [`tests/README.md`](tests/README.md) for the full 45-check test catalog.

## Target Hardware

| Platform           | Architecture | Use Case               |
|--------------------|-------------|------------------------|
| AMD V3000          | x86_64      | Industrial edge gateway |
| Jetson Orin Nano   | aarch64     | Edge AI/ML workloads   |
| Intel N100 miniPCs | x86_64      | Development / prototype |
| QEMU VMs           | x86_64      | Testing (no hardware)  |

## CI/CD Pipeline

```mermaid
flowchart TD
    subgraph triggers["Triggers"]
        mr["Merge Request"]
        main["Push to main"]
    end

    subgraph nix_stage["build-nix"]
        deb_x86["build:deb:k3s\nx86_64"]
        deb_arm["build:deb:k3s-arm64\naarch64"]
        nixos_eval["NixOS eval\n+ flake checks"]
    end

    subgraph debian_stage["build-debian"]
        img_s["server image"]
        img_a["agent image"]
    end

    subgraph test_stage["test"]
        vm_nixos["NixOS VM tests\ncluster + smoke"]
        vm_debian["Debian VM tests\ncluster + boot"]
    end

    triggers --> nix_stage
    nix_stage --> debian_stage --> vm_debian
    nix_stage --> vm_nixos
```

- **build-nix**: Evaluates flake, compiles `.deb` packages (EC2 runners), runs NixOS checks
- **build-debian**: Assembles bootable Debian images via kas/BitBake (large-disk runners)
- **test**: VM cluster tests on KVM-capable runners (both backends)

Built artifacts are shared between stages via Nix binary cache (Harmonia), not GitLab artifacts.

## Caching Architecture

```mermaid
flowchart TD
    subgraph node["Each Build Node"]
        store["/nix/store — ZFS + zstd"]
        harmonia["Harmonia → Caddy (HTTPS)"]
        store --> harmonia
    end

    subgraph yocto["ISAR Build Caches"]
        apt["apt-cacher-ng\nDebian package proxy"]
        sstate["SSTATE_DIR + DL_DIR"]
    end

    subgraph mirrors["Internal Mirrors"]
        artifactory["JFrog Artifactory\nDebian repos + binaries"]
        gitlab["Internal GitLab\nSource code forks"]
    end

    harmonia -->|"HTTPS substituters"| peers["Other Build Nodes"]
    apt -->|"cache miss"| artifactory
```

| Cache Tier       | What                          | Storage                |
|------------------|-------------------------------|------------------------|
| Nix binary cache | Built derivations (.nar)      | ZFS + Harmonia per node|
| apt-cacher-ng    | Debian packages               | Local per machine      |
| Yocto sstate     | BitBake shared state           | Local disk (ephemeral) |
| Artifactory      | Custom .debs + Debian mirror  | JFrog cloud            |
| Internal GitLab  | Source code forks             | GitLab instance        |

See [`docs/nix-binary-cache-architecture-decision.md`](docs/nix-binary-cache-architecture-decision.md) for the full architecture decision.

## Documentation

> **[Full Documentation Map](docs/README.md)** — Navigable index of every document, diagram, and guide in this project.

Key entry points:

- [`docs/GETTING-STARTED.md`](docs/GETTING-STARTED.md) — Guided walkthrough for all developer paths
- [`backends/debian/README.md`](backends/debian/README.md) — Debian backend build guide
- [`backends/nixos/README.md`](backends/nixos/README.md) — NixOS backend configuration and deployment
- [`tests/README.md`](tests/README.md) — Test framework and full test catalog
- [`infra/README.md`](infra/README.md) — CI/CD infrastructure (AWS + NixOS runners)
- [`docs/SECRETS-SETUP.md`](docs/SECRETS-SETUP.md) — SOPS/age secrets management
- [`RELEASE.md`](RELEASE.md) — Versioning and release process
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — Contribution guidelines and commit conventions
