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

#### Fixture design: additive from minimal bases

**Key insight**: GitHub Actions supports `container:` jobs that run steps inside a specified Docker image. Instead of using the bloated `ubuntu-24.04` runner (which has Docker, Go, Java, etc. pre-installed) and removing software, use minimal container images and install only what each fixture needs. This is how real developer machines work — you start with an OS and install your tools.

**When to use container jobs vs regular runners:**
- Container jobs (minimal image + additive installs): fixtures where Docker is NOT present, or where we need a different base OS (NixOS, minimal Ubuntu/Debian)
- Regular runner directly: fixtures where Docker IS present and running (ubuntu-24.04 has a real Docker daemon; this is a legitimate fixture as-is)
- macOS runner directly: no container option for macOS

#### Test fixture matrix

**Tier 1 — Immediately feasible on GH runners:**

| ID | Fixture | Runner/Container | Setup | Expected |
|----|---------|------------------|-------|----------|
| F1 | Ubuntu + Docker running | `ubuntu-24.04` runner | default state | OK: engine=docker |
| F2 | Ubuntu + Docker stopped | `ubuntu-24.04` runner | `systemctl stop docker.socket docker.service` | ERROR: "daemon not running" |
| F3 | Minimal Linux + podman (apt) | container: `ubuntu:24.04` | install Nix + podman via apt | OK: engine=podman |
| F4 | Minimal Linux + no runtime | container: `ubuntu:24.04` | install Nix only | ERROR: "No container runtime found" |
| F5 | Minimal Linux + real nerdctl as docker | container: `ubuntu:24.04` | install Nix + real nerdctl binary, symlink as `docker` | ERROR: "containerd mode" |
| F6 | Minimal Linux + podman via Nix (non-NixOS) | container: `ubuntu:24.04` | install Nix, `nix profile install nixpkgs#podman`, no `/etc/NIXOS` | ERROR: "Nix store" path rejection |
| F7 | macOS + no Docker | `macos-latest` runner | default state | ERROR: "Docker not found" |
| F8 | macOS + real nerdctl as docker | `macos-latest` runner | install real nerdctl, symlink as `docker` | ERROR: "containerd mode" |

**Tier 2 — Needs research before implementation:**

| ID | Fixture | Question |
|----|---------|----------|
| F9 | NixOS + Nix-store podman | Does `nixos/nix` or a NixOS container image work for container jobs? Need `/etc/NIXOS` to exist and podman at `/nix/store/*/bin/podman`. This tests OK path 5 — the only path where Nix-store podman is accepted. |
| F10 | WSL + podman | Can `WSL_DISTRO_NAME` env var reliably trigger the WSL branch? This is partial (doesn't test 9p mounts, kas-build wrapper WSL logic). Real WSL testing needs Windows runner + WSL2. Research both options. |
| F11 | WSL + Docker | Same as F10 but with Docker instead of podman. |
| F12 | macOS + Docker | Is there a headless Docker option on macOS GH runners? (`colima`, `lima`, `docker-machine`?) If feasible, this tests OK path 1 — currently untested. |

**Tier 3 — Deferred (self-hosted or impractical in CI):**

| ID | Fixture | Reason |
|----|---------|--------|
| F13 | macOS + Rancher Desktop (dockerd) | GUI application, can't install headlessly in CI. Tests OK path 2. |
| F14 | macOS + Docker daemon stopped | Requires Docker installed first (F12 prerequisite), then stop daemon. |
| F15 | Real WSL2 on Windows | Requires Windows runner + WSL2 + Nix inside WSL. Complex, high runner cost. |

#### Implementation approach for container jobs

Container jobs need Nix installed. Two options:
- **Option A**: Use `nixos/nix` as base image (Nix pre-installed, but not minimal Ubuntu)
- **Option B**: Use `ubuntu:24.04` as base + install Nix via determinate systems installer

Option B is preferred for most fixtures because it matches the real developer experience (Ubuntu user installs Nix). Option A may be needed for the NixOS fixture (F9).

**Test structure per fixture:**
1. Runner/container provides the base OS
2. Setup step installs Nix (if container job) and fixture-specific software
3. Run step: `nix develop --command bash -c 'echo "ENGINE=${KAS_CONTAINER_ENGINE:-UNSET}"'` capturing all output
4. Assert step: verify exit code, output patterns, and engine value

**All fixtures run with `fail-fast: false`** so every fixture is tested regardless of individual failures.

#### Sub-tasks

- **T1e-1**: Implement Tier 1 fixtures (F1-F8). Research whether `nix develop` works reliably inside GH Actions container jobs with `ubuntu:24.04` base image. If container jobs prove problematic, document issues and fall back to runner-based approach with clear rationale.
- **T1e-2**: Research Tier 2 fixtures (F9-F12). Document findings in this plan file. Implement any that are feasible.
- **T1e-3**: Implement researched Tier 2 fixtures. Update Tier 3 rationale if anything became feasible.

#### DoD

1. All Tier 1 fixtures (F1-F8) pass in CI
2. Each fixture asserts exit code, output pattern, and `KAS_CONTAINER_ENGINE` value
3. Tier 2 research documented with findings and decisions
4. Tier 3 deferred fixtures have explicit rationale
5. No mocked binaries — every fixture uses real software or genuine absence
