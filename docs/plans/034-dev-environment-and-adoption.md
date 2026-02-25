# Plan 034: Dev Environment Validation and Team Adoption

**Status**: `PLAN:ACTIVE`
**Created**: 2026-02-24
**Repo**: n3x-public (kyosaku-kai/n3x)

## Context

The n3x-public repo is live on GitHub with 22/22 CI checks passing, release automation validated (0.0.2), and repository rulesets configured. The next phase is validating the developer experience across all claimed platforms.

The flake now defines a single `default` dev shell with platform-aware logic (WSL detection, container runtime auto-detection, binfmt validation, Rancher Desktop nerdctl detection) ported from upstream `fix/container-runtime-cross-arch` work. The shell works on both `x86_64-linux` and `aarch64-darwin`. The unused specialized shells (`k3s`, `test`, old NixOS-admin `default`) were deleted.

## Task Progress

| Task | Description | Status |
|------|-------------|--------|
| 1a | Consolidate dev shells — promote debian to default | TASK:COMPLETE |
| 1b | Port upstream platform-aware shell logic | TASK:COMPLETE |
| 1c | Dev shell validation CI workflow (basic) | TASK:COMPLETE |
| 1d | Harden shellHook — validate all host-environment prerequisites | TASK:COMPLETE |
| 1e-1 | Tier 1 fixtures: real test environments (F1-F8) | TASK:PENDING |
| 1e-2 | Tier 2 research: NixOS, WSL, macOS+Docker feasibility | TASK:PENDING |
| 1e-3 | Tier 2 implementation + Tier 3 rationale | TASK:PENDING |

## Task Dependencies

```
T1a,T1b (shell consolidation + platform logic) ──> T1c (basic CI workflow)
T1c ──> T1d (harden shellHook host-environment validation)
T1d ──> T1e-1 (Tier 1 real fixtures F1-F8)
T1d ──> T1e-2 (Tier 2 research: NixOS, WSL, macOS+Docker)
T1e-2 ──> T1e-3 (Tier 2 implementation)
```

---

## Task Definitions

### Task 1a: Consolidate dev shells

**Status**: `TASK:COMPLETE`
**Commits**: `de62aec`

Promoted the `debian` shell to `default`. Deleted `k3s`, `test`, and old NixOS-admin `default` shells (zero consumers outside flake.nix). Renamed `mkDebianShell` → `mkDevShell`, shell name `"n3x-debian"` → `"n3x"`. Updated all `.#debian` references across docs and scripts to bare `nix develop`.

### Task 1b: Port upstream platform-aware shell logic

**Status**: `TASK:COMPLETE`
**Commits**: (see git log)

Ported from upstream:

**shellHook changes**:
- Darwin: Rancher Desktop nerdctl detection, conditional `KAS_CONTAINER_ENGINE` export
- Linux WSL: podman-first with docker fallback, `WSL_DISTRO` env var fallback
- Linux non-WSL: docker-first preference (avoids sudo PATH issues), Nix-store podman warning for non-NixOS, full no-runtime guidance
- Removed `podman` from Nix `buildInputs` — must be system-installed

**kas-build wrapper changes**:
- Darwin: nerdctl detection, host/target arch detection, native-build.yml overlay
- Linux: `WSL_DISTRO` fallback, container engine auto-detection, arch detection, binfmt_misc validation for cross-arch builds

### Task 1c: Dev shell validation CI workflow

**Status**: `TASK:COMPLETE`

**Goal**: Replace the current `dev-shells.yml` (which tests the wrong thing) with a CI workflow that validates the actual developer onboarding experience on Linux and macOS.

**What to test** (single `default` shell on both platforms):

1. **Shell entry**: `nix develop --command bash -c 'echo OK'` succeeds
2. **Key tools on PATH**: `kas`, `jq`, `yq`, `kas-build`, `kas-container`
3. **shellHook completes without error** (captures platform detection output)
4. **Tool functionality**: `kas --version`, `kas-build --help` (validates wrapper is executable)

**Platforms and runners**:
- `ubuntu-24.04` (x86_64-linux): Full validation
- `macos-latest` (aarch64-darwin): Shell entry + tools (no Docker on GH runners, so shellHook will warn about missing Docker — that's expected)

**Trigger**: Only on changes to `flake.nix`, `flake.lock`, or `backends/debian/kas/**` — not every push.

**DoD**:
1. `.github/workflows/dev-shells.yml` replaced with focused workflow
2. Passes on both Ubuntu 24.04 and macOS
3. Validates tool availability and shellHook execution

---

### Task 1d: Harden shellHook — validate all host-environment prerequisites

**Status**: `TASK:COMPLETE`
**Commits**: `a970213`
**Decision**: Option A (hard fail) — shellHook calls `exit 1` on all 8 error paths

**What was done**:
- All 8 error paths now call `exit 1` (shell entry fails entirely when prerequisites aren't met)
- All error messages use ANSI red coloring (`echo -e` with `\033[0;31m`) for visibility
- All 5 OK paths unchanged (export `KAS_CONTAINER_ENGINE` correctly)
- Decision documented in code comment at Darwin branch entry point
- CI workflow (`dev-shells.yml`) updated: macOS step now verifies hard-fail behavior (expects rejection + "Docker not found" message) instead of expecting warn-and-continue

**Error paths hardened** (all `exit 1`):
- Darwin: docker missing (path 1), nerdctl detected (path 2), daemon stopped (path 3)
- Linux WSL: no runtime found (path 7)
- Linux non-WSL: nerdctl detected (path 8), daemon stopped (path 10), Nix-store podman on non-NixOS (path 11), no runtime found (path 13)

**Note on binfmt_misc** (prerequisite #5): Not added to shellHook validation. binfmt is only needed for cross-arch builds, not all builds. It remains validated in the kas-build wrapper where the target architecture is known. Adding it to shellHook would reject native-arch-only developers unnecessarily.

**DoD assessment**:
1. Every ERROR path produces actionable guidance — YES
2. Every ERROR path prevents kas-build from running — YES (`exit 1` kills the shell)
3. Every OK path exports `KAS_CONTAINER_ENGINE` correctly — YES (unchanged)
4. Behavior consistent across all 3 platform branches — YES
5. Decision documented in code comments — YES (flake.nix line 594-596)

---

### Task 1e: CI matrix — real test fixtures for every claimed dev environment

**Status**: `TASK:PENDING`

**Previous attempt (reverted)**: Commits `32de225` + `990dd16` used a mocking approach — moving docker binaries, creating fake nerdctl scripts, setting `WSL_DISTRO_NAME` env vars on regular ubuntu runners. This tested bash branching logic, not real environments. Reverted because it doesn't prove the dev shell works on actual developer machines.

**Principle**: Each CI matrix entry must be a **real test fixture** — a runner or container with a genuine OS baseline and real software installed (or genuinely absent). Start from **minimal base images and add** what each fixture needs, rather than starting from a bloated runner image and subtracting.

**Goal**: Prove the dev shell works (or correctly rejects) on every environment the project claims to support. Each fixture represents a real developer's machine configuration.

#### What the flake claims to support

The flake defines `devShells` for `x86_64-linux` and `aarch64-darwin`. The shellHook detects and validates:

**OK paths** (shell enters, `KAS_CONTAINER_ENGINE` exported):
1. Darwin + Docker Desktop → `docker`
2. Darwin + Rancher Desktop (dockerd/moby mode) → `docker`
3. Linux non-WSL + Docker running → `docker`
4. Linux non-WSL + system podman → `podman`
5. Linux non-WSL + Nix-store podman on NixOS → `podman`
6. Linux WSL + system podman → `podman`
7. Linux WSL + Docker → `docker`

**ERROR paths** (shell rejects with `exit 1` and guidance):
8. Darwin + no Docker
9. Darwin + nerdctl/containerd mode
10. Darwin + Docker daemon stopped
11. Linux non-WSL + nerdctl/containerd mode
12. Linux non-WSL + Docker daemon stopped
13. Linux non-WSL + Nix-store podman on non-NixOS
14. Linux non-WSL + no runtime
15. Linux WSL + no runtime

#### Fixture design: runner VMs with real package management

**No container jobs.** The dev shell's purpose is to prepare for `kas-container`, which runs privileged containers. Testing inside a GH Actions `container:` job would require Docker-in-Docker or podman-in-container — adding complexity that doesn't represent any real developer's machine and may not work for privileged execution.

GitHub Actions runners ARE VMs. They are the test fixtures. Configure them with real package management:
- **Install**: `sudo apt-get install podman`, `nix profile install nixpkgs#podman`, `brew install nerdctl`
- **Remove**: `sudo apt-get remove docker-ce docker-ce-cli containerd.io` (real package removal, not `mv`)
- **Stop services**: `sudo systemctl stop docker.socket docker.service` (real daemon state change)

The `ubuntu-24.04` runner comes with Docker pre-installed. For fixtures that need Docker, use it as-is. For fixtures that need no Docker, remove the Docker packages. For fixtures that need podman, install it via apt. This mirrors what real developers do on their machines.

#### Test fixture matrix

**Tier 1 — Immediately feasible on GH runners:**

| ID | Fixture | Runner | Setup | Expected |
|----|---------|--------|-------|----------|
| F1 | Ubuntu + Docker running | `ubuntu-24.04` | default state | OK: engine=docker |
| F2 | Ubuntu + Docker stopped | `ubuntu-24.04` | `systemctl stop docker.socket docker.service` | ERROR: "daemon not running" |
| F3 | Ubuntu + podman (apt) | `ubuntu-24.04` | `apt-get remove docker*`, `apt-get install podman` | OK: engine=podman |
| F4 | Ubuntu + no runtime | `ubuntu-24.04` | `apt-get remove docker*` | ERROR: "No container runtime found" |
| F5 | Ubuntu + real nerdctl | `ubuntu-24.04` | `apt-get remove docker*`, install real nerdctl binary, symlink as `docker` | ERROR: "containerd mode" |
| F6 | Ubuntu + podman via Nix (non-NixOS) | `ubuntu-24.04` | `apt-get remove docker*`, `nix profile install nixpkgs#podman` | ERROR: "Nix store" path rejection |
| F7 | macOS + no Docker | `macos-latest` | default state (no Docker on GH macOS runners) | ERROR: "Docker not found" |
| ~~F8~~ | ~~macOS + Rancher Desktop (containerd)~~ | ~~`macos-latest`~~ | ~~Rancher Desktop in containerd mode (docker = nerdctl)~~ | ~~ERROR: "containerd mode"~~ |

**F8 moved to Tier 3**: Rancher Desktop is a GUI application that can't be installed headlessly in CI. The containerd mode (where `docker` is actually nerdctl) is the same scenario as F13 (dockerd mode) — both require Rancher Desktop installed. The nerdctl detection logic (`docker -v | grep -qi nerdctl`) is validated by F5 on Linux — same grep check, same code path. A standalone nerdctl binary can't be installed either: nerdctl publishes no macOS binaries (GitHub releases: Linux/FreeBSD/Windows only) and the Homebrew formula is Linux-only.

**macOS fixture coverage summary**: The shellHook has 4 macOS use cases:
1. Bare macOS (no container tools) → **F7 (Tier 1, implemented)**
2. Docker Desktop installed → **F9 (Tier 2, needs headless Docker research)**
3. Rancher Desktop in dockerd/moby mode → **F13 (Tier 3, GUI app)**
4. Rancher Desktop in containerd mode → **F8 (Tier 3, GUI app + no standalone nerdctl)**

**Tier 2 — Needs research before implementation:**

| ID | Fixture | Question |
|----|---------|----------|
| F9 | macOS + Docker Desktop | Is there a headless Docker option on macOS GH runners? (`colima`, `lima`, `docker-machine`?) If feasible, this tests OK path 1 — Darwin happy path, currently untested. |
| F10 | NixOS + Nix-store podman | How to get a NixOS-like environment on a GH runner? Need `/etc/NIXOS` to exist and podman at `/nix/store/*/bin/podman`. Tests OK path 5. Options: NixOS self-hosted runner, or create `/etc/NIXOS` marker + nix-installed podman on ubuntu (semi-synthetic but tests the real code path). |
| F11 | WSL + podman | Real WSL testing needs Windows runner + WSL2 + Nix inside WSL. Research feasibility and cost. Alternative: `WSL_DISTRO_NAME` env var on Linux runner (partial — tests env-var code path but not WSL-specific behavior like 9p mounts). |
| F12 | WSL + Docker | Same as F11 but with Docker. |

**Tier 3 — Deferred (self-hosted or impractical in CI):**

| ID | Fixture | Reason |
|----|---------|--------|
| F8 | macOS + Rancher Desktop (containerd) | GUI application, can't install headlessly in CI. nerdctl has no standalone macOS binary. Detection logic validated by F5 on Linux. |
| F13 | macOS + Rancher Desktop (dockerd) | GUI application, can't install headlessly in CI. Tests OK path 2. |
| F14 | macOS + Docker daemon stopped | Requires Docker installed first (F9 prerequisite). Implement after F9 if feasible. |
| F15 | Real WSL2 on Windows | Requires Windows runner + WSL2 + Nix inside WSL. Complex, high runner cost. Document as self-hosted-only if F11 research shows GH Windows runners can't do this. |

#### Implementation approach

All fixtures use runner VMs directly. Setup steps use real package management.

**Test structure per fixture:**
1. Setup step: install/remove real packages, start/stop real services
2. Run step: `nix develop --command bash -c 'echo "ENGINE=${KAS_CONTAINER_ENGINE:-UNSET}"'` capturing all output
3. Assert step: verify exit code, output patterns, and engine value

**All fixtures run with `fail-fast: false`** so every fixture is tested regardless of individual failures.

**nerdctl installation** (F5, F8): Download the real nerdctl binary from the official GitHub release. Create a `docker` symlink pointing to it. This is what Rancher Desktop containerd mode does — `docker` is actually nerdctl. The shellHook's `docker -v | grep -qi nerdctl` check runs against the real nerdctl binary output.

**Docker removal** (F3-F6): Use `sudo apt-get remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin` or similar to genuinely uninstall Docker packages. Verify with `! command -v docker` post-removal. This is a real package state, not a moved binary.

#### Sub-tasks

- **T1e-1**: Implement Tier 1 fixtures (F1-F7) on runner VMs with real package management. F8 (macOS + nerdctl) deferred to Tier 2 — nerdctl has no macOS binary. Validate `apt-get remove` fully removes docker on ubuntu-24.04 runners. Validate real nerdctl binary download (v2.2.1 linux-amd64) and F6 Nix-store podman detection via `nix build --print-out-paths` PATH injection.
- **T1e-2**: Research Tier 2 fixtures (F9-F12). Document findings in this plan file. Implement any that are feasible.
- **T1e-3**: Implement researched Tier 2 fixtures. Update Tier 3 rationale if anything became feasible.

#### DoD

1. All Tier 1 fixtures (F1-F7) pass in CI (F8 deferred — no macOS nerdctl binary)
2. Each fixture asserts exit code, output pattern, and `KAS_CONTAINER_ENGINE` value
3. Tier 2 research documented with findings and decisions
4. Tier 3 deferred fixtures have explicit rationale
5. No mocked binaries, no container jobs, no fake scripts — every fixture uses real software on real runner VMs
