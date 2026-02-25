# Plan 033: CI Pipeline Refactoring — Move Logic from Workflows to Nix

## Context

The n3x-public GitHub Actions workflows (`ci.yml`, `release.yml`) embed business logic that duplicates or should derive from `lib/debian/build-matrix.nix`. This violates the project's design principle that Nix is the single source of truth. The CI should be a thin orchestration layer: provision environment, query Nix for structured data, execute commands.

Six instances of duplicated logic were identified across the two workflow files. The most concrete is a machine-to-architecture mapping (for CROSS_COMPILE detection) that's hardcoded as a shell `case` statement in 2 places, with a 3rd place silently omitting it.

Additionally, the release pipeline (auto-tag + release workflows) was set up during Plan 032 Task 6 but has only been tested once (release 0.0.1). A version bump to 0.0.2 will validate the full release automation end-to-end, including the conventional-commit-based release notes generator added in PR #2.

## Findings

### F1: Machine→architecture mapping (CROSS_COMPILE) — HIGH

Duplicated 2× with identical shell case statements; omitted 1×:
- `ci.yml:240-243` (Tier 4 build-isar)
- `release.yml:151-154` (release build)
- `ci.yml` Tier 5 (debian-test) omits it entirely — benign for qemuamd64-on-x86_64 but would break if Tier 5 ever ran arm64 builds

### F2: Release kas commands — full duplication with "sync manually" — HIGH

`release.yml:164-204` hardcodes kas overlay chains, recipe names, and file extensions per machine in a shell `case` statement using pipe-delimited strings.

### F3: Machine→runner mapping — MEDIUM

Duplicated 3× in static YAML matrices. Derivable from architecture.

### F4: Tier 5 test group→variant mapping — MEDIUM

`ci.yml:304-319` hardcodes variant-to-test mappings.

### F5: NixOS test list — LOW

`ci.yml:121-128` hardcodes the 7 NixOS test names. Low churn.

### F6: Disk cleanup duplication — LOW

Platform concern, not business logic.

## Progress

| Task | Description | Status |
|------|-------------|--------|
| T1 | Document plan in n3x-public | `TASK:COMPLETE` |
| T2 | Add `arch` to machines in build-matrix.nix | `TASK:PENDING` |
| T3 | Add `mkCiKasCommand` and release helpers to build-matrix.nix | `TASK:PENDING` |
| T4 | Replace arch detection in ci.yml Tier 4 | `TASK:PENDING` |
| T5 | Replace arch detection in ci.yml Tier 5 | `TASK:PENDING` |
| T6 | Refactor release.yml to use build-matrix.nix | `TASK:PENDING` |
| T7 | Bump VERSION to 0.0.2 | `TASK:PENDING` |
| T8 | Dynamic matrix generation (future) | `TASK:DEFERRED` |

## Task Dependencies

```
T1 (independent, first commit)
T2 (arch) → T3 (functions) → T4 (ci.yml Tier 4)
                            → T5 (ci.yml Tier 5)
                            → T6 (release.yml)
T4, T5, T6 → T7 (version bump, validates everything)
```

## Files to Modify

| File | Tasks | Changes |
|------|-------|---------|
| `docs/plans/033-ci-pipeline-refactoring.md` | T1 | This plan |
| `lib/debian/build-matrix.nix` | T2, T3 | Add `arch`, `releaseExtensions`, helpers |
| `.github/workflows/ci.yml` | T4, T5 | Replace arch detection in Tier 4 and 5 |
| `.github/workflows/release.yml` | T6 | Replace arch + variant definitions, add Nix |
| `VERSION` | T7 | `0.0.1` → `0.0.2` |
