# Plan: CI Validation Infrastructure for VLAN Tests

**Created**: 2026-01-17
**Status**: Planning phase
**Goal**: Validate VLAN test infrastructure using GitHub Actions with proper binary caching

---

## Executive Summary

**Objective**: Set up GitHub Actions CI to validate the VLAN test infrastructure before manual laptop testing.

**Key Constraints**:
- Must use binary caching (Nix builds without cache = expensive + slow)
- Must be portable across CI systems (GitHub Actions now, GitLab CI later)
- Must be cost-effective on paid GitHub account
- Must be designed interactively, not rushed

**Success Criteria**:
- All 3 VLAN tests run successfully in CI
- Build times are reasonable (<15 min per test with cache)
- Costs are predictable and acceptable
- CI configuration is portable (shell scripts + CI orchestration)

---

## Why This Approach?

### The Problem with Naive CI

```yaml
# ❌ This will be SLOW and EXPENSIVE
- name: Run test
  run: nix build '.#checks.x86_64-linux.k3s-cluster-vlans'
  # First run: Downloads ALL dependencies, builds everything
  # Time: 30-60 minutes
  # Cost: High runner minutes
```

### The Solution: Binary Cache

```yaml
# ✅ With binary cache
- name: Setup Cachix
  uses: cachix/cachix-action@v12
  with:
    name: n3x
    authToken: ${{ secrets.CACHIX_AUTH_TOKEN }}

- name: Run test
  run: nix build '.#checks.x86_64-linux.k3s-cluster-vlans'
  # First run: ~15 min (builds only new stuff)
  # Subsequent runs: ~5 min (uses cache)
  # Cost: Manageable
```

---

## Plan Phases

### Phase 1: Research & Cost Analysis 📊

**Goal**: Understand costs, time, and options before implementing anything.

**Tasks**:
1. **Research GitHub Actions Nix ecosystem**
   - Available actions (cachix-action, install-nix-action, magic-nix-cache)
   - Runner specifications (ubuntu-latest specs)
   - Nested virtualization support on GitHub runners

2. **Binary cache options comparison**:
   | Option | Cost | Speed | Complexity | Privacy | Notes |
   |--------|------|-------|------------|---------|-------|
   | **Attic** (S3-backed) ✅ | $5-45/mo (AWS infra) | Fast | Medium | Private | **CHOSEN** - See detailed analysis below |
   | **Cachix** (hosted) | Free tier (5GB) or $15-30/mo | Fast | Low | Public or Private | Easier but less control |
   | **S3 + nix-serve** | $0.023/GB/mo storage | Medium | Medium | Private | Lacks Nix-aware features |
   | **GitHub Actions cache** | 10GB free (Actions cache) | Fast | Low | Private | Limited to GitHub |
   | **Magic Nix Cache** (Flox) | Free | Fast | Very Low | Public | Public only, no GC control |

   **Why Attic?** (Decision rationale)

   Attic provides critical features for embedded Linux builds that other solutions lack:

   **Nix-Aware Garbage Collection**:
   - S3 lifecycle rules are "dumb" — delete objects older than X days regardless of active references
   - Attic understands the Nix store graph, keeps paths still needed by active builds
   - Critical for long-lived cross-compilers and toolchains (6+ months old but still used)

   **Chunk-Level Deduplication**:
   - Only uploads chunks that don't already exist in cache
   - Direct S3 + `nix copy` uploads entire NARs even if 90% duplicated
   - Huge benefit for board variants sharing toolchains (N100 vs Jetson with common base)

   **Transparent Upstream Caching**:
   - Acts as pull-through cache for cache.nixos.org
   - Simplifies client configuration (one substituter vs managing fallback chain)
   - Single source of truth for all cache lookups

   **Structured Metadata**:
   - NAR info stored in PostgreSQL, making it queryable
   - "Which builds use old glibc?" "What paths reference this dependency?"
   - With S3, you'd need to parse thousands of `.narinfo` files

   **Automatic Signing**:
   - Handles cache signing automatically
   - With S3, you manage signing keys separately in CI configuration

   **Cache Composition/Namespacing**:
   - Project-specific caches inherit from shared base (e.g., "board-A" inherits "common-toolchain")
   - No chunk duplication between related caches
   - With S3, you'd manage this via bucket prefixes manually

   **Company Economies of Scale** (to be verified):
   - Shared ECS/Fargate capacity might make Attic containers "free"
   - Existing RDS with spare capacity could eliminate db.t4g.micro cost ($7/mo)
   - Shared ALB reduces incremental cost to ~$2-5/mo (vs $16 base fee)
   - Existing platform team managing similar services reduces operational burden
   - Compute Savings Plans / Reserved Instances could reduce costs 30-60%

   **Questions for Internal Infrastructure Team**:
   - [ ] Do you have existing ECS/Fargate services with spare capacity?
   - [ ] Is there a shared PostgreSQL RDS we could add a database to?
   - [ ] Is there an existing ALB for internal services?
   - [ ] Does platform team already manage similar stateful services?
   - [ ] How mature is your IaC? (Can we copy existing Terraform modules?)
   - [ ] Do you have Compute Savings Plans or RDS Reserved Instances?

3. **Estimate costs**:
   ```
   GitHub Actions runner minutes:
   - Ubuntu runner: $0.008/minute (paid account)
   - Estimated test time: 15 min with cache, 45 min without
   - 3 tests × 15 min = 45 min ≈ $0.36 per run
   - With 10 runs/day = $3.60/day = ~$108/month

   With proper caching:
   - Cached test time: 5 min per test
   - 3 tests × 5 min = 15 min ≈ $0.12 per run
   - 10 runs/day = $1.20/day = ~$36/month
   ```

4. **Test KVM availability** on GitHub Actions:
   ```bash
   - name: Check KVM
     run: |
       ls -la /dev/kvm || echo "KVM not available"
       # GitHub ubuntu-latest runners HAVE nested virt support!
   ```

**Deliverable**: Research report with recommendation (Phase 1 output document)

---

### Phase 2: Attic Infrastructure Design 🎯

**Goal**: Design Attic binary cache architecture and AWS infrastructure.

**Status**: ✅ **Design Complete** - Comprehensive design document created for DevOps handoff

**Design Document**: [ATTIC-INFRASTRUCTURE-DESIGN.md](ATTIC-INFRASTRUCTURE-DESIGN.md)

**Summary**: Created comprehensive infrastructure design document with:
- Architecture diagrams (high-level, network topology, data flow)
- Detailed component specifications (Attic server, RDS, S3, ALB)
- Decision matrices with pros/cons for 9 key decisions
- Specific questions for DevOps team to answer
- Implementation checklist (7-10 hour deployment estimate)
- Cost projections (3 scenarios: dedicated, shared, cost-optimized)
- Monitoring, security, and disaster recovery plans
- Pulumi module skeleton for Go implementation

**Next Action**: DevOps team reviews document, answers infrastructure questions, schedules deployment

**Technology Choice**: S3-backed Attic (see Phase 1 rationale)

**Decision Points**:

1. **Attic Infrastructure Choices**:
   - **AWS Region**: Choose region based on:
     - Developer location (minimize latency)
     - India team access (VPN/DirectConnect availability)
     - GitHub Actions runner latency (us-east-1 typical)
     - Cost considerations

   - **Compute**: ECS Fargate vs EC2
     - **Fargate**: Serverless, $15-45/mo for small workload
     - **EC2**: t4g.small reserved, ~$9/mo but requires management
     - **Shared Fargate**: If company has existing cluster - potentially $0 marginal cost

   - **Database**: RDS PostgreSQL
     - **Dedicated**: db.t4g.micro, ~$13/mo ($7 instance + $6 storage)
     - **Shared RDS**: Add `attic` database to existing instance - potentially $0 marginal cost

   - **Load Balancer**:
     - **Dedicated ALB**: $16/mo base + LCU usage
     - **Shared ALB**: Add target group to existing ALB - $2-5/mo incremental

   - **Storage**: S3
     - ~$0.023/GB/month storage
     - ~$0.09/GB data transfer out (to internet)
     - ~$0.01/GB data transfer (AWS region to region)

2. **Cache Namespacing Strategy**:
   - **Option A**: Single shared cache for all projects
     - Simple to manage
     - All projects benefit from shared dependencies
     - Requires careful GC policies

   - **Option B**: Per-project caches with inheritance
     - `common-toolchain` (base cache)
     - `n3x-x86_64` (inherits from common)
     - `n3x-aarch64` (inherits from common)
     - Better isolation, optimized deduplication

   - **Option C**: Per-branch caches
     - `n3x-main`, `n3x-feature-branches`
     - Prevents test pollution between branches
     - Higher storage costs

3. **Garbage Collection Policy**:
   - **Aggressive** (keep 30 days): Lower storage cost, risk losing old toolchains
   - **Conservative** (keep 90 days): Higher storage, safer for long-lived builds
   - **Smart** (reference-based): Keep if referenced by recent builds, regardless of age
   - **Manual**: No automatic GC, clean up on-demand

4. **Access Control**:
   - **Public read, authenticated write**: GitHub Actions can read anonymously, push requires token
   - **Fully authenticated**: All operations require token (better security)
   - **IP-restricted**: Limit to CI runners + office/VPN IPs

5. **Upstream Cache Strategy**:
   - **Proxy cache.nixos.org**: Attic transparently proxies official cache
     - Pros: Single substituter for clients, reduces nixpkgs.org load
     - Cons: Increases Attic storage, more complex
   - **Direct upstream**: Clients configure both substituters
     - Pros: Simpler Attic config, lower storage
     - Cons: Clients need multi-substituter config

6. **What to cache?**
   ```nix
   # Cache these:
   - nixpkgs dependencies (k3s, kubectl, QEMU, etc.)
   - Test VMs (huge - 2-3 GB each)
   - Built configurations

   # Don't cache:
   - Test results (ephemeral)
   - Log outputs
   ```

7. **Signing Key Management**:
   - **CI-generated keys**: GitHub Actions secrets store private key
   - **AWS KMS**: Store private key in KMS, Attic uses KMS API
   - **SSM Parameter Store**: Store private key encrypted in SSM
   - **Key rotation**: How often? Manual or automated?

**Interactive Design Session Tasks**:
- [ ] Verify company infrastructure economies (ECS, RDS, ALB, etc.)
- [ ] Choose AWS region based on latency and team access
- [ ] Decide: Dedicated vs shared infrastructure (Fargate, RDS, ALB)
- [ ] Choose cache namespacing strategy (single, per-project, per-branch)
- [ ] Design garbage collection policy (aggressive, conservative, smart)
- [ ] Choose access control model (public read, fully authenticated, IP-restricted)
- [ ] Decide on upstream cache strategy (proxy cache.nixos.org or direct)
- [ ] Design signing key management approach
- [ ] Create Terraform/IaC plan for Attic infrastructure
- [ ] Design monitoring and alerting (cache hit rate, storage growth, API errors)
- [ ] Plan for disaster recovery (backup RDS, S3 versioning)

**Deliverable**: Attic infrastructure architecture document with Terraform plan outline

---

### Phase 3: Portable CI Architecture 🏗️

**Goal**: Design CI system that works across GitHub Actions and GitLab CI.

**Architecture Principle**: **CI orchestrates, scripts execute**

```
┌─────────────────────────────────────────┐
│ CI System (GitHub Actions / GitLab CI) │
│ - Triggers on events                    │
│ - Sets up environment                   │
│ - Calls portable scripts                │
│ - Reports results                       │
└─────────────────────────────────────────┘
                    │
                    ▼
┌─────────────────────────────────────────┐
│ Portable Shell Scripts (.ci/scripts/)  │
│ - setup-nix.sh                          │
│ - run-tests.sh                          │
│ - report-results.sh                     │
│ - (works on any CI or local)            │
└─────────────────────────────────────────┘
```

**Directory Structure**:
```
.ci/
├── README.md                    # CI documentation
├── scripts/                     # Portable scripts
│   ├── setup-nix.sh            # Install/configure Nix
│   ├── setup-cache.sh          # Configure binary cache
│   ├── run-test.sh             # Run single test with retry
│   ├── run-all-tests.sh        # Run test suite
│   └── report-results.sh       # Format test results
│
├── github/                      # GitHub Actions specific
│   └── workflows/
│       └── test-vlans.yml      # Workflow definition
│
└── gitlab/                      # GitLab CI specific (future)
    └── .gitlab-ci.yml          # Pipeline definition
```

**Portable Script Example**:
```bash
#!/usr/bin/env bash
# .ci/scripts/run-test.sh - Portable test runner

set -euo pipefail

TEST_NAME="${1:-k3s-cluster-simple}"
MAX_RETRIES="${2:-2}"
REBUILD="${3:-false}"

echo "=== Running test: $TEST_NAME ==="

REBUILD_FLAG=""
if [ "$REBUILD" = "true" ]; then
  REBUILD_FLAG="--rebuild"
fi

for attempt in $(seq 1 $MAX_RETRIES); do
  echo "Attempt $attempt of $MAX_RETRIES..."

  if nix build ".#checks.x86_64-linux.$TEST_NAME" $REBUILD_FLAG --print-build-logs; then
    echo "✅ Test passed: $TEST_NAME"
    exit 0
  else
    echo "❌ Test failed: $TEST_NAME (attempt $attempt)"
    if [ $attempt -lt $MAX_RETRIES ]; then
      echo "Retrying..."
      sleep 10
    fi
  fi
done

echo "❌ Test failed after $MAX_RETRIES attempts: $TEST_NAME"
exit 1
```

**Interactive Design Session Tasks**:
- [ ] Review proposed directory structure
- [ ] Decide on script responsibilities
- [ ] Design error handling and retry logic
- [ ] Plan for test parallelization (run 3 tests in parallel or sequential?)
- [ ] Design result reporting format

**Deliverable**: CI architecture document with script specifications

---

### Phase 3B: Attic Infrastructure Deployment 🏗️

**Goal**: Deploy Attic server infrastructure to AWS.

**Prerequisites**:
- Phase 2 design decisions finalized
- AWS account access with appropriate permissions
- Terraform or CloudFormation IaC tooling

**Tasks**:

1. **Infrastructure as Code Setup**:
   - [ ] Create Terraform module for Attic infrastructure
   - [ ] Define S3 bucket with appropriate policies
   - [ ] Define RDS PostgreSQL instance (or add database to shared RDS)
   - [ ] Define ECS task definition for Attic server
   - [ ] Define ALB with target group (or add to shared ALB)
   - [ ] Define security groups and IAM roles
   - [ ] Configure VPC, subnets, and networking

2. **Attic Server Configuration**:
   - [ ] Generate Attic server configuration file
   - [ ] Configure S3 backend settings
   - [ ] Configure PostgreSQL connection
   - [ ] Set up cache namespaces (based on Phase 2 decisions)
   - [ ] Configure garbage collection policies
   - [ ] Set up access control (tokens, public read, etc.)

3. **Signing Key Generation**:
   - [ ] Generate Attic cache signing key pair
   - [ ] Store private key securely (AWS Secrets Manager or SSM)
   - [ ] Configure Attic to use signing key
   - [ ] Document public key for client configuration

4. **Database Initialization**:
   - [ ] Run Attic database migrations
   - [ ] Verify database schema creation
   - [ ] Create initial cache namespaces
   - [ ] Set up database backups

5. **Deployment**:
   - [ ] Apply Terraform plan to create infrastructure
   - [ ] Deploy Attic container to ECS
   - [ ] Verify Attic server is reachable via ALB
   - [ ] Test health check endpoint
   - [ ] Verify database connectivity

6. **Monitoring and Alerting**:
   - [ ] Set up CloudWatch metrics for:
     - Cache hit/miss rate
     - Storage usage (S3, RDS)
     - API request latency
     - Error rates
   - [ ] Create CloudWatch alarms for:
     - High error rate
     - Storage approaching limits
     - Database connection issues
   - [ ] Set up log aggregation (CloudWatch Logs)

7. **Access Configuration**:
   - [ ] Create Attic API tokens for CI (GitHub Actions)
   - [ ] Create tokens for developers (if needed)
   - [ ] Configure token permissions (read-only, read-write)
   - [ ] Store tokens in GitHub Secrets

**Testing**:
```bash
# Verify Attic server is reachable
curl https://attic.yourcompany.com/v1/healthz

# Test cache push (requires auth token)
attic login ci https://attic.yourcompany.com ci-token-here
nix build .#checks.x86_64-linux.k3s-cluster-simple
attic push n3x result

# Test cache pull (may be public)
nix build .#checks.x86_64-linux.k3s-cluster-simple \
  --substituters https://attic.yourcompany.com/n3x \
  --trusted-public-keys "n3x-cache:PUBLIC_KEY_HERE"
```

**Success Criteria**:
- ✅ Attic server deployed and accessible
- ✅ S3 and RDS integrated correctly
- ✅ Cache push/pull works from test machine
- ✅ Signing verification works
- ✅ Monitoring dashboards showing metrics
- ✅ Cost within projected estimates

**Deliverable**: Deployed Attic infrastructure with IaC code, documentation, and access tokens

---

### Phase 4: GitHub Actions Integration 🚀

**Goal**: Implement the designed CI system for GitHub Actions.

#### Phase 4A: Minimal Viable CI

**Goal**: Get ONE test running in CI with caching.

**Tasks**:
1. Create `.ci/scripts/setup-nix.sh`
2. Create `.ci/scripts/setup-attic.sh` (configure Attic substituter)
3. Create `.ci/scripts/run-test.sh`
4. Create `.github/workflows/test-vlans.yml` (minimal)
5. Configure Attic cache access (public key, substituter URL)
6. Run `k3s-cluster-simple` test only
7. Validate caching works (check build logs for cache hits)
8. Test cache push (if CI has write token)

**Minimal Workflow**:
```yaml
name: VLAN Tests (Minimal)

on:
  push:
    branches: [simint]
  pull_request:

jobs:
  test-simple:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Setup Nix
        uses: DeterminateSystems/nix-installer-action@main
        with:
          extra-conf: |
            extra-substituters = https://attic.yourcompany.com/n3x
            extra-trusted-public-keys = n3x-cache:${{ secrets.ATTIC_PUBLIC_KEY }}

      - name: Install Attic client
        run: |
          nix profile install github:zhaofengli/attic
          attic login ci https://attic.yourcompany.com ${{ secrets.ATTIC_TOKEN }}

      - name: Check KVM
        run: ls -la /dev/kvm

      - name: Run simple test
        run: .ci/scripts/run-test.sh k3s-cluster-simple 2 true

      - name: Push to cache
        if: success()
        run: |
          attic push n3x result
          # Also push any new builds
          attic push n3x /nix/store/*

      - name: Report results
        if: always()
        run: .ci/scripts/report-results.sh
```

**Success Criteria**:
- ✅ Workflow runs without errors
- ✅ Test passes
- ✅ Cache hits visible in logs (2nd run)
- ✅ Build time reasonable (<15 min)

#### Phase 4B: Full Test Suite

**Goal**: Run all 3 VLAN tests in CI.

**Tasks**:
1. Extend workflow to run all 3 tests
2. Decide: Parallel or sequential?
   - **Parallel**: Faster (15 min total), uses more resources
   - **Sequential**: Slower (45 min total), more reliable
3. Add test result artifacts (store test logs)
4. Add status badges to README
5. Set up notifications (optional)

**Full Workflow Structure**:
```yaml
jobs:
  test-simple:
    runs-on: ubuntu-latest
    steps: [...]

  test-vlans:
    runs-on: ubuntu-latest
    steps: [...]

  test-bonding-vlans:
    runs-on: ubuntu-latest
    steps: [...]

  report:
    needs: [test-simple, test-vlans, test-bonding-vlans]
    runs-on: ubuntu-latest
    if: always()
    steps:
      - name: Generate summary
        run: .ci/scripts/generate-summary.sh
```

**Success Criteria**:
- ✅ All 3 tests run in CI
- ✅ Results are clear and actionable
- ✅ Failures are debuggable
- ✅ Costs are within acceptable range

#### Phase 4C: Optimization & Polish

**Tasks**:
1. Optimize cache hit rate
2. Add test result comparison (detect regressions)
3. Add performance metrics (test duration tracking)
4. Documentation for CI system
5. Troubleshooting runbook

---

### Phase 5: GitLab CI Port 🔄

**Goal**: Prove portability by adapting to GitLab CI.

**Tasks**:
1. Create `.gitlab-ci.yml`
2. Adapt cache configuration (GitLab uses different cache syntax)
3. Test on GitLab CI (work account)
4. Verify scripts work unchanged
5. Document differences between GitHub/GitLab

**GitLab CI Structure**:
```yaml
# .gitlab-ci.yml
stages:
  - test
  - report

.test-template:
  image: nixos/nix:latest
  before_script:
    - .ci/scripts/setup-nix.sh
    - .ci/scripts/setup-cache.sh
  cache:
    key: nix-${CI_COMMIT_REF_SLUG}
    paths:
      - .nix-cache/

test-simple:
  extends: .test-template
  stage: test
  script:
    - .ci/scripts/run-test.sh k3s-cluster-simple 2 true
```

**Success Criteria**:
- ✅ Same scripts work on GitLab CI
- ✅ Only CI orchestration differs
- ✅ Results are equivalent

---

## Cost Estimation (Updated with Attic)

### GitHub Actions (Paid Account)

**Assumptions**:
- Ubuntu runner: $0.008/minute
- 3 tests per push
- 10 pushes/day during development
- 1 push/day during maintenance

**Development Phase** (2 weeks):
```
Per run:
- 3 tests × 5 min (with Attic cache) = 15 min = $0.12
- 10 runs/day × $0.12 = $1.20/day
- 14 days × $1.20 = $16.80 total

First-time setup:
- Initial cache population: 3 tests × 15 min = 45 min = $0.36
- One-time cost: $0.36

Total development cost: ~$17
```

**Maintenance Phase** (monthly):
```
- 1 run/day × $0.12 = $0.12/day
- 30 days × $0.12 = $3.60/month
```

### Attic Infrastructure (AWS)

**Baseline Costs** (dedicated infrastructure):
```
Monthly recurring:
- S3 storage: 50GB × $0.023/GB = $1.15/mo
- S3 requests: ~$1/mo (PUT, GET operations)
- ECS Fargate: 0.25 vCPU, 512MB RAM = $15-45/mo
- RDS PostgreSQL (db.t4g.micro): $7/mo (instance) + $6/mo (20GB storage) = $13/mo
- ALB: $16/mo (base) + $2/mo (LCU) = $18/mo
- Data transfer: $5/mo (estimated)

Total: ~$53-83/mo
```

**With Economies of Scale** (shared infrastructure):
```
Monthly recurring:
- S3 storage: 50GB × $0.023/GB = $1.15/mo
- S3 requests: ~$1/mo
- Shared ECS Fargate: $0/mo (spare capacity)
- Shared RDS: $0/mo (add database to existing instance)
- Shared ALB: $2-5/mo (incremental LCU usage only)
- Data transfer: $2-5/mo (within AWS or via DirectConnect to India)

Total: ~$6-12/mo
```

**Storage Growth Projection**:
```
Assumptions:
- Each test run produces ~5GB of artifacts
- Attic deduplication: 70-80% (due to shared toolchain)
- Net new storage: ~1-1.5GB per test run
- 30 runs/month = 30-45GB/month growth
- With GC (90 days): Steady state ~150-200GB

Storage cost at steady state:
- 200GB × $0.023/GB = $4.60/mo
```

**Total Cost Comparison**:

| Scenario | Attic Infrastructure | Storage | Data Transfer | Total/Month |
|----------|---------------------|---------|---------------|-------------|
| **Dedicated AWS** | $51/mo | $4.60/mo | $5/mo | **$60.60/mo** |
| **Shared AWS** | $5/mo | $4.60/mo | $3/mo | **$12.60/mo** |
| **Break-even** | - | - | - | ~1.5TB cached at shared pricing |

**Verdict**:
- **If using shared infrastructure**: Very cost-effective (~$12/mo + $3.60/mo CI = ~$16/mo total)
- **If dedicated infrastructure**: Higher upfront but still reasonable (~$60/mo + $3.60/mo CI = ~$64/mo total)
- **Key factor**: Verify company has shareable ECS/RDS/ALB infrastructure before Phase 3B

---

## Timeline Estimate

| Phase | Duration | Effort |
|-------|----------|--------|
| **Phase 1: Research** | 1-2 hours | Review options, test KVM, estimate costs |
| **Phase 2: Attic Design** | 2-3 hours | Interactive design session, infrastructure decisions |
| **Phase 3: CI Architecture** | 2 hours | Design portable scripts and structure |
| **Phase 3B: Attic Deployment** | 6-8 hours | IaC setup, deploy infrastructure, testing |
| **Phase 4A: Minimal CI** | 2-3 hours | Implement, test, validate Attic integration |
| **Phase 4B: Full Suite** | 2-3 hours | Add all tests, optimize |
| **Phase 4C: Polish** | 2 hours | Documentation, troubleshooting |
| **Phase 5: GitLab** | 2 hours | Port and validate |
| **Total** | **19-25 hours** | Spread over multiple sessions |

**Critical Path Dependencies**:
1. Phase 1 (Research) → Phase 2 (Attic Design)
2. Phase 2 (Attic Design) → Phase 3B (Attic Deployment)
3. Phase 3B (Attic Deployment) → Phase 4A (GitHub Actions Integration)
4. Phase 3 (CI Architecture) can run in parallel with Phase 3B

**Acceleration Options**:
- If company has existing Terraform modules for similar services: -2-3 hours from Phase 3B
- If platform team assists with deployment: -1-2 hours from Phase 3B
- If using trial/POC Attic instance for Phase 4A before full deployment: Can start Phase 4A earlier

---

## Decision Points Requiring User Input

Before implementation, we need to decide:

1. **Attic Infrastructure** (Phase 2 decisions):
   - [ ] AWS region (based on team location, latency, cost)
   - [ ] Dedicated vs shared infrastructure (ECS, RDS, ALB)
   - [ ] Cache namespacing strategy (single, per-project, per-branch)
   - [ ] Garbage collection policy (30/60/90 days, or reference-based)
   - [ ] Access control model (public read + auth write, or fully authenticated)
   - [ ] Upstream cache strategy (proxy cache.nixos.org or direct client config)
   - [ ] Signing key storage (Secrets Manager, SSM, or CI secrets)

2. **Test Execution Strategy**:
   - [ ] Parallel (faster, uses 3× resources)
   - [ ] Sequential (slower, more reliable)
   - [ ] Hybrid (simple first, then parallel for vlans tests)

3. **Trigger Strategy**:
   - [ ] On every push (thorough, expensive)
   - [ ] On pull requests only (efficient)
   - [ ] Scheduled nightly (minimal cost)
   - [ ] Manual trigger (full control)

4. **Scope**:
   - [ ] Just VLAN tests (3 tests)
   - [ ] All checks (7+ tests)
   - [ ] Selected critical tests

5. **Notification Preferences**:
   - [ ] GitHub status checks only
   - [ ] Email on failure
   - [ ] Slack/Discord integration
   - [ ] None (check manually)

---

## Success Metrics

**Phase 4A (Minimal CI)**:
- ✅ One test passes in CI
- ✅ Cache works (visible in logs)
- ✅ Build time <15 min
- ✅ Cost <$0.50 per run

**Phase 4B (Full Suite)**:
- ✅ All 3 VLAN tests pass
- ✅ Total time <30 min (parallel) or <60 min (sequential)
- ✅ Failure detection works
- ✅ Results are clear

**Phase 5 (GitLab Port)**:
- ✅ Same scripts work
- ✅ Only YAML differs
- ✅ Results equivalent

---

## Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| **KVM not available** | High | Test on ubuntu-latest first; fallback to self-hosted runner |
| **Cache size limits** | Medium | Monitor cache size, implement cleanup strategy |
| **Costs spiral** | Medium | Set budget alerts, use scheduled runs for testing |
| **Cache misses** | Medium | Optimize cache keys, pre-populate cache |
| **Flaky tests** | Low | Implement retry logic, monitor failure patterns |

---

## Next Steps

1. **Review this plan** in a new session
2. **Phase 1: Research session** - Gather data on options
3. **Phase 2: Design session** - Make decisions interactively
4. **Phase 3: Architecture session** - Design scripts
5. **Phase 4A: Implementation** - MVP CI pipeline
6. **Iterate** based on results

---

## References

- [GitHub Actions pricing](https://docs.github.com/en/billing/managing-billing-for-github-actions/about-billing-for-github-actions)
- [Magic Nix Cache](https://github.com/DeterminateSystems/magic-nix-cache-action)
- [Cachix](https://www.cachix.org/)
- [Nix on GitHub Actions best practices](https://github.com/DeterminateSystems/nix-installer)
- [GitLab CI Nix integration](https://docs.gitlab.com/ee/ci/examples/nix.html)

---

## Appendix: Alternative Approaches Considered

### ❌ Approach 1: No Cache
**Pros**: Simple
**Cons**: Slow (45+ min), expensive ($3.60/run), wasteful
**Verdict**: Not viable for iterative development

### ❌ Approach 2: Docker-based Tests
**Pros**: Faster than full Nix builds
**Cons**: Loses Nix reproducibility, misses real test environment
**Verdict**: Defeats purpose of Nix testing

### ✅ Approach 3: Binary Cache + Portable Scripts (CHOSEN)
**Pros**: Fast (5-15 min), affordable ($0.12/run), portable, proper testing
**Cons**: Requires cache setup, more complex initially
**Verdict**: Best balance of speed, cost, and correctness
