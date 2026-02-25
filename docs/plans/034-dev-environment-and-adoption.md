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
| 1e-1 | Tier 1 fixtures: real test environments (F1-F7) | TASK:COMPLETE |
| 1e-2 | Tier 2 research + implementation: macOS+Docker, macOS+nerdctl via Colima | TASK:PENDING |
| 1e-3 | Tier 3 rationale + remaining Tier 2 (NixOS, WSL) | TASK:PENDING |
| 1f-1 | DRY refactor: extract shared container engine detection into Nix functions | TASK:COMPLETE |
| 1f-2 | Add Darwin+Podman path to shellHook and kas-build wrapper | TASK:PENDING |
| 1f-3 | CI fixtures for Darwin+Podman (Tier 2/3 as feasible) | TASK:PENDING |

## Task Dependencies

```
T1a,T1b (shell consolidation + platform logic) ──> T1c (basic CI workflow)
T1c ──> T1d (harden shellHook host-environment validation)
T1d ──> T1e-1 (Tier 1 real fixtures F1-F7)
T1d ──> T1e-2 (Tier 2: macOS fixtures via Colima)
T1e-2 ──> T1e-3 (Tier 3 rationale + remaining Tier 2)
T1d ──> T1f-1 (DRY refactor: shared detection functions)
T1f-1 ──> T1f-2 (Darwin+Podman shellHook + kas-build)
T1f-2 ──> T1f-3 (Darwin+Podman CI fixtures)
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
3. Darwin + Colima (Docker mode) → `docker`
4. Darwin + Podman Machine → `podman` *(NEW — requires T1f-2)*
5. Linux non-WSL + Docker running → `docker`
6. Linux non-WSL + system podman → `podman`
7. Linux non-WSL + Nix-store podman on NixOS → `podman`
8. Linux WSL + system podman → `podman`
9. Linux WSL + Docker → `docker`

**ERROR paths** (shell rejects with `exit 1` and guidance):
10. Darwin + no container runtime *(updated from "no Docker")*
11. Darwin + nerdctl/containerd mode (Rancher Desktop or Colima containerd)
12. Darwin + Docker daemon stopped (and no podman)
13. Darwin + Podman Machine not running (and no docker) *(NEW — requires T1f-2)*
14. Linux non-WSL + nerdctl/containerd mode
15. Linux non-WSL + Docker daemon stopped (and no podman)
16. Linux non-WSL + Nix-store podman on non-NixOS
17. Linux non-WSL + no runtime
18. Linux WSL + no runtime

#### Contract-based coverage model (research finding, 2026-02-25)

The shellHook tests **behavioral contracts**, not specific products. The three checks it performs are:
1. `command -v docker` / `command -v podman` — is the binary on PATH?
2. `docker -v | grep -qi nerdctl` — is the binary actually nerdctl?
3. `docker info` / `podman info` — can it reach a running daemon/machine?

These checks behave identically regardless of which product provides the binary. Testing with one Docker-compatible tool (e.g., Colima) validates all tools satisfying the same contract (Docker Desktop, Rancher Desktop dockerd mode, OrbStack). This is why Colima serves as a CI proxy for Docker Desktop and Rancher Desktop (dockerd mode).

**Coverage guarantees by contract:**

| Contract | CI fixture(s) | Real-world products covered |
|---|---|---|
| Docker-compatible daemon running | F1 (Linux), F8 (macOS via Colima) | Docker Desktop, Colima, Rancher Desktop (dockerd), OrbStack |
| nerdctl masquerading as docker | F5 (Linux), F9 (macOS via Colima containerd) | Rancher Desktop (containerd mode), Colima containerd mode |
| Docker daemon stopped | F2 (Linux), F10 (macOS via Colima) | Any stopped docker daemon on any product |
| System podman running | F3 (Linux), F11 (macOS via Podman Machine)* | System podman (apt/dnf), Podman Machine |
| Nix-store podman on non-NixOS | F6 (Linux) | Nix-installed podman on Ubuntu/Debian/Fedora |
| No container runtime | F4 (Linux), F7 (macOS) | Clean system |

*F11 is Tier 3 (Podman Machine doesn't work on GH runners). The `command -v podman` + `podman info` contract is validated by F3 on Linux. Darwin-specific code path (error messages, detection ordering) validated by code review + manual testing.

#### macOS container runtime research (2026-02-25)

**The fundamental constraint**: Every macOS container runtime requires a Linux VM. GH Actions macOS runners are themselves VMs, so nested virtualization is required. Only **Intel macOS runners** (`macos-15-intel`) support this. ARM runners (`macos-14`, `macos-15`) cannot run any container runtime.

**Survey of 11 macOS container runtime options:**

| Tool | License | CLI-Only | GH macOS CI viable | Notes |
|---|---|---|---|---|
| Colima | MIT | Yes | **Yes** (`macos-15-intel`) | Proven by Colima's own CI. Docker or containerd modes. |
| Docker Desktop | Commercial | No (GUI) | No | Needs GUI session + nested virt |
| Podman Machine | Apache 2.0 | Yes | No | Confirmed by Podman maintainer (Discussion #26859) |
| Rancher Desktop | Apache 2.0 | No (Electron) | No | GUI + nested virt. `rdctl` CLI needs Electron running. |
| OrbStack | Commercial | Yes | No | macOS-only, needs nested virt |
| Lima | Apache 2.0 | Yes | Untested on macOS | Works on Linux runners. Same backend as Colima. |
| Finch (AWS) | Apache 2.0 | Yes | No on macOS | Works on Linux runners natively. |
| Multipass | GPL v3 | Yes | No | VM manager, not container runtime |
| nerdctl standalone | Apache 2.0 | N/A | N/A | No macOS binary (draft PR #3763 still open) |
| Minikube | Apache 2.0 | Yes | No | Requires existing Docker |
| Apple container | Apache 2.0 | Yes | Maybe (macOS 26+) | Apple Silicon only, v0.9.0, very early |

**Key conclusions:**
- **Colima is the only confirmed working option** for container runtimes on GH Actions macOS runners
- `macos-15-intel` runner required (available until ~August 2027)
- macOS 15 has Local Network Privacy (LNP) restrictions — network access to containers requires `sudo`
- Podman Machine explicitly doesn't work: "GitHub action runners don't allow virtualization" (Podman maintainer)

#### Fixture design: runner VMs with real package management

**No container jobs.** The dev shell's purpose is to prepare for `kas-container`, which runs privileged containers. Testing inside a GH Actions `container:` job would require Docker-in-Docker or podman-in-container — adding complexity that doesn't represent any real developer's machine and may not work for privileged execution.

GitHub Actions runners ARE VMs. They are the test fixtures. Configure them with real package management:
- **Install**: `sudo apt-get install podman`, `nix profile install nixpkgs#podman`, `brew install colima docker`
- **Remove**: `sudo apt-get remove docker-ce docker-ce-cli containerd.io` (real package removal, not `mv`)
- **Stop services**: `sudo systemctl stop docker.socket docker.service` (real daemon state change)

The `ubuntu-24.04` runner comes with Docker pre-installed. For fixtures that need Docker, use it as-is. For fixtures that need no Docker, remove the Docker packages. For fixtures that need podman, install it via apt. This mirrors what real developers do on their machines.

#### Test fixture matrix

**Tier 1 — Immediately feasible on GH runners (implemented in dev-shells.yml):**

| ID | Fixture | Runner | Setup | Expected |
|----|---------|--------|-------|----------|
| F1 | Ubuntu + Docker running | `ubuntu-24.04` | default state | OK: engine=docker |
| F2 | Ubuntu + Docker stopped | `ubuntu-24.04` | `systemctl stop docker.socket docker.service` | ERROR: "daemon not running" |
| F3 | Ubuntu + podman (apt) | `ubuntu-24.04` | `apt-get remove docker*`, `apt-get install podman` | OK: engine=podman |
| F4 | Ubuntu + no runtime | `ubuntu-24.04` | `apt-get remove docker*` | ERROR: "No container runtime found" |
| F5 | Ubuntu + real nerdctl | `ubuntu-24.04` | `apt-get remove docker*`, install real nerdctl binary, symlink as `docker` | ERROR: "containerd mode" |
| F6 | Ubuntu + podman via Nix (non-NixOS) | `ubuntu-24.04` | `apt-get remove docker*`, `nix build --print-out-paths` PATH injection | ERROR: "Nix store" path rejection |
| F7 | macOS + no runtime | `macos-latest` | default state (no Docker/podman on GH macOS runners) | ERROR: "no container runtime" |

**Tier 2 — Feasible with research-validated approach:**

| ID | Fixture | Runner | Setup | Expected | Notes |
|----|---------|--------|-------|----------|-------|
| F8 | macOS + Docker (Colima) | `macos-15-intel` | `brew install docker colima && colima start` | OK: engine=docker | Validates Darwin Docker happy path. Covers Docker Desktop, Rancher Desktop (dockerd), OrbStack by contract equivalence. |
| F9 | macOS + nerdctl (Colima containerd) | `macos-15-intel` | `brew install colima && colima start --runtime containerd`, symlink nerdctl as docker | ERROR: "containerd mode" | Validates Darwin nerdctl detection. Covers Rancher Desktop (containerd) by contract equivalence. |
| F10 | macOS + Docker stopped (Colima) | `macos-15-intel` | `brew install docker colima && colima start && colima stop` | ERROR: "daemon not running" | Tests Darwin daemon-stopped detection. |
| F11 | macOS + Podman Machine | Tier 3 (see below) | `brew install podman && podman machine init && podman machine start` | OK: engine=podman | **Requires T1f-2 (Darwin+Podman shellHook path)**. Cannot test on GH runners — Podman Machine needs nested virt. Contract validated by F3 on Linux. |
| F12 | NixOS + Nix-store podman | `ubuntu-24.04` | Create `/etc/NIXOS` marker + nix-installed podman PATH | OK: engine=podman | Semi-synthetic: real podman binary from Nix store + NixOS marker. Tests the real code path. |
| F13 | WSL + podman | Deferred | `WSL_DISTRO_NAME` env var on Linux runner | OK: engine=podman | Partial: tests env-var code path but not WSL-specific behavior. |
| F14 | WSL + Docker | Deferred | `WSL_DISTRO_NAME` env var + Docker | OK: engine=docker | Partial: tests env-var code path. |

**Tier 3 — Self-hosted only or impractical in CI:**

| ID | Fixture | Reason | Contract-validated by |
|----|---------|--------|----------------------|
| F11 | macOS + Podman Machine | Podman maintainer confirmed: "GH action runners don't allow virtualization" (Discussion #26859). Same `command -v podman` + `podman info` contract as Linux. | F3 (Linux podman) + code review |
| F15 | macOS + Rancher Desktop (dockerd) | GUI Electron app, no headless mode (Issue #1407). Same Docker daemon contract. | F8 (macOS Colima docker) |
| F16 | macOS + Rancher Desktop (containerd) | GUI app + same nerdctl detection contract. | F9 (macOS Colima containerd) |
| F17 | macOS + OrbStack | Commercial license. Same Docker daemon contract. | F8 (macOS Colima docker) |
| F18 | Real WSL2 on Windows | Requires Windows runner + WSL2 + Nix inside WSL. Complex, high cost. | F13/F14 (partial) |

#### Implementation approach

All fixtures use runner VMs directly. Setup steps use real package management.

**Test structure per fixture:**
1. Setup step: install/remove real packages, start/stop real services
2. Run step: `nix develop --command bash -c 'echo "ENGINE=${KAS_CONTAINER_ENGINE:-UNSET}"'` capturing all output
3. Assert step: verify exit code, output patterns, and engine value

**All fixtures run with `fail-fast: false`** so every fixture is tested regardless of individual failures.

**Colima setup for macOS fixtures** (F8-F10):
```yaml
runs-on: macos-15-intel
steps:
  - run: brew install docker colima    # F8: Docker mode
  - run: colima start                  # starts Lima VM with Docker
  # or: colima start --runtime containerd  # F9: containerd mode
```
Colima takes ~80s to start. `macos-15-intel` supports nested virtualization via Intel VT-x.
macOS 15 LNP (Local Network Privacy) may require `sudo` for network access to containers.

**nerdctl installation** (F5, F9): Download the real nerdctl binary from the official GitHub release. Create a `docker` symlink pointing to it. This is what Rancher Desktop containerd mode does — `docker` is actually nerdctl. The shellHook's `docker -v | grep -qi nerdctl` check runs against the real nerdctl binary output.

**Docker removal** (F3-F6): Use `sudo apt-get remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin` or similar to genuinely uninstall Docker packages. Verify with `! command -v docker` post-removal. This is a real package state, not a moved binary.

#### Sub-tasks

- **T1e-1**: Implement Tier 1 fixtures (F1-F7) on runner VMs with real package management. Validate `apt-get remove` fully removes docker on ubuntu-24.04 runners. Validate real nerdctl binary download (v2.2.1 linux-amd64) and F6 Nix-store podman detection via `nix build --print-out-paths` PATH injection.
- **T1e-2**: Implement Tier 2 macOS fixtures (F8-F10) using Colima on `macos-15-intel`. Research complete — Colima confirmed working. Also implement F12 (NixOS semi-synthetic) and F13/F14 (WSL partial) if straightforward.
- **T1e-3**: Update Tier 3 rationale. Document contract-based coverage for fixtures that can't run in CI. Implement remaining feasible Tier 2 fixtures.

#### DoD

1. All Tier 1 fixtures (F1-F7) pass in CI
2. Tier 2 macOS fixtures (F8-F10) pass on `macos-15-intel` via Colima
3. Each fixture asserts exit code, output pattern, and `KAS_CONTAINER_ENGINE` value
4. Contract-based coverage documented: each Tier 3 fixture maps to a Tier 1/2 fixture validating the same behavioral contract
5. No mocked binaries, no container jobs, no fake scripts — every fixture uses real software on real runner VMs

---

### Task 1f: DRY refactor + Darwin+Podman support

**Status**: `TASK:PENDING`

**Motivation**: The current container engine detection logic is duplicated across 4 locations in `flake.nix` with inconsistent behavior between Darwin and Linux. Darwin supports only Docker, but real macOS developers also use Podman Machine. Adding Darwin+Podman requires touching all 4 locations — this is the right time to DRY the detection into shared Nix-defined shell functions.

#### Code audit: current DRY violations (flake.nix)

**4 locations with duplicated container engine detection:**

1. **Darwin shellHook** (lines 593-622): Docker-only. Checks `command -v docker`, `docker -v | grep -qi nerdctl`, `docker info`. No podman path. Hardcodes `KAS_CONTAINER_ENGINE=docker`.
2. **Linux shellHook** (lines 623-705): Docker + podman. WSL/non-WSL sub-branches. Has nerdctl detection, Nix-store podman rejection, no-runtime error.
3. **Darwin kas-build wrapper** (lines 149-246): Duplicates all Darwin shellHook checks (lines 178-201). Then hardcodes `KAS_CONTAINER_ENGINE=docker` at line 236 and `engine: docker` in log message at line 239. Also hardcodes `docker run` in binfmt suggestion (line 230).
4. **Linux kas-build wrapper** (lines 361-372): Falls back to auto-detect if `$KAS_CONTAINER_ENGINE` not set. Uses `$KAS_CONTAINER_ENGINE` variable in kas-container invocation (line 417) — this is the correct pattern.

**Specific hardcoding violations in Darwin kas-build wrapper:**
- Line 236: `export KAS_CONTAINER_ENGINE=docker` — should use detected engine
- Line 239: `(engine: docker)` — should use `$KAS_CONTAINER_ENGINE`
- Line 230: `docker run --rm --privileged multiarch/qemu-user-static` — should use `$KAS_CONTAINER_ENGINE run`
- Lines 178-201: Entire detection block duplicated from shellHook

**Pattern analysis: what the Linux kas-build wrapper gets right:**
```bash
# Lines 361-372 (Linux kas-build wrapper)
if [[ -z "${KAS_CONTAINER_ENGINE:-}" ]]; then
  if command -v docker &>/dev/null; then
    export KAS_CONTAINER_ENGINE=docker
  elif command -v podman &>/dev/null; then
    export KAS_CONTAINER_ENGINE=podman
  else
    log_error "No container engine found..."
    exit 1
  fi
fi
# Then uses $KAS_CONTAINER_ENGINE everywhere
```
The Darwin wrapper should follow this same pattern.

#### Sub-task T1f-1: Extract shared detection functions in Nix

**Status**: `TASK:COMPLETE`
**Commit**: `8a8b466`

**Goal**: Define container engine detection as Nix-level shell snippet variables that both shellHook and kas-build wrapper consume, eliminating duplication.

**Design approach** — shared shell functions defined once in Nix `let` bindings:

```nix
# Shared detection primitives (platform-independent)
detectEngine = ''
  # Detect container engine. Sets ENGINE_NAME or ENGINE_ERROR.
  # Called by both shellHook and kas-build wrapper.
  detect_container_engine() {
    # 1. Check for docker
    if command -v docker &>/dev/null; then
      if docker -v 2>/dev/null | grep -qi nerdctl; then
        ENGINE_ERROR="NERDCTL_AS_DOCKER"
        return 1
      elif docker info &>/dev/null 2>&1; then
        ENGINE_NAME="docker"
        return 0
      else
        ENGINE_ERROR="DOCKER_STOPPED"
        return 1
      fi
    fi

    # 2. Check for podman
    if command -v podman &>/dev/null; then
      local podman_path
      podman_path=$(command -v podman)
      # Nix-store podman rejected on non-NixOS (sudo resets PATH)
      if [[ "$podman_path" == /nix/store/* ]] && [[ ! -f /etc/NIXOS ]]; then
        ENGINE_ERROR="PODMAN_NIX_STORE"
        ENGINE_ERROR_PATH="$podman_path"
        return 1
      fi
      # Verify podman is functional (machine running on macOS, daemon on Linux)
      if podman info &>/dev/null 2>&1; then
        ENGINE_NAME="podman"
        return 0
      else
        ENGINE_ERROR="PODMAN_NOT_RUNNING"
        return 1
      fi
    fi

    # 3. Nothing found
    ENGINE_ERROR="NONE"
    return 1
  }
'';
```

**Platform-specific error handlers** remain separate (Darwin suggests "Docker Desktop or Podman Machine", Linux suggests "apt-get install"):

```nix
# Darwin error handler
darwinEngineErrors = ''
  handle_engine_error() {
    case "$ENGINE_ERROR" in
      NERDCTL_AS_DOCKER)
        echo -e "  ${RED}ERROR: containerd mode detected...${NC}"
        # ... Darwin-specific guidance ...
        ;;
      DOCKER_STOPPED)
        echo -e "  ${RED}ERROR: Docker daemon not running${NC}"
        echo "  Start Docker Desktop, Colima, or OrbStack."
        ;;
      PODMAN_NOT_RUNNING)
        echo -e "  ${RED}ERROR: Podman Machine not running${NC}"
        echo "  Start with: podman machine start"
        ;;
      NONE)
        echo -e "  ${RED}ERROR: No container runtime found${NC}"
        echo "  Install one of:"
        echo "    Docker Desktop: https://www.docker.com/products/docker-desktop/"
        echo "    Colima: brew install colima docker && colima start"
        echo "    Podman: brew install podman && podman machine init && podman machine start"
        echo "    Rancher Desktop (dockerd mode): https://rancherdesktop.io/"
        ;;
    esac
    exit 1
  }
'';
```

**ShellHook becomes:**
```nix
shellHook = gitHooksSetup + banner + detectEngine + (if isDarwin then darwinEngineErrors else linuxEngineErrors) + ''
  ENGINE_NAME="" ENGINE_ERROR="" ENGINE_ERROR_PATH=""
  if detect_container_engine; then
    export KAS_CONTAINER_ENGINE="$ENGINE_NAME"
    echo "  engine: $ENGINE_NAME"
    echo "  version: $($ENGINE_NAME --version)"
  else
    handle_engine_error
  fi
'' + usageInfo;
```

**kas-build wrapper becomes:**
```nix
# Both Darwin and Linux wrappers:
detectEngine + ''
  if [[ -z "${KAS_CONTAINER_ENGINE:-}" ]]; then
    ENGINE_NAME="" ENGINE_ERROR="" ENGINE_ERROR_PATH=""
    if detect_container_engine; then
      export KAS_CONTAINER_ENGINE="$ENGINE_NAME"
    else
      log_error "No container engine found."
      exit 1
    fi
  fi
  log_info "Starting kas-container build (engine: $KAS_CONTAINER_ENGINE)..."
  # ... uses $KAS_CONTAINER_ENGINE everywhere ...
''
```

**Special case — WSL**: The Linux shellHook has WSL-specific logic (podman-first preference, WSL-specific error messages). This stays in the Linux error handler, not the shared detection function. The detection function itself is WSL-unaware — it just finds what's available. The shellHook's WSL branch can override detection order if needed by calling `command -v podman` first.

**DoD for T1f-1:**
1. `detect_container_engine` function defined once, used by all 4 code locations
2. Platform-specific error messages remain in separate Darwin/Linux/WSL handlers
3. No behavioral changes — same OK paths, same ERROR paths, same exit codes
4. All existing Tier 1 fixtures (F1-F7) still pass
5. Nix evaluation (`nix flake check --no-build`) succeeds

#### Sub-task T1f-2: Add Darwin+Podman to shellHook and kas-build wrapper

**Goal**: The shared `detect_container_engine` from T1f-1 already checks for podman (with `podman info` to verify the machine is running). This sub-task adds Darwin-specific error messages and updates the kas-build wrapper.

**Changes required:**
1. Darwin error handler: add `PODMAN_NOT_RUNNING` case (suggest `podman machine start`)
2. Darwin error handler: update `NONE` case to suggest Podman alongside Docker
3. Darwin kas-build wrapper: use `$KAS_CONTAINER_ENGINE` instead of hardcoded `docker`
4. Darwin kas-build wrapper: binfmt suggestion uses `$KAS_CONTAINER_ENGINE run` not `docker run`
5. Update flake.nix comment at line 148: "Darwin: Uses Docker Desktop as container engine (podman broken on nix-darwin)" → accurate description
6. Update flake.nix comment at line 554: "Darwin: Docker Desktop / Rancher Desktop validation" → include Podman Machine

**Podman Machine on macOS specifics:**
- `podman` CLI talks to Fedora CoreOS VM via `podman machine`
- Runtime is crun (NOT containerd, NOT runc)
- Provides Docker API compatibility socket at `~/.local/share/containers/podman/machine/podman.sock`
- `kas-container` supports `KAS_CONTAINER_ENGINE=podman` — will invoke `podman` CLI directly
- `podman info` returns success when machine is running, failure when stopped

**DoD for T1f-2:**
1. `nix develop` on macOS with Podman Machine running → enters shell, `KAS_CONTAINER_ENGINE=podman`
2. `nix develop` on macOS with Podman Machine stopped (and no docker) → rejects with "podman machine not running" guidance
3. `nix develop` on macOS with both docker and podman → prefers docker (consistency with Linux non-WSL behavior)
4. `kas-build` on macOS uses `$KAS_CONTAINER_ENGINE` throughout, no hardcoded `docker`
5. All existing fixtures still pass (no behavioral change for Docker-only scenarios)

#### Sub-task T1f-3: CI fixtures for Darwin+Podman

**Goal**: Add CI fixture coverage for the new Darwin+Podman path where feasible.

**F11 (macOS + Podman Machine)** is Tier 3 — cannot run on GH runners. Coverage comes from:
- F3 (Linux podman): validates `command -v podman` + `ENGINE_NAME=podman` contract
- Code review: Darwin podman path is structurally identical to shared detection function
- Manual testing procedure documented for developers on real Macs

**What CAN be tested:** After T1f-2, F7 (macOS + no runtime) should say "No container runtime found" with updated guidance mentioning Docker, Colima, and Podman. Update F7's `expect_pattern` accordingly.

**Manual testing procedure** (for developer documentation):
```bash
# On a real Mac with Podman Machine:
brew install podman
podman machine init
podman machine start
nix develop   # Should succeed: engine=podman

podman machine stop
nix develop   # Should fail: "Podman Machine not running"
```

**DoD for T1f-3:**
1. F7 expectations updated for new "no runtime" message (includes Podman guidance)
2. Manual testing procedure documented in plan or developer docs
3. Tier 3 rationale for F11 documents contract-based coverage via F3
