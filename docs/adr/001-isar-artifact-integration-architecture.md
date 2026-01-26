# ADR 001: ISAR Artifact Integration Architecture

## Status

Accepted

## Context

The isar-k3s project combines two fundamentally different build paradigms:

1. **ISAR/BitBake**: Debian-based image builder that produces `.wic` disk images, rootfs tarballs, kernels, and initrds. Builds run in kas-container (privileged podman), use sstate-cache, and download packages from Debian repositories.

2. **Nix**: Purely functional package manager with content-addressable storage, hermetic builds, and deterministic outputs.

We need Nix derivations (tests, flash scripts) to consume ISAR-built artifacts. The question is how to integrate these two systems.

### Options Considered

**Option A: requireFile (Current)**
- Uses `pkgs.requireFile` to reference artifacts by content hash
- User manually adds artifacts to nix store after ISAR build
- Hash pins ensure reproducibility of downstream derivations
- Pros: Simple, works now, content-addressable
- Cons: Manual step required, not "fully traceable" from source

**Option B: Fixed-Output Derivations (FOD)**
- Create Nix derivations that run kas-container and produce artifacts
- Nix verifies output hash matches expected value
- Pros: Fully automated, traceable derivation exists
- Cons:
  - ISAR builds are NOT bit-reproducible (Debian packages change)
  - Requires privileged container (sandbox escape)
  - Hash must be updated after every upstream change
  - sstate-cache affects outputs

**Option C: fetchurl from CI Artifacts**
- CI builds ISAR images, uploads to storage with stable URLs
- Nix uses `fetchurl` with hash to retrieve
- Pros: Fully traceable (URL + hash), no local ISAR build needed
- Cons: Requires CI infrastructure, stable artifact storage

**Option D: Hybrid with Improved Tooling**
- Keep requireFile pattern for content-addressability
- Add flake app `rebuild-isar-artifacts` to automate:
  - Running kas-build
  - Computing hash
  - Adding to nix store
  - Updating isar-artifacts.nix
- Future: Add CI artifact fetching (Option C) as alternative source

### Constraints

1. **ISAR is not hermetic**: Same recipe can produce different hashes across builds due to:
   - Debian package updates
   - Build timestamps
   - sstate-cache state

2. **kas-container requires privileges**: Cannot run inside Nix sandbox

3. **Development velocity**: Frequent recipe changes during development make hash update cycles tedious

4. **Team onboarding**: New developers need simple, documented workflow

## Decision

We adopt **Option D: Hybrid approach with improved tooling**.

### Architecture

```
ISAR Build System              Nix Integration
==================             ===============

kas-container build     --->   build/tmp/deploy/images/
        |                              |
        v                              v
   .wic, .tar.gz            nix-hash --flat --base32
        |                              |
        v                              v
   Local file              nix-store --add-fixed sha256
        |                              |
        v                              v
   <manual or flake app>    /nix/store/<hash>-artifact
        |                              |
        v                              v
   Update hash in          requireFile { sha256 = "..."; }
   isar-artifacts.nix              |
                                   v
                           Test/Flash derivations
```

### Implementation Components

1. **`nix/isar-artifacts.nix`**: Registry of all ISAR artifacts using `requireFile` pattern with descriptive error messages showing rebuild instructions

2. **`nix run .#rebuild-isar-artifacts`**: Flake app that automates the entire workflow:
   - Accepts machine and role arguments
   - Runs kas-build with correct config
   - Computes SHA256 hash
   - Adds to nix store
   - Updates isar-artifacts.nix with new hash
   - Supports shell completion for discoverability

3. **`scripts/update-artifact-hashes.sh`**: Low-level script for manual hash operations

### Future Enhancement: CI Integration

When CI infrastructure is established with Nix binary cache:

```nix
# Future: isar-artifacts.nix could support multiple sources
let
  # Try binary cache first, fall back to requireFile
  fetchIsarArtifact = { name, sha256, ciUrl ? null }:
    if ciUrl != null && builtins.pathExists (fetchurl { url = ciUrl; inherit sha256; })
    then fetchurl { url = ciUrl; inherit sha256; }
    else requireFile { inherit name sha256; message = "..."; };
in ...
```

This allows:
- CI publishes artifacts to Nix binary cache or S3
- Developers can pull pre-built artifacts (fast)
- Or build locally and add to store (offline capable)

## Consequences

### Positive

- **Content-addressable**: Same hash guarantees same artifact content
- **Reproducible downstream**: Tests always run against pinned artifact versions
- **Offline capable**: Works without network after artifacts are in store
- **Simple mental model**: ISAR builds images, Nix consumes them
- **Extensible**: CI integration can be added without changing consumer code
- **Tooling reduces friction**: One command rebuilds and registers artifacts

### Negative

- **Manual step remains**: User must run flake app after ISAR changes
- **Hash updates required**: Any recipe change requires hash update cycle
- **Not pure Nix**: Cannot `nix build` from scratch without ISAR infrastructure
- **Storage duplication**: Artifacts exist in both build/ and /nix/store

### Mitigations

- Clear documentation in devShell welcome message
- Flake app makes the workflow single-command
- CI integration (future) eliminates manual step for most developers

## Future Research Topics

1. **Nix Binary Cache Integration**: Evaluate `cachix` or S3-backed cache for artifact distribution

2. **ISAR Reproducibility**: Investigate snapshot.debian.org for pinned package sources

3. **Hash Synchronization**: Explore integrating ISAR's sstate signatures with Nix content hashes

4. **Build Farm**: Consider dedicated build infrastructure that produces both sstate-cache and Nix store artifacts

## References

- `nix/isar-artifacts.nix` - Artifact registry implementation
- `docs/nix-isar-integration-guide-revised.md` - Detailed integration patterns
- `flake.nix` - Flake app definition
