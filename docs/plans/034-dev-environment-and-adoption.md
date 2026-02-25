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
| 1e | CI matrix for shellHook host-environment detection paths | TASK:PENDING |

## Task Dependencies

```
T1a,T1b (shell consolidation + platform logic) ──> T1c (basic CI workflow)
T1c ──> T1d (harden shellHook host-environment validation)
T1d ──> T1e (CI matrix validating all host-environment paths)
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

### Task 1e: CI matrix for shellHook host-environment detection paths

**Status**: `TASK:PENDING`

**Problem**: The current `dev-shells.yml` only tests 2 of 13+ shellHook code paths — docker-running on Linux and no-docker on macOS. The other paths (podman, nerdctl, WSL, no-runtime, daemon-stopped, binfmt missing) have zero CI coverage. The dev shell claims to work on "any host with Nix" but only validates two specific host configurations.

**Goal**: Expand CI to validate every reachable shellHook code path by manipulating the host environment on GitHub runners. Each scenario simulates a real developer's machine state and asserts the shellHook produces correct behavior (engine detection, warnings, failures, guidance).

**Test structure per scenario**:
1. **Setup**: install/remove/mock tools, stop services, set env vars
2. **Run**: `nix develop --command bash -c '...'` capturing shellHook stdout + `KAS_CONTAINER_ENGINE` value
3. **Assert**: expected output patterns (warnings/errors) and expected engine value (or UNSET)

**Linux scenarios** (ubuntu-24.04):

| ID | Scenario | Setup | Expected ENGINE | Expected output |
|----|----------|-------|-----------------|-----------------|
| L1 | docker running | (default runner state) | docker | "docker version:" |
| L2 | docker stopped | `sudo systemctl stop docker docker.socket` | UNSET | "daemon not running" |
| L3 | podman only | `sudo apt-get install -y podman` + hide docker | podman | "podman version:" |
| L4 | no runtime | hide docker and podman from PATH | UNSET | "No container runtime found" |
| L5 | nerdctl mock | mock `/usr/local/bin/docker` outputting nerdctl | UNSET | "containerd mode" |

**Linux WSL-simulated** (ubuntu-24.04 + `WSL_DISTRO_NAME=ci-test`):

| ID | Scenario | Setup | Expected ENGINE | Expected output |
|----|----------|-------|-----------------|-----------------|
| W1 | WSL + podman | install podman, hide docker | podman | "WSL2 Environment" + "podman version:" |
| W2 | WSL + docker | (default + env var) | docker | "WSL2 Environment" + "docker version:" |
| W3 | WSL + none | hide both | UNSET | "No container runtime found" |

**macOS scenarios** (macos-latest):

| ID | Scenario | Setup | Expected ENGINE | Expected output |
|----|----------|-------|-----------------|-----------------|
| M1 | no docker | (default runner state) | UNSET | "Docker not found" |
| M2 | nerdctl mock | mock docker outputting nerdctl | UNSET | "containerd mode" |

**Implementation notes**:

- "Hide docker" = `sudo mv /usr/bin/docker /usr/bin/docker.bak` (restore in post step)
- "Nerdctl mock" = `printf '#!/bin/sh\necho "nerdctl version 1.7.0"' > /usr/local/bin/docker && chmod +x /usr/local/bin/docker`
- WSL simulation only tests the env-var-gated code path, not actual WSL behavior (9p mounts, etc.)
- The Nix-store-podman-on-non-NixOS path (path 11) is hard to mock and may be deferred — it requires a binary at `/nix/store/*/bin/podman` without `/etc/NIXOS` existing
- Each scenario is a separate matrix entry with `fail-fast: false` so all paths are tested even if one fails

**DoD**:
1. All 10 testable scenarios (L1-L5, W1-W3, M1-M2) pass in CI
2. Each scenario asserts on both output content and `KAS_CONTAINER_ENGINE` value
3. Assertions validate the T1d hardened behavior (fail/flag on ERROR paths)
4. Path 11 (Nix-store podman) either tested or explicitly deferred with rationale
