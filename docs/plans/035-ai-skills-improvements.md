# Plan 035: AI Skills and Developer Experience Improvements

## Motivation

During a hands-on ISAR build session (2026-02-26), several friction points were identified where Claude Code spent multiple tool calls discovering information that should have been immediately available via skills or CLAUDE.md.

## Revised Recommendations (n3x-specific)

Original analysis identified 7 items. After reviewing n3x's actual state:
- **#6 (root/user management docs)**: Dropped — belongs in project docs, not AI skills
- **#7 (.opencode/rules/ population)**: Deferred — happens on internal fork after T7.3
- **#1 (qemu-test skill)**: Revised to "image-testing" — n3x uses NixOS VM test driver, not raw QEMU; skill should cover both automated tests and interactive debugging

## Progress

| ID | Description | Status |
|----|-------------|--------|
| T1 | Create `.ai/skills/image-testing.md` + symlinks | TASK:PENDING |
| T2 | Add "Build Quick Reference" section to CLAUDE.md | TASK:PENDING |
| T3 | Implement `.claude/SessionStart` hook | TASK:PENDING |
| T4 | Extract plan status from CLAUDE.md to reduce token cost | TASK:PENDING |

---

## Task T1: Create `.ai/skills/image-testing.md`

**Problem**: No single reference for how to test built images. The isar-build skill covers building but stops at the build output. Testing knowledge is scattered across CLAUDE.md (test commands), mk-debian-vm-script.nix (QEMU invocation), tests/README.md (test architecture), and flake.nix (interactive QEMU with Unix sockets).

**Scope**: Create `.ai/skills/image-testing.md` as single source of truth, with symlinks from `.claude/skills/image-testing.md` and `.opencode/agents/image-testing.md`.

**Content outline**:
- **Automated testing**: How to run NixOS VM tests (`nix build '.#checks...'`), test naming conventions, test tiers (L1-L4)
- **Interactive debugging**: How to use the NixOS test driver interactively, serial console access, the Unix socket QEMU infrastructure from flake.nix
- **Manual image booting**: How to boot a WIC image with QEMU outside the test framework (firmware path discovery, boot modes, exit keys)
- **Default credentials**: root/root with root-login overlay, locked without it, nixos-test-backdoor for automated tests
- **Boot modes**: firmware (UEFI/OVMF) vs direct (kernel/initrd), when each is used
- **Common test failures**: Timing bugs, missing backdoor, network not converged

**DoD**: Skill file exists at `.ai/skills/image-testing.md`, symlinks work from both `.claude/skills/` and `.opencode/agents/`, content covers all six areas above.

---

## Task T2: Add "Build Quick Reference" section to CLAUDE.md

**Problem**: Build information is scattered across CLAUDE.md lines 147-183 (ISAR Builds), lines 185-220 (isar-build-all), and the isar-build.md skill. A new session must piece together fragments to understand how to run a build. The most common first action in any session is "build something" — this should be immediately findable.

**Scope**: Add a concise (~15 line) "Build Quick Reference" section near the top of CLAUDE.md (after Critical Rules, before Project Status), cross-referencing the skill files for detailed procedures.

**Content**:
```
## Build Quick Reference
- Enter dev shell: `nix develop`
- Build all ISAR variants: `nix run '.'`
- Build one variant: `nix run '.' -- --variant <name>`
- Build specific kas overlay combo: `nix develop -c bash -c "cd backends/debian && kas-build <overlays>"`
- Run tests: `nix build '.#checks.x86_64-linux.<test-name>' -L`
- List variants: `nix run '.' -- --list`
- List tests: `nix flake show 2>/dev/null | grep checks`
- Detailed build procedures: See `.claude/skills/isar-build.md`
- Testing procedures: See `.claude/skills/image-testing.md`
```

**DoD**: Section exists in CLAUDE.md between "Critical Rules" and "Project Status". Contains working commands and cross-references to both skill files.

---

## Task T3: Implement `.claude/SessionStart` hook

**Problem**: `settings.json` defines a SessionStart hook pointing to `.claude/SessionStart`, but the script does not exist. This hook could inject cheap, high-value context at the start of every session — preventing common friction like "kas-build not on PATH" (must use `nix develop`) and "orphaned build processes."

**Scope**: Create `.claude/SessionStart` as an executable shell script.

**Content** (emit to stdout, which becomes session context):
- Current git branch and last commit (1 line)
- Whether orphaned build processes exist (podman/bitbake/qemu/nixos-test-driver)
- WSL mount status (if on WSL)
- Available disk space warning if <10GB free
- Reminder: `nix develop` required for builds

**Constraints**:
- Must complete in <2 seconds (blocks session start)
- Must work on both Linux (WSL) and macOS
- Output should be concise — 5-10 lines max
- Must be executable (`chmod +x`)

**DoD**: `.claude/SessionStart` exists, is executable, runs in <2s, outputs useful session context. Hook fires on new Claude Code sessions in this repo.

---

## Task T4: Extract plan status from CLAUDE.md

**Problem**: CLAUDE.md lines 54-78 contain plan status tracking (Plan 034 task list, Plan 033 status) that duplicates content in `docs/plans/*.md`. This content changes every session, adds ~25 lines of token cost, and creates maintenance burden (must update both CLAUDE.md and plan files).

**Scope**: Replace the inline plan status block in CLAUDE.md with a concise summary + links to plan files.

**Before** (~25 lines):
```
- **Plan 034**: **ACTIVE** (all T1 complete) - Dev Environment Validation and Team Adoption
  - T1a: Consolidate dev shells ... — COMPLETE
  - T1b: Port upstream ... — COMPLETE
  [... 15 more lines of task-level detail ...]
- **Plan 033**: **COMPLETE** (7/7, T8 deferred) - CI Pipeline Refactoring
```

**After** (~5 lines):
```
## Active Plans
- **Plan 035**: AI Skills Improvements — `docs/plans/035-ai-skills-improvements.md`
- **Plan 034**: Dev Environment Validation — COMPLETE — `docs/plans/034-dev-environment-and-adoption.md`
- **Plan 033**: CI Pipeline Refactoring — COMPLETE — `docs/plans/033-ci-pipeline-refactoring.md`
```

**Constraint**: Preserve all non-plan content. Move the detailed Plan 034 notes (CRITICAL rules about test fixtures, macOS CI, contract-based coverage, DRY violations) into the plan file itself if they're not already there.

**DoD**: CLAUDE.md plan status section is ≤8 lines. All task-level detail lives in plan files only. No information lost.
