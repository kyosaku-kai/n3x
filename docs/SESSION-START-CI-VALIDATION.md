# Quick Start: CI Validation Work

**When to use**: Starting a new session to work on GitHub Actions CI validation.

---

## Context

You want to validate the VLAN test infrastructure using GitHub Actions CI instead of manual laptop testing.

**Why?**
- Automated validation without local KVM setup
- Proper binary caching (5min builds vs 45min)
- Portable architecture for future GitLab CI use
- Cost-effective (~$0.12 per run with cache)

---

## Tell Claude

In your new session, say:

> "I want to work on CI validation for the VLAN tests. Please read **docs/plans/CI-VALIDATION-PLAN.md** and help me start Phase 1 research."

---

## What Claude Will Do

1. Read the comprehensive CI validation plan
2. Review Phase 1 tasks (Research & Cost Analysis)
3. Guide you through:
   - Testing KVM availability on GitHub runners
   - Comparing cache options (Magic Nix Cache vs Cachix)
   - Estimating actual costs
   - Making informed decisions before implementation

---

## Key Files

- **docs/plans/CI-VALIDATION-PLAN.md** ← The comprehensive plan
- **CLAUDE.md** (Phase 7) ← Progress tracking
- **README.md** ← Will add CI badge later

---

## What We'll Build

```
.ci/
├── scripts/                    # Portable shell scripts
│   ├── setup-nix.sh
│   ├── setup-cache.sh
│   ├── run-test.sh
│   └── run-all-tests.sh
│
└── github/
    └── workflows/
        └── test-vlans.yml     # GitHub Actions workflow
```

**Principle**: CI orchestrates, scripts execute. Same scripts work on GitHub Actions, GitLab CI, and local machine.

---

## Approach

**Interactive Design-First** (not rushed implementation):

1. **Phase 1**: Research options, test assumptions
2. **Phase 2**: Design cache strategy together
3. **Phase 3**: Design portable CI architecture
4. **Phase 4**: Implement for GitHub Actions
5. **Phase 5**: Port to GitLab CI (proof of portability)

Each phase includes interactive design sessions where you make decisions based on research.

---

## Decision Points

You'll need to decide:

1. **Cache Provider**:
   - Magic Nix Cache (easiest, free, public)
   - Cachix free tier (5GB, public/private)
   - Cachix paid ($15-30/mo, unlimited)

2. **Test Strategy**:
   - Parallel (faster, more resources)
   - Sequential (slower, more reliable)

3. **Trigger Strategy**:
   - On every push
   - On pull requests only
   - Scheduled nightly
   - Manual trigger

4. **Scope**:
   - Just 3 VLAN tests
   - All checks (7+ tests)

---

## Cost Estimates

**With proper binary caching:**
- Per run: $0.12 (3 tests × 5 min)
- Development phase: ~$17 over 2 weeks
- Maintenance: ~$3.60/month

**Without caching (don't do this):**
- Per run: $3.60 (3 tests × 45 min)
- Prohibitively expensive

---

## Timeline

**12-15 hours total** across multiple sessions:
- Phase 1: 1-2 hours (research)
- Phase 2: 1 hour (cache design)
- Phase 3: 2 hours (architecture)
- Phase 4A: 2-3 hours (minimal CI)
- Phase 4B: 2-3 hours (full suite)
- Phase 4C: 2 hours (polish)
- Phase 5: 2 hours (GitLab port)

---

## Success Criteria

**Phase 1 Complete** when you have:
- ✅ KVM availability confirmed on GitHub runners
- ✅ Cache options compared with pros/cons
- ✅ Cost estimates validated
- ✅ Decisions made on cache provider and strategy

**Phase 4A Complete** when:
- ✅ One test runs successfully in CI
- ✅ Binary cache works (logs show cache hits)
- ✅ Build time <15 minutes
- ✅ Cost per run <$0.50

**Full Success** when:
- ✅ All 3 VLAN tests pass in CI
- ✅ Costs are predictable and acceptable
- ✅ Scripts are portable (work locally and in CI)
- ✅ GitLab CI port works with same scripts

---

## Current State

**Branch**: `simint`
**Commit**: `e21c19e`
**Status**: Plan created, ready to begin Phase 1

**What exists**:
- ✅ VLAN test infrastructure (3 test variants)
- ✅ Comprehensive testing guide for manual testing
- ✅ Complete CI validation plan
- ❌ No CI implementation yet (that's what we're building)

---

## Common Questions

**Q: Why not just run `nix build` in CI?**
A: Without caching, Nix downloads all dependencies and builds everything from scratch (45+ min, $3.60 per run). With caching, builds take 5 min and cost $0.12.

**Q: Why portable scripts instead of native CI syntax?**
A: Makes it easy to port between GitHub Actions and GitLab CI. Also lets you run the same commands locally for debugging.

**Q: Why interactive design instead of just implementing?**
A: This is your first GitHub Actions + Nix project. Making informed decisions up front saves time and money later.

**Q: Can I test this locally first?**
A: Yes! The portable scripts will work locally. We'll design them to be testable without CI.

---

## Next Steps

1. Read this document
2. Start new session with Claude
3. Say: "Read docs/plans/CI-VALIDATION-PLAN.md and help me with Phase 1"
4. Follow Claude's guidance through research and design phases
5. Make decisions interactively based on findings
6. Implement only after design is solid

---

**Ready to start!** This will be an interactive learning and building process.
