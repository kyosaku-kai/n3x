# n3x Build System Presentation Guide

**Duration**: 15-20 minutes presentation + discussion
**Audience**: Team members expecting ISAR/Yocto walkthrough, with optional Nix abstraction layer discussion
**Visual Aid**: Open `docs/diagrams/n3x-build-system-presentation.drawio.svg` in browser alongside this guide

---

## Presentation Flow Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  1. ISAR Backend (Primary Focus)                              ~10 min      │
│     ├── What is ISAR/Yocto/BitBake?                                        │
│     ├── kas YAML Composition Pattern                                       │
│     ├── Directory Walkthrough                                              │
│     └── Build Command Demo                                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│  2. Debian Development Workflows                              ~5 min       │
│     ├── Low-Level: Kernel/OS Development                                   │
│     └── High-Level: Application Packaging                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│  3. Nix Abstraction Layer (If Time Permits)                   ~5 min       │
│     ├── Why Parameterize with Nix?                                         │
│     ├── Shared Network Profiles                                            │
│     └── Unified Test Infrastructure                                        │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Part 1: ISAR Backend (~10 minutes)

### 1.1 Opening Context

**Show**: The main diagram in browser

**Talking Points**:
- This project builds K3s (lightweight Kubernetes) images for edge hardware
- We use ISAR - "Integration System for Automated Root filesystem generation"
- ISAR = BitBake build system + Debian package ecosystem
- Result: Production-grade `.wic` disk images ready for deployment

### 1.2 What is ISAR?

**Visual**: Point to the "Build Layer" section of the diagram

**Talking Points**:
- **BitBake**: Task execution engine from OpenEmbedded/Yocto (not reinventing the wheel)
- **ISAR advantage**: Uses real Debian packages instead of building everything from source
- **Why this matters**: Faster builds, Debian ecosystem packages, familiar tooling
- **Output**: Bootable disk images (`.wic`) with Debian Trixie base + our customizations

### 1.3 kas YAML Composition Pattern

**Navigate to**: `backends/debian/kas/`

**Show the directory structure**:
```
kas/
├── base.yml              # Shared configuration (cache, parallelism)
├── machine/              # Hardware targets
│   ├── qemu-amd64.yml   # x86_64 QEMU VM (testing)
│   └── jetson-orin-nano.yml
├── image/                # Role (server vs agent)
│   ├── k3s-server.yml
│   └── k3s-agent.yml
├── packages/             # Package groups
│   ├── k3s-core.yml     # K3s and dependencies
│   └── debug.yml        # Debug tools
├── network/              # Network profiles
│   ├── simple.yml
│   ├── vlans.yml
│   └── bonding-vlans.yml
└── node/                 # Node identity (determines IP)
    ├── server-1.yml
    └── server-2.yml
```

**Talking Points**:
- **Composition over configuration**: Build command stacks YAML files with colons
- **Each overlay adds/overrides**: Packages, variables, targets
- **Separation of concerns**: Machine, role, packages, network, identity are independent
- **Flexibility**: Same patterns work for QEMU testing and real hardware

### 1.4 Build Command Anatomy

**Show this command** (don't run, just explain):
```bash
kas-build kas/base.yml:kas/machine/qemu-amd64.yml:kas/packages/k3s-core.yml:kas/packages/debug.yml:kas/image/k3s-server.yml:kas/network/simple.yml:kas/node/server-1.yml
```

**Talking Points**:
- Read left-to-right: Each colon adds another overlay
- `base.yml` → Shared cache, parallelism settings
- `machine/qemu-amd64.yml` → Target hardware (MACHINE variable)
- `packages/k3s-core.yml` → K3s binary and dependencies
- `image/k3s-server.yml` → Build target (server role)
- `network/simple.yml` → Network profile (flat network)
- `node/server-1.yml` → Node identity (IP: 192.168.1.1)

**Key insight**: To build server-2 with VLANs, just change the last two overlays:
```bash
kas-build ...same...:kas/network/vlans.yml:kas/node/server-2.yml
```

### 1.5 Directory Walkthrough

**Navigate to**: `backends/debian/meta-n3x/`

**Show**:
```
meta-n3x/
├── conf/layer.conf           # BitBake layer registration
├── recipes-bsp/
│   └── nvidia-l4t/           # Jetson BSP packages
│       ├── nvidia-l4t-core_36.4.4.bb
│       └── nvidia-l4t-tools_36.4.4.bb
├── recipes-core/
│   ├── images/               # Image definitions
│   │   ├── n3x-image-base.bb
│   │   ├── n3x-image-server.bb
│   │   └── n3x-image-agent.bb
│   ├── k3s/                  # K3s binary packaging
│   │   ├── k3s-server_1.32.0.bb
│   │   └── k3s-agent_1.32.0.bb
│   └── k3s-system-config/    # Kernel modules, sysctl
├── recipes-support/
│   └── systemd-networkd-config/  # Network configuration
├── recipes-testing/
│   └── nixos-test-backdoor/  # VM test infrastructure
└── classes/                  # Shared build logic
```

**Talking Points**:
- **Standard BitBake/Yocto structure**: recipes-*, classes/, conf/
- **BSP recipes**: NVIDIA L4T packages for Jetson hardware
- **Image recipes**: Define what packages go into the final image
- **K3s recipes**: Download static binary from GitHub, package as .deb
- **Network config recipe**: Installs systemd-networkd files for static IPs

### 1.6 What a kas Overlay Actually Does

**Navigate to**: `backends/debian/kas/packages/k3s-core.yml`

**Show contents** (approximate):
```yaml
header:
  version: 14

local_conf_header:
  k3s-packages: |
    IMAGE_INSTALL:append = " k3s-server k3s-agent k3s-system-config"
    IMAGE_INSTALL:append = " ca-certificates curl iptables conntrack"
    IMAGE_INSTALL:append = " iproute2 ipvsadm bridge-utils procps util-linux"
```

**Talking Points**:
- `IMAGE_INSTALL:append` adds Debian packages to the image
- These are **real Debian packages** from Trixie + our custom .deb recipes
- The overlay **configures** the build, doesn't change recipe logic
- Team members add packages via overlays, not by editing recipes

---

## Part 2: Debian Development Workflows (~5 minutes)

### 2.1 Two Development Patterns

**Visual**: Draw on whiteboard or describe conceptually

```
┌───────────────────────────────────────────────────────────────────┐
│                  Debian Development Patterns                       │
├───────────────────────────────────────────────────────────────────┤
│                                                                    │
│  Low-Level (Kernel/OS)              High-Level (Applications)     │
│  ──────────────────────            ─────────────────────────      │
│                                                                    │
│  • BitBake recipes (.bb)            • Standard Debian packaging   │
│  • Cross-compilation support        • debian/ directory in repo   │
│  • Kernel patches via .bbappend     • Build with dpkg-buildpackage│
│  • BSP modifications                • Host on internal apt repo   │
│  • Lives in meta-n3x/          • Lives in ANY repo           │
│                                                                    │
│  Who: Platform team                 Who: Application teams        │
│  When: New hardware, drivers        When: New features, services  │
│                                                                    │
└───────────────────────────────────────────────────────────────────┘
```

### 2.2 Low-Level: Kernel/OS Development

**Talking Points**:
- Modify kernel, drivers, BSP → Write BitBake recipes in `meta-n3x/`
- ISAR supports cross-compilation for ARM64 (Jetson)
- Kernel patches: Use `.bbappend` files to modify upstream ISAR recipes
- Example: `recipes-bsp/nvidia-l4t/` for Jetson-specific modifications

### 2.3 High-Level: Application Packaging

**Talking Points**:
- Standard Debian packaging workflow - no ISAR knowledge required
- Create `debian/` directory in your application repo
- Build `.deb` with `dpkg-buildpackage` or CI pipeline
- Host on internal apt repository (Artifactory, simple HTTP server)
- Add to ISAR images via kas overlay:
  ```yaml
  # kas/feature/my-app.yml
  local_conf_header:
    my-app: |
      IMAGE_INSTALL:append = " my-application-package"
  ```

**Key insight**: Application teams don't need to touch this repository. They:
1. Package their app as standard Debian package
2. Request addition to a kas overlay
3. Platform team adds one line to `IMAGE_INSTALL:append`

### 2.4 Package Addition Workflow

**Navigate to**: `backends/debian/kas/packages/debug.yml` as example

**Show**:
```yaml
header:
  version: 14

local_conf_header:
  debug-packages: |
    IMAGE_INSTALL:append = " openssh-server vim-tiny less iputils-ping sshd-regen-keys"
```

**Talking Points**:
- This is all it takes to add packages to an image
- Create new `kas/feature/*.yml` for logical groupings
- Compose features in build command: `:kas/feature/my-app.yml:kas/feature/monitoring.yml`

---

## Part 3: Nix Abstraction Layer (If Time Permits, ~5 minutes)

### 3.1 Why Parameterize with Nix?

**Visual**: Point to the unified abstractions section of the diagram

**Talking Points**:
- ISAR builds produce **one image at a time**
- We need: Multiple machines × Multiple roles × Multiple network profiles × Multiple nodes
- **The combinatorial problem**: 2 machines × 2 roles × 4 profiles × 2 nodes = 32 images
- Nix provides: Declarative configuration, parameterized builds, reproducibility

### 3.2 Shared Network Profiles

**Navigate to**: `lib/network/profiles/simple.nix`

**Show** (conceptual structure):
```nix
{
  ipAddresses = {
    "server-1" = { cluster = "192.168.1.1"; };
    "server-2" = { cluster = "192.168.1.2"; };
  };
  interfaces = { cluster = "eth1"; };
  serverApi = "https://192.168.1.1:6443";
}
```

**Talking Points**:
- **Pure data**: No code, just configuration values
- **Same profile** used by NixOS backend AND ISAR backend
- For ISAR: Transforms into `systemd-networkd` `.network` files
- For NixOS: Transforms into `systemd.network.*` module options
- **Single source of truth**: Change once, both backends update

### 3.3 Unified Test Infrastructure

**Navigate to**: `tests/` directory

**Show directory structure**:
```
tests/
├── nixos/                # NixOS VM tests (fast iteration)
├── isar/                 # ISAR .wic image tests
└── lib/                  # Shared test utilities
    ├── mk-k3s-cluster-test.nix   # Parameterized test builder
    └── test-scripts/             # Shared test phases
```

**Talking Points**:
- **Same test logic** runs on both NixOS and Debian backend images
- Tests validate: Boot → Network → K3s service → Cluster formation
- **16-test parity matrix**: 4 network profiles × 2 boot modes × 2 backends
- Command example:
  ```bash
  nix build '.#checks.x86_64-linux.debian-cluster-simple'
  ```

### 3.4 Why This Matters for the Team

**Talking Points**:
- **Debian backend is production**: ISAR-based, embedded-grade, OTA updates
- **NixOS is development**: Fast iteration, easy testing, same network configs
- **Nix glue**: Parameterizes Debian backend builds, runs tests, manages artifacts
- **Team workflow**: Use kas overlays for packages, rely on Nix for test validation

---

## Q&A Preparation

### Likely Questions

**Q: Why not just use Yocto directly?**
- A: ISAR gives us Debian packages (faster, familiar), kas gives us composition (flexible), Nix gives us reproducible orchestration and testing.

**Q: How do I add my application?**
- A: Standard Debian packaging in your repo → host on apt repo → add to kas overlay. You don't need to modify this repository directly.

**Q: What's the build time?**
- A: First build: 15-30 minutes (downloads packages, creates sstate cache). Subsequent builds: 2-5 minutes (incremental).

**Q: Can we use this for production?**
- A: Yes. ISAR is used by Siemens and others for production embedded systems. SWUpdate integration provides A/B OTA updates.

**Q: What about ARM64/Jetson?**
- A: Fully supported. `kas/machine/jetson-orin-nano.yml` configures the Jetson build. Same overlay pattern, different machine.

---

## Key Files for Live Navigation

| Purpose | Path |
|---------|------|
| Main visual | `docs/diagrams/n3x-build-system-presentation.drawio.svg` |
| Debian Backend README | `backends/debian/README.md` |
| kas base config | `backends/debian/kas/base.yml` |
| Package overlay example | `backends/debian/kas/packages/k3s-core.yml` |
| Network profile | `lib/network/profiles/simple.nix` |
| Test framework | `tests/README.md` |
| Project overview | `README.md` |

---

## Post-Presentation Resources

Share these links with attendees:

1. **This presentation guide**: `docs/BUILD-SYSTEM-PRESENTATION-GUIDE.md`
2. **Debian Backend README**: `backends/debian/README.md` (detailed build instructions)
3. **Test Framework**: `tests/README.md` (how to run/debug tests)
4. **Architecture Decision Record**: `docs/adr/001-isar-artifact-integration-architecture.md`

---

## Continuation Prompt

```
Continue work on n3x project presentation/documentation.

Current status: Presentation guide created at docs/BUILD-SYSTEM-PRESENTATION-GUIDE.md
Last completed: Created comprehensive 15-20 minute presentation guide covering:
  - ISAR backend architecture and kas YAML composition
  - Debian development workflows (low-level and high-level)
  - Nix abstraction layer overview
  - Q&A preparation

Key artifacts:
  - docs/BUILD-SYSTEM-PRESENTATION-GUIDE.md (main deliverable)
  - docs/diagrams/n3x-build-system-presentation.drawio.svg (visual aid)

Next task: User to specify - could be presentation rehearsal feedback, additional
documentation, or other project work
```
