# CLAUDE.md - Project Memory and Rules

This file provides project-specific rules and essential context for Claude Code when working with the n3x repository.

## Critical Rules

### Git Commit Practices
1. **COMMIT FREQUENTLY** - Don't accumulate changes across multiple files before committing. Commit each logical change as you make it. Small, frequent commits are better than large batches. This also serves as implicit flake verification (see rule 3).
2. **Committing IS your flake check** - The Nix-managed pre-commit hook (`core.hooksPath`) runs `nix flake check --no-build` automatically. Do NOT run `nix flake check` manually before committing — just commit and let the hook verify. If the commit succeeds, the flake is valid. If the hook fails, fix and re-commit. The hook also auto-formats `.nix` files with `nixpkgs-fmt` and re-stages them. The hook args are not immutable — if a better approach is found, update the hook in nixcfg.
3. **NEVER include AI/Claude attributions in commits** - No "Co-Authored-By: Claude", no "Generated with Claude", no Anthropic mentions.
4. **Do NOT commit temporary files** - Never stage files created for temporary purposes.

### Task Completion Standards
5. **Test tasks require PASS to be COMPLETE** - A task to "run test X" is NOT complete if the test fails. Documenting a failure is progress, but the task stays `IN_PROGRESS` until the test passes. Do NOT move to the next task until the current test-based task passes.
6. **NEVER mark failed tests as "complete with documentation"** - This creates tech debt breadcrumbs. Fix issues before moving on.

### Backend Parity Requirements
7. **NEVER defer tests for perceived redundancy** - This project establishes a parameterized embedded Linux build matrix. Every test that exists for one backend MUST be run for all backends. Do NOT make judgment calls about "overlapping" tests or "same code path" - run ALL tests to verify actual parity. The goal is identical test coverage across NixOS and Debian backends.
8. **Test parity is non-negotiable** - If NixOS has a test (simple, vlans, bonding-vlans, dhcp-simple), the Debian backend must have and pass the same test. No exceptions.

### Shell Command Practices
9. **ALWAYS single-quote Nix derivation references** - Use `nix build '.#thing'` to prevent zsh globbing.

### Container Image Pinning
10. **Use `tag@digest` syntax for container images** - Provides determinism (digest) + visibility (tag):
   ```yaml
   # CORRECT: tag for humans, digest for machines
   image: ghcr.io/siemens/kas/kas-isar:5.1@sha256:c60d32d7d6943e114affad0f8a0e9ec6d4c163e636c84da2dd8bde7a39f2a9bd

   # WRONG: mutable tag only
   image: ghcr.io/siemens/kas/kas-isar:5.1
   ```
   - Digest is authoritative for pulling (reproducibility)
   - Tag is documentation for humans (version visibility)
   - Get digest: `docker images --digests <image>`

### NixOS Test Driver & QEMU Process Management
11. **Orphaned nix build cleanup** - Prefer SIGTERM over SIGKILL (WSL mount safety):
   ```bash
   sudo kill -TERM <pid>; sleep 5; sudo kill -INT <pid>  # SIGKILL only as last resort
   ```
   If mounts break: `nix run '.#wsl-remount'` or `wsl --shutdown`

12. **PROACTIVE log monitoring** - Use `-L` flag, check BashOutput frequently, kill early on failure patterns.

13. **Session cleanup** - Verify no orphaned processes before new tests:
   ```bash
   pgrep -a qemu 2>/dev/null || echo "No QEMU"; pgrep -a nixos-test-driver 2>/dev/null || echo "No drivers"
   ```

## Project Status

- **Release**: 0.0.2 (tagged, published with release notes)
- **Plan 034**: **ACTIVE** (4/10 complete) - Dev Environment Validation and Team Adoption
  - T1a: Consolidate dev shells (promote debian→default, delete others) — COMPLETE
  - T1b: Port upstream platform-aware shell logic — COMPLETE
  - T1c: Dev shell validation CI workflow (basic) — COMPLETE
  - T1d: Harden shellHook — validate all host-environment prerequisites — COMPLETE
  - T1e-1: Tier 1 real test fixtures (F1-F7) — PENDING
  - T1e-2: Tier 2 macOS fixtures via Colima on `macos-15-intel` — PENDING
  - T1e-3: Tier 3 rationale + remaining Tier 2 (NixOS, WSL) — PENDING
  - T1f-1: DRY refactor: extract shared container engine detection into Nix functions — COMPLETE
  - T1f-2: Add Darwin+Podman path to shellHook and kas-build wrapper — PENDING
  - T1f-3: CI fixtures for Darwin+Podman — PENDING
  - Plan file: `docs/plans/034-dev-environment-and-adoption.md`
  - PR: https://github.com/kyosaku-kai/n3x/pull/6 (T1a-T1d pushed)
  - **CRITICAL**: Test fixtures must use real software on runner VMs. NO mocked binaries, NO fake scripts, NO container jobs (DinD breaks privileged kas-container testing). Use runner VMs directly with real package management (`apt-get install/remove`, `brew install`, `nix profile install`). See plan file T1e spec for fixture matrix and rationale.
  - **macOS CI constraint**: Only Colima works on GH Actions macOS runners (`macos-15-intel`). Podman Machine, Docker Desktop, Rancher Desktop, OrbStack all require nested virt that ARM runners don't support. Intel runner available until ~Aug 2027.
  - **Contract-based coverage**: ShellHook tests behavioral contracts (binary on PATH + version string + daemon reachable), not products. Testing with Colima validates Docker Desktop, Rancher Desktop (dockerd), OrbStack by contract equivalence.
  - **DRY violations**: Container engine detection duplicated in 4 places in flake.nix (Darwin shellHook, Linux shellHook, Darwin kas-build wrapper, Linux kas-build wrapper). Darwin wrapper hardcodes "docker" throughout. T1f refactors into shared `detect_container_engine` function.
- **Plan 033**: **COMPLETE** (7/7, T8 deferred) - CI Pipeline Refactoring
  - Plan file: `docs/plans/033-ci-pipeline-refactoring.md`
- **Test Infrastructure**: Fully integrated NixOS + Debian backends, 16-test parity matrix
- **BitBake Limits**: BB_NUMBER_THREADS=dynamic (min(CPUs, (RAM_GB-4)/3)), BB_PRESSURE_MAX_MEMORY=10000
- **ISAR Build Matrix**: 42 artifacts across 4 machines (qemuamd64, amd-v3c18i, qemuarm64, jetson-orin-nano)
  - All hashes tracked in `lib/debian/artifact-hashes.nix`
  - VM test results: 18 PASS, 1 EXCLUDED (swupdate-boot-switch)
  - `nix run '.'` is the default app (`isar-build-all`)

### Architecture

**GitHub Actions CI** (current, `.github/workflows/ci.yml`):
- Tiered pipeline: eval/lint → deb packages → NixOS VM tests → ISAR builds → Debian VM tests
- x86_64 on `ubuntu-latest`, aarch64 on `ubuntu-24.04-arm` (Cobalt 100)
- KVM-accelerated VM tests on GitHub-hosted runners
- `magic-nix-cache-action` for Nix store caching

**Target CI Architecture** (future, see `docs/nix-binary-cache-architecture-decision.md`):
- Self-managed EC2 runners (x86_64 + Graviton) for ISAR/Nix builds
- On-prem NixOS bare metal for: VM tests (KVM required), HIL tests
- Harmonia + ZFS binary cache, Caddy reverse proxy with internal CA

### ISAR Package Parity

Package requirements are verified at **Nix eval time**. Missing packages fail `nix flake check --no-build` immediately.

```
lib/debian/package-mapping.nix  →  Defines required packages (Nix→Debian mapping)
        ↓
lib/debian/verify-kas-packages.nix  →  Verifies kas YAMLs contain packages
        ↓
nix flake check --no-build  →  Fails if packages missing from kas overlays
```

See: [tests/README.md](tests/README.md#debian-backend-package-parity-verification-plan-016) for details.

### Key Architecture
- **Profiles** export data only (ipAddresses, interfaces, vlanIds)
- **mkNixOSConfig** transforms data → NixOS systemd.network modules
- **mkSystemdNetworkdFiles** transforms data → ISAR .network/.netdev files
- **mkK3sFlags.mkExtraFlags** transforms data → k3s CLI flags

### Test Commands
```bash
# NixOS tests
nix build '.#checks.x86_64-linux.k3s-cluster-simple'
nix build '.#checks.x86_64-linux.k3s-cluster-vlans'
nix build '.#checks.x86_64-linux.k3s-cluster-bonding-vlans'

# Debian backend tests
nix build '.#checks.x86_64-linux.debian-cluster-simple' -L
nix build '.#checks.x86_64-linux.debian-network-debug' -L
```

## Technical Learnings

### Nix Eval-Time Verification with lib.seq

**Problem**: `passthru` attributes on derivations aren't evaluated during `nix flake check` unless explicitly accessed. A verification that uses `passthru.verified = throw "error"` will silently pass.

**Solution**: Use `lib.seq` to force evaluation before derivation instantiation:
```nix
# WRONG: passthru.verified not evaluated during flake check
pkgs.runCommand "check" {} '' ... '' // { passthru.verified = verified; }

# RIGHT: lib.seq forces 'verified' to evaluate, throw fires at eval time
lib.seq verified (pkgs.runCommand "check" {} '' ... '')
```

**Use case**: Static verification checks that must fail during `nix flake check --no-build` rather than during the build phase.

### ISAR Test Framework
- Use NixOS VM Test Driver with ISAR-built .wic images (NOT Avocado)
- Test images need `nixos-test-backdoor` package via `kas/test-k3s-overlay.yml`
- VM derivation names must NOT use `run-<name>-vm` pattern

### ISAR Builds - CRITICAL

**Claude Code CAN and SHOULD run ISAR builds** using `nix develop -c`:

```bash
# CORRECT - Claude Code can run this directly
nix develop -c bash -c "cd backends/debian && kas-build kas/base.yml:kas/machine/qemu-amd64.yml:kas/packages/k3s-core.yml:kas/packages/debug.yml:kas/image/k3s-server.yml:kas/test-k3s-overlay.yml:kas/network/simple.yml:kas/node/server-1.yml"

# ALSO CORRECT - interactive shell then kas-build
nix develop
cd backends/debian
kas-build kas/base.yml:...

# WRONG - direct docker/podman bypasses kas-container, causes git safe.directory errors
docker run ... ghcr.io/siemens/kas/kas-isar:5.1 build ...
```

**The constraint is about DIRECT docker/podman invocation, NOT about Claude's ability to run builds.**

**Why kas-build wrapper is required**: The wrapper calls `kas-container --isar build`, which:
1. Handles user namespace mapping (prevents git safe.directory errors)
2. Manages WSL 9p filesystem unmounting (prevents sgdisk sync() hang)
3. Sets `KAS_CONTAINER_ENGINE=podman` and correct image version

**Build command structure**:
```
kas-build kas/base.yml:kas/machine/<machine>.yml:kas/packages/k3s-core.yml:kas/packages/debug.yml:kas/image/<role>.yml:kas/boot/grub.yml:kas/test-k3s-overlay.yml:kas/network/<profile>.yml:kas/node/<node>.yml
```

**CRITICAL**: Include `kas/boot/grub.yml` for correct GRUB bootloader with:
- `net.ifnames=0 biosdevname=0` - Legacy eth* naming for NixOS test driver
- `quiet loglevel=1` - Clean hvc0 for backdoor shell protocol
- `extra-space 512M` - Space for k3s runtime extraction

**Additional rules**:
- **ASK before rebuilds** - prefer test-level fixes over image changes
- **See `.claude/skills/isar-build.md`** for detailed procedures

### ISAR Build Matrix and `isar-build-all` (THE Primary Workflow)

**`nix run '.'`** is the default app and the command everyone should use. It orchestrates the
entire ISAR build matrix: build → rename → hash → register in nix store → update hashes file.

```bash
# Primary workflow commands:
nix run '.' -- --list                    # Show all 16 build variants
nix run '.' -- --variant base            # Build one variant
nix run '.' -- --machine qemuamd64       # Build all variants for one machine
nix run '.'                              # Build ALL 16 variants

# Post-build registration (skip kas-build, just register existing outputs):
nix run '.' -- --variant base-swupdate --rename-existing   # Rename + hash + register
nix run '.' -- --variant base-swupdate --hash-only         # Hash + register only

# Also accessible as:
nix run '.#isar-build-all' -- --help
```

**Three-file architecture** (critical to understand):
1. **`lib/debian/build-matrix.nix`** - Single source of truth for 16 variants.
   Defines machines, roles, boot modes, naming functions (`mkVariantId`, `mkArtifactName`,
   `mkIsarOutputName`, `mkAttrPath`, `mkKasCommand`).
2. **`lib/debian/artifact-hashes.nix`** - Mutable state: SHA256 hashes for all 42 artifacts.
   Updated by `isar-build-all` via sed after each build.
3. **`lib/debian/mk-artifact-registry.nix`** - Generator combining build-matrix + hashes
   into a `requireFile` attrset. Powers `isarArtifacts.qemuamd64.server.wic` etc.

**Why this matters**: Every ISAR VM test depends on artifacts being in the nix store.
`requireFile` fails at build time if the artifact is missing. `isar-build-all` is the ONLY
workflow that ensures artifacts are properly named, hashed, and registered.

**Key detail**: `base` and `base-swupdate` variants produce the SAME ISAR output filename
(`n3x-image-base-debian-trixie-qemuamd64.wic`) because they share `role = "base"`.
The `--rename-existing` flag copies to unique names to avoid collisions.

### ISAR VM Interface Naming

**QEMU NIC ordering**: net0 (user, restricted) is added first, then vlan1 (VDE switch).
- **With `net.ifnames=0`** (server/agent images via boot overlay): `eth0` (user), `eth1` (VDE)
- **Without `net.ifnames=0`** (base/swupdate images): `enp0s2` (user), `enp0s3` (VDE)
- The VDE switch is ALWAYS the second NIC device.
- Tests that use swupdate images must use `enp0s3` for cluster networking.
- Tests that use server/agent images use `eth1` for cluster networking.

### ISAR Recipe Cleaning and Build State Management

**NEVER manually delete build state files** (stamps, work dirs, sstate). Use kas-container's built-in cleaning commands:

```bash
# Clean specific recipe's build artifacts (keeps sstate and downloads)
# Use this when a recipe fails and needs rebuild
nix develop -c bash -c "cd backends/debian && kas-container --isar clean kas/machine/<machine>.yml:..."

# Clean build artifacts + sstate cache (keeps downloads)
# Use this for deeper clean - forces rebuild of all recipes
nix develop -c bash -c "cd backends/debian && kas-container --isar cleansstate kas/machine/<machine>.yml:..."

# Clean everything including downloads
# Nuclear option - full rebuild from scratch
nix develop -c bash -c "cd backends/debian && kas-container --isar cleanall kas/machine/<machine>.yml:..."
```

**Stale `.git-downloads` symlink** (common issue):
- Each kas-container session creates a new tmpdir (`/tmp/tmpXXXXXX`); `.git-downloads` symlink in the build work dir points to the previous session's tmpdir
- **Fix**: Remove before EVERY new build after a container session change:
  ```bash
  rm -f backends/debian/build/tmp/work/debian-trixie-arm64/.git-downloads
  rm -f backends/debian/build/tmp/work/debian-trixie-amd64/.git-downloads
  ```
- Integrate into build command: `rm -f backends/debian/build/tmp/work/debian-trixie-*/.git-downloads && nix develop -c bash -c "cd backends/debian && kas-build ..."`

**Download cache collision** (multi-arch):
- k3s recipe uses `downloadfilename=k3s` for BOTH architectures — x86_64 and arm64 binaries share the same cache key
- If switching architectures (e.g., qemuamd64 → jetson-orin-nano), the cached `k3s` binary is the wrong architecture
- **Fix**: Delete the cached binary AND its fetch stamps:
  ```bash
  rm -f ~/.cache/yocto/downloads/k3s ~/.cache/yocto/downloads/k3s.done
  rm -f backends/debian/build/tmp/stamps/debian-trixie-arm64/k3s-server/1.32.0-r0.do_fetch*
  rm -f backends/debian/build/tmp/stamps/debian-trixie-arm64/k3s-agent/1.32.0-r0.do_fetch*
  ```
- TODO: Fix k3s recipe to use arch-specific `downloadfilename` (e.g., `k3s-arm64` or `k3s-amd64`)

### ISAR Build Cache
- Shared cache: `DL_DIR="${HOME}/.cache/yocto/downloads"`, `SSTATE_DIR="${HOME}/.cache/yocto/sstate"`

### ZFS Replication Limitations

**ZFS does NOT support multi-master replication.** Key findings:
- `zfs send/recv` requires single-master topology (one writer, read-only replicas)
- If both source and destination have written past the last shared snapshot, they've "diverged" and cannot be merged
- Tools like zrep/zrepl are active-passive with failover, not simultaneous read-write

**For Nix binary caches with multiple active builders:**
- Use HTTP substituters instead of ZFS replication
- Each node: independent ZFS-backed `/nix/store` (for compression benefits)
- Each node: Harmonia serving local store
- Before building, Nix queries all substituters; downloads if found, builds if not
- Nix's content-addressing prevents conflicts (same derivation = same store path)

**ZFS value without replication:**
- zstd compression: 1.5-2x savings (500GB → 750-1000GB effective)
- Checksumming: Detects bit rot
- Snapshots: Pre-GC safety, instant rollback
- ARC cache: Intelligent read caching

### Test Timing Patterns

**"It works sometimes" = Timing Bug**. Diagnose with:
- ICMP works but TCP fails? → TCP establishment latency (add warm-up loop)
- Works on retry? → Missing readiness check (use `wait_until_succeeds`)
- Fails under load? → Fixed delay too short (replace `time.sleep` with polling)

**Avoid**: `time.sleep(N)` for service/network readiness
**Prefer**: Poll for expected condition with timeout

**Reference fix** (bonding-vlans TCP latency):
```python
# WRONG: Assume network ready after fixed delay
time.sleep(2)
server_2.succeed("systemctl start k3s-server.service")

# RIGHT: Warm up TCP connection before starting service
for attempt in range(3):
    code, out = server_2.execute("timeout 15 curl -sk https://server-1:6443/cacerts")
    if code == 0 or "cacerts" in out.lower():
        break
    time.sleep(2)
server_2.succeed("systemctl start k3s-server.service")
```

**Resolved latent issues**:
- Bond state verification via `/proc/net/bonding/bond0`
- Replaced `time.sleep(2)` with `wait_until_succeeds` IP polling

### WIC Generation Hang (WSL2)
- Cause: `sgdisk` sync() hangs on 9p mounts
- Solution: `kas-build` wrapper handles mount/unmount automatically

### Platform Support
| Platform | nixosTest Multi-Node | vsim (Nested Virt) |
|----------|---------------------|-------------------|
| Native Linux | YES | YES |
| WSL2 | YES | NO (2-level limit) |
| Darwin | YES* | NO |

### ISAR Kernel Selection Mechanism

**ISAR does NOT use Yocto's `PREFERRED_PROVIDER_virtual/kernel`.**

ISAR kernel selection uses `KERNEL_NAME`:
- `image.bbclass` sets `KERNEL_IMAGE_PKG = "linux-image-${KERNEL_NAME}"`
- `linux-kernel.bbclass` extracts `KERNEL_NAME_PROVIDED` from recipe name (e.g., `linux-tegra` → `tegra`)
- Machine conf sets `KERNEL_NAME ?= "arm64"` (default = stock Debian)
- To override: `KERNEL_NAME = "tegra"` in kas overlay `local_conf_header`

### QEMU User-Mode for ISAR aarch64 Builds

**WSL2 NixOS can build ISAR aarch64 images via QEMU user-mode emulation.**

- User's WSL kernel: Custom, based on NixOS-WSL project
- Requires binfmt_misc registration with F (fix binary) and C (credentials) flags
- Static QEMU binary from `nixpkgs#pkgsStatic.qemu-user`
- First build (stock Debian kernel, no kernel compile): ~14 minutes
- Kernel compile under QEMU TCG emulation: KILLED after 2h49m, still on do_dpkg_build
  - All 20 vCPUs pegged at 100%, 8 parallel qemu-aarch64 gcc processes
  - CPU-bound (4.5G/27.4G RAM used), no I/O bottleneck
  - TCG overhead ~10-20x vs native for compiler workloads
- **Cross-compilation fix committed (f3011b8)**: Removed ISAR_CROSS_COMPILE="0" from
  jetson-orin-nano.yml. ISAR default (="1") uses host cross-toolchain.
- **Cross-compile VALIDATED (2026-02-11)**: Kernel cross-compile succeeded in ~22 minutes
  - `CROSS_COMPILE=aarch64-linux-gnu-` confirmed in build log
  - `tegra234-enable.cfg` config fragment merged successfully
  - `linux-image-tegra` (6.12.69+r0) in image manifest
  - nvidia-l4t-core + nvidia-l4t-tools (36.4.4) installed
  - vmlinux: 40MB (tegra) vs 37MB (stock Debian arm64)
  - Full build with sstate: ~30 minutes total
  - Improvement: 22min vs 2h49m+ (killed) under TCG emulation
- Persistent binfmt config: VALIDATED (2026-02-12) — nixcfg WSL module (`binfmt.enable = true`) produces
  correct `systemd-binfmt.service` registration with POCF flags at boot. No manual registration needed.
  See `docs/binfmt-requirements.md` for details.

### AWS AMI Registration (register-ami.sh)

- AWS `register-image --architecture` accepts `x86_64` or `arm64` (NOT `aarch64`)
- Script maps: `--arch aarch64` → `AWS_ARCH="arm64"` for the API call
- Uses `jq` (not python3) for JSON parsing — lighter dependency
- EXIT trap handles S3 cleanup on script failure

### Infra Flake Input Management

- **nixos-generators**: Archived 2026-01-30, upstreamed to nixpkgs 25.05.
  **Removed as flake input** (2026-02-16): initially replaced with manual
  `system.build.amazonImage` via builder module import. **Migrated to native
  `system.build.images.amazon` API** (2026-02-16): the 25.11 image framework
  (`nixos/modules/image/images.nix`) auto-imports all 26 image builders.
  AMI-only config (e.g., `first-boot-format`) is injected via `image.modules.amazon`
  deferred module — lives only in the image variant, not the base nixosConfiguration.
- **ALWAYS use native NixOS 25.11 image APIs** (`system.build.images.*`) — not manual
  builder module imports from `maintainers/scripts/ec2/`. The `image.modules.*`
  deferred module pattern cleanly separates image-specific config from base config.
- **nixos-anywhere**: Not needed as a flake input — run from upstream flake directly.
  Was adding 14 transitive lock entries including a separate nixpkgs tree.
- **Caddyfile v2 syntax**: Use named matchers (`@name path /...`) for path-specific
  headers, not nested `{path ...}` inside header values.

### NixOS 25.11 Migration Workarounds

**Migration date**: 2026-02-16. Both flakes migrated from nixpkgs master (main) / 24.11 (infra) to 25.11.

1. **`services.resolved.settings` → individual options** (commit `ffbedba`)
   - `services.resolved.settings.Resolve` is a master-only freeform attrset API, not on 25.11
   - File: `backends/nixos/modules/common/networking.nix:168`
   - Fix: `dnssec`, `dnsovertls`, `fallbackDns` as individual options; `DNSStubListener`,
     `ReadEtcHosts`, `Cache`, `CacheFromLocalhost` via `extraConfig`
   - WORKAROUND: When nixpkgs upstreams `services.resolved.settings` to stable, revert to
     structured attrset form. Check 26.05 release notes.

2. **ISAR test driver API: `python3Packages` as attrset** (commit `dd30372`)
   - On master, test driver accepts individual Python packages as args. On 25.11, it takes
     `python3Packages` as a single attrset.
   - File: `tests/lib/debian/mk-debian-test.nix:153-154`
   - API-ADAPTATION: Not a workaround — 25.11 API is the canonical form. Master's destructured
     args are the newer (unreleased) pattern.

3. **nixpkgs fork still required** — `virtualisation.bootDiskAdditionalSpace` not upstreamed
   - Fork: `timblaktu/nixpkgs/vm-bootloader-disk-size` rebased onto `nixos-25.11`
   - TODO: Submit upstream PR to nixpkgs, then drop fork

4. **gitlab-runner `authenticationTokenConfigFile`** (commit `53f7032`)
   - `registrationConfigFile` deprecated in GitLab 16.0+, removed in 18.0
   - File: `infra/nixos-runner/modules/gitlab-runner.nix`
   - Added new option + mutual exclusion assertion. Both old and new work.

### Key Files
- `lib/network/mk-network-config.nix` - Unified NixOS module generator
- `lib/k3s/mk-k3s-flags.nix` - Shared K3s flag generator
- `tests/lib/mk-k3s-cluster-test.nix` - Parameterized test builder
- `secrets/.sops.yaml` - SOPS configuration with public keys

## References
- [tests/README.md](tests/README.md) - Testing framework
- [docs/SECRETS-SETUP.md](docs/SECRETS-SETUP.md) - Secrets management
- [docs/ISAR-L4-TEST-ARCHITECTURE.md](docs/ISAR-L4-TEST-ARCHITECTURE.md) - ISAR L4 cluster test design
- [docs/binfmt-requirements.md](docs/binfmt-requirements.md) - Cross-architecture binfmt_misc requirements
- [docs/nix-binary-cache-architecture-decision.md](docs/nix-binary-cache-architecture-decision.md) - Binary cache ADR
- [docs/plans/034-dev-environment-and-adoption.md](docs/plans/034-dev-environment-and-adoption.md) - Dev environment validation and team adoption plan
- [docs/plans/033-ci-pipeline-refactoring.md](docs/plans/033-ci-pipeline-refactoring.md) - CI pipeline refactoring plan
- ALWAYS ask before adding packages to ISAR images
