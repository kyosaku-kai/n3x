# Plan 034: Dev Environment Validation and Team Adoption

**Status**: `PLAN:ACTIVE`
**Created**: 2026-02-24
**Repo**: n3x-public (kyosaku-kai/n3x)

## Context

The n3x-public repo is live on GitHub with 22/22 CI checks passing, release automation validated (0.0.2), and repository rulesets configured. The next phase is validating the developer experience across all claimed platforms.

The flake defines 5 dev shells but none have been tested in CI. The `debian` shell has platform-aware logic (WSL detection, podman vs Docker, binfmt validation) established during the upstream `fix/container-runtime-cross-arch` work. Validating these shells across platforms prevents "works on my machine" issues when teammates adopt the repo.

## Task Progress

| Task | Description | Status |
|------|-------------|--------|
| 1 | Cross-platform dev shell validation CI | TASK:PENDING |

## Task Dependencies

```
```

---

## Task Definitions

### Task 1: Cross-platform dev shell validation CI

**Status**: `TASK:PENDING`

**Goal**: Add a GitHub Actions workflow that validates `nix develop` shells work on all claimed platforms: Ubuntu 24.04, macOS (Apple Silicon), and NixOS.

**Dev shells to test**:

| Shell | x86_64-linux | aarch64-darwin | Notes |
|-------|-------------|----------------|-------|
| `default` | Yes | No | NixOS tools (nixos-rebuild, kubectl, etc.) |
| `k3s` | Yes | No | Kubernetes tools |
| `test` | Yes | No | VM test tools (qemu, libvirt) |
| `debian` | Yes | Yes | ISAR/Debian build tools (kas, podman/docker) |

**Platforms and runners**:

1. **Ubuntu 24.04** (`ubuntu-24.04`): Tests all 4 x86_64-linux shells. Nix installed via DeterminateSystems/nix-installer-action. Most common CI/developer platform.

2. **macOS** (`macos-latest`, Apple Silicon): Tests `debian` shell only (aarch64-darwin). Validates Docker Desktop detection logic in shellHook. Note: no Docker on GitHub macOS runners, so shellHook will warn — test should verify the shell *enters* and tools are available, not that Docker is running.

3. **NixOS**: No native GitHub Actions runner exists. Options:
   - **Option A**: Use `nixos/nix` Docker image on `ubuntu-latest` — tests Nix-in-container, not NixOS host. Lightweight.
   - **Option B**: Use DeterminateSystems installer on `ubuntu-latest` — same as Ubuntu test but with different Nix distribution. May not add value over Ubuntu test.
   - **Option C**: Boot a NixOS VM via QEMU on `ubuntu-latest` — tests actual NixOS, heavy.
   - **Recommended**: Option A for now. Document that NixOS host validation requires on-prem runner.

**Validation approach per shell**:
```bash
# 1. Shell entry succeeds
nix develop '.#<shell>' --command bash -c 'echo "shell-entry: OK"'

# 2. Key tools are on PATH
nix develop '.#default' --command bash -c 'which kubectl && which nixpkgs-fmt && echo "tools: OK"'
nix develop '.#k3s' --command bash -c 'which kubectl && which helm && echo "tools: OK"'
nix develop '.#test' --command bash -c 'which qemu-system-x86_64 && echo "tools: OK"'
nix develop '.#debian' --command bash -c 'which kas && which jq && echo "tools: OK"'

# 3. shellHook runs without error (captured via nix develop -c env check)
```

**Implementation approach**:
- New workflow file: `.github/workflows/dev-shells.yml`
- Trigger: on push/PR (same as ci.yml), or potentially on flake.nix/flake.lock changes only
- Matrix strategy: `{os: [ubuntu-24.04, macos-latest], shell: [default, k3s, test, debian]}` with exclude rules for darwin-unsupported shells
- Use `magic-nix-cache-action` for caching (same as ci.yml)
- Separate from ci.yml to keep concerns clean (ci.yml = build/test pipeline, dev-shells.yml = developer environment validation)

**Reference**: upstream `fix/container-runtime-cross-arch` branch established the platform-aware shellHook pattern with container runtime detection, binfmt validation, and Darwin-specific Docker Desktop checks.

**DoD**:
1. `.github/workflows/dev-shells.yml` exists and passes on all platforms
2. All 4 x86_64-linux shells validated on Ubuntu 24.04
3. `debian` shell validated on macOS (aarch64-darwin)
4. NixOS coverage documented (on-prem scope) or Docker-based NixOS test included
5. CI status badge added to README (optional)
