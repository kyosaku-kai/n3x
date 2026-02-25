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
| 1c | Dev shell validation CI workflow | TASK:COMPLETE |

## Task Dependencies

```
T1a,T1b (shell consolidation + platform logic) ──> T1c (CI workflow)
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
