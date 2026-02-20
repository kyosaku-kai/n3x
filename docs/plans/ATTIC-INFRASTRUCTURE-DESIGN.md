> **ARCHIVED / SUPERSEDED**: This document describes an Attic-based binary cache design that
> was superseded by a Harmonia-based architecture. See
> [nix-binary-cache-architecture-decision.md](../nix-binary-cache-architecture-decision.md)
> for the current architecture decision record.

# Attic Binary Cache Infrastructure Design

**Project**: n3x (Nix-based k3s cluster for embedded Linux)
**Document Version**: 1.0
**Created**: 2026-01-17
**Status**: ARCHIVED — Superseded by Harmonia ADR
**Owner**: Development Team
**Implementer**: DevOps/Platform Team

---

## Executive Summary

### What is Attic?

Attic is an S3-backed Nix binary cache server that provides intelligent caching for Nix builds. It sits between CI/CD systems and the Nix store, dramatically reducing build times and costs.

**Problem**: Nix builds without caching are slow (30-60 min) and expensive on CI runners.
**Solution**: Attic caches built artifacts, reducing subsequent builds to 5-15 minutes.

### Why Attic? (vs Cachix, S3 direct, Magic Nix Cache)

Attic provides critical features for embedded Linux builds:

| Feature | Attic | Cachix | S3 Direct | Magic Nix Cache |
|---------|-------|---------|-----------|-----------------|
| **Nix-Aware GC** | ✅ Keeps referenced paths | ❌ Time-based only | ❌ S3 lifecycle rules | ❌ Public only |
| **Chunk Dedup** | ✅ Uploads only new chunks | ✅ Yes | ❌ Full NAR uploads | ✅ Yes |
| **Private Cache** | ✅ Self-hosted | ✅ Paid tier | ✅ S3 private | ❌ Public only |
| **Upstream Proxy** | ✅ Transparent cache.nixos.org proxy | ❌ Client-side config | ❌ Client-side config | ❌ No |
| **Structured Metadata** | ✅ PostgreSQL queryable | ❌ Proprietary | ❌ File-based | ❌ N/A |
| **Cost Control** | ✅ Self-hosted, predictable | ⚠️ Per-GB pricing | ✅ Low S3 costs | ✅ Free |
| **Company Integration** | ✅ Uses existing AWS infra | ❌ External service | ✅ AWS-native | ❌ External service |

**Key Benefit for n3x**: Cross-compilation toolchains for N100 (x86_64) and Jetson (aarch64) share 80%+ of their dependencies. Attic's chunk-level deduplication means we only store unique portions, dramatically reducing storage costs.

### Business Case

**Without Attic** (naive CI):
- Build time: 30-60 minutes per test run
- 3 tests × 45 min = 135 min/run ≈ **$1.08/run**
- 10 runs/day = **$10.80/day** = **$324/month** in CI costs alone

**With Attic** (cached builds):
- First run: 15 min (partial cache)
- Subsequent runs: 5 min per test
- 3 tests × 5 min = 15 min/run ≈ **$0.12/run**
- 10 runs/day = **$1.20/day** = **$36/month** in CI costs

**Savings**: **~$288/month** (89% reduction) in CI costs + **Attic infrastructure costs** (~$6-60/mo depending on shared resources).

**Break-even**: Even at highest infrastructure cost ($60/mo), total is $96/mo vs $324/mo = **70% savings**.

---

## Architecture Overview

### High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        GitHub Actions CI                         │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐          │
│  │  Test Job 1  │  │  Test Job 2  │  │  Test Job 3  │          │
│  │ (k3s-simple) │  │ (k3s-vlans)  │  │(k3s-bonding) │          │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘          │
│         │                  │                  │                   │
│         └──────────────────┴──────────────────┘                  │
│                            │                                      │
│                    Read cache + Push builds                      │
└────────────────────────────┼──────────────────────────────────────┘
                             │
                             │ HTTPS (authenticated)
                             │
                             ▼
        ┌────────────────────────────────────────────┐
        │     Application Load Balancer (ALB)        │
        │  https://attic.yourcompany.com             │
        │  - TLS termination                         │
        │  - Health checks                           │
        │  - Request routing                         │
        └────────────┬───────────────────────────────┘
                     │
                     ▼
        ┌────────────────────────────────────────────┐
        │      ECS Fargate / EC2 Container           │
        │                                            │
        │  ┌──────────────────────────────────────┐ │
        │  │       Attic Server Container         │ │
        │  │  - ghcr.io/zhaofengli/attic          │ │
        │  │  - Handles cache requests            │ │
        │  │  - Chunk deduplication               │ │
        │  │  - NAR signing                       │ │
        │  │  - Access control                    │ │
        │  └──────┬───────────────────┬───────────┘ │
        │         │                   │              │
        └─────────┼───────────────────┼──────────────┘
                  │                   │
        ┌─────────▼─────────┐  ┌──────▼──────────────┐
        │   RDS PostgreSQL  │  │    S3 Bucket        │
        │                   │  │                     │
        │  - NAR metadata   │  │  - Binary artifacts │
        │  - Cache mappings │  │  - Chunked storage  │
        │  - Access control │  │  - Versioning       │
        │  - GC metadata    │  │  - Lifecycle rules  │
        └───────────────────┘  └─────────────────────┘
```

### Data Flow

**1. Cache Read (CI job needs dependency)**:
```
CI Job → ALB → Attic Server → Check PostgreSQL for NAR info
                            ↓
                      Found in cache?
                     /              \
                   YES               NO
                    ↓                 ↓
              Fetch chunks      Query cache.nixos.org
              from S3          (upstream proxy mode)
                    ↓                 ↓
              Return to CI      Download & cache
                               (store in S3 + PostgreSQL)
                                       ↓
                                 Return to CI
```

**2. Cache Write (CI job pushes new build)**:
```
CI Job → Push NAR → Attic Server → Chunk deduplication
                                 → Only upload new chunks to S3
                                 → Update PostgreSQL metadata
                                 → Sign NAR with cache key
                                 → Return success
```

### Network Topology

```
┌──────────────────────────────────────────────────────────────┐
│                          AWS VPC                             │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐   │
│  │            Public Subnet (2 AZs)                    │   │
│  │                                                      │   │
│  │  ┌────────────────┐         ┌────────────────┐     │   │
│  │  │ ALB (us-east-1a)│         │ ALB (us-east-1b)│     │   │
│  │  └────────┬───────┘         └────────┬───────┘     │   │
│  │           │                           │              │   │
│  └───────────┼───────────────────────────┼──────────────┘   │
│              │                           │                   │
│  ┌───────────▼───────────────────────────▼──────────────┐   │
│  │            Private Subnet (2 AZs)                    │   │
│  │                                                      │   │
│  │  ┌────────────────┐         ┌────────────────┐     │   │
│  │  │ ECS Task        │         │ ECS Task        │     │   │
│  │  │ (us-east-1a)    │         │ (us-east-1b)    │     │   │
│  │  │ - Attic Server  │         │ - Attic Server  │     │   │
│  │  └────┬───────┬────┘         └────┬───────┬────┘     │   │
│  │       │       │                   │       │          │   │
│  └───────┼───────┼───────────────────┼───────┼──────────┘   │
│          │       │                   │       │               │
│  ┌───────▼───────┴───────────────────▼───────┴──────────┐   │
│  │         Private Subnet (Database Tier)              │   │
│  │                                                      │   │
│  │  ┌──────────────────────────────────────────────┐   │   │
│  │  │   RDS PostgreSQL (Multi-AZ optional)         │   │   │
│  │  │   - Primary in us-east-1a                    │   │   │
│  │  │   - Standby in us-east-1b (optional)         │   │   │
│  │  └──────────────────────────────────────────────┘   │   │
│  │                                                      │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  S3 Bucket (Regional, outside VPC)                  │   │
│  │  - VPC Endpoint for low-latency, no NAT costs       │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

---

## Component Specifications

### 1. Attic Server Container

**Docker Image**: `ghcr.io/zhaofengli/attic:latest` (or pinned version)

**Resource Requirements** (starting point):
- **CPU**: 0.25-0.5 vCPU (Fargate) or t3.small (EC2)
- **Memory**: 512MB-1GB RAM
- **Storage**: Ephemeral only (stateless)
- **Network**: 1 Gbps (within AWS)

**Environment Variables**:
```bash
ATTIC_SERVER_ADDR=0.0.0.0:8080
ATTIC_SERVER_DATABASE_URL=postgresql://attic:PASSWORD@rds-endpoint:5432/attic
ATTIC_SERVER_S3_REGION=us-east-1  # Or chosen region
ATTIC_SERVER_S3_BUCKET=company-attic-cache
ATTIC_SERVER_TOKEN_HS256_SECRET_BASE64=<generated-secret>
```

**Ports**:
- **8080**: HTTP API (behind ALB, ALB handles TLS)

**Health Check**:
- **Endpoint**: `GET /v1/healthz`
- **Expected**: HTTP 200
- **Interval**: 30 seconds
- **Timeout**: 5 seconds
- **Unhealthy threshold**: 3 consecutive failures

**Scaling**:
- **Min tasks**: 1 (cost optimization)
- **Max tasks**: 3 (high availability)
- **Scale on**: CPU >70% or Request Count >1000/min

---

### 2. RDS PostgreSQL Database

**Purpose**: Store NAR metadata, cache mappings, access control

**Instance Specs** (starting point):
- **Instance Class**: `db.t4g.micro` (2 vCPU, 1 GB RAM) - cheapest ARM-based
- **Engine**: PostgreSQL 15 or 16
- **Storage**: 20 GB gp3 (baseline, grows automatically)
- **Multi-AZ**: Optional (adds cost, improves uptime)
- **Backup Retention**: 7 days minimum

**Database Name**: `attic`

**Schema**: Created automatically by Attic on first run (migrations)

**Connection**:
- **Port**: 5432
- **Security Group**: Only allow ECS tasks (private subnet)
- **Encryption**: At-rest (default) and in-transit (require SSL)

**Performance Monitoring**:
- Enable Performance Insights (minimal cost)
- CloudWatch metrics: CPU, connections, IOPS

**Cost Optimization Options**:
- Use existing shared RDS instance (add `attic` database)
- Reserved Instance pricing (1-year term saves ~40%)

---

### 3. S3 Bucket

**Purpose**: Store binary cache artifacts (NARs) as deduplicated chunks

**Configuration**:
- **Region**: Same as Attic server (minimize latency and data transfer costs)
- **Bucket Name**: `company-attic-cache` (or your naming convention)
- **Versioning**: Enabled (recover from accidental deletions)
- **Object Ownership**: Bucket owner enforced
- **Block Public Access**: All enabled (private cache)

**Lifecycle Rules**:
```
Rule 1: Transition to Intelligent-Tiering
  - After 30 days: Move to S3 Intelligent-Tiering
  - Saves cost for infrequently accessed objects

Rule 2: Expire incomplete multipart uploads
  - After 7 days: Delete incomplete uploads
  - Prevents storage bloat
```

**IAM Policy** (Attic server needs):
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::company-attic-cache",
        "arn:aws:s3:::company-attic-cache/*"
      ]
    }
  ]
}
```

**Encryption**:
- **At-rest**: S3-managed keys (SSE-S3) or AWS KMS (SSE-KMS)
- **In-transit**: HTTPS enforced (bucket policy)

**Access**:
- VPC Endpoint (S3 Gateway Endpoint) - no NAT costs, faster

**Storage Estimate**:
- Initial: ~50 GB (first test runs)
- Steady state (90-day retention): ~150-200 GB
- Growth: ~30-45 GB/month (with deduplication)

---

### 4. Application Load Balancer (ALB)

**Purpose**: TLS termination, request routing, health checks

**Configuration**:
- **Scheme**: Internet-facing (GitHub Actions needs access)
- **Subnets**: Public subnets in 2 AZs (high availability)
- **Security Group**: Allow HTTPS (443) from internet, HTTP (80) redirect to HTTPS

**Listeners**:
```
1. HTTP (port 80) → Redirect to HTTPS
2. HTTPS (port 443) → Forward to Attic target group
   - TLS Certificate: ACM-managed (yourcompany.com wildcard or attic.yourcompany.com)
   - TLS Policy: ELBSecurityPolicy-TLS13-1-2-2021-06 (modern)
```

**Target Group**:
- **Protocol**: HTTP (ALB → ECS)
- **Port**: 8080
- **Health Check**: `/v1/healthz`
- **Deregistration Delay**: 30 seconds (graceful shutdown)

**DNS**:
- **Record**: `attic.yourcompany.com` → ALB DNS name (CNAME or Alias)

**Cost Optimization**:
- If company has existing ALB for internal services, add Attic as new target group
- Incremental cost: ~$2-5/mo (LCU usage only, not base $16/mo)

---

### 5. Security & IAM

#### ECS Task Execution Role
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken",
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "*"
    }
  ]
}
```

#### ECS Task Role (Attic server needs)
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::company-attic-cache",
        "arn:aws:s3:::company-attic-cache/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue"
      ],
      "Resource": "arn:aws:secretsmanager:REGION:ACCOUNT:secret:attic/*"
    }
  ]
}
```

#### Security Groups

**ALB Security Group**:
- Inbound:
  - Allow TCP 443 (HTTPS) from 0.0.0.0/0
  - Allow TCP 80 (HTTP) from 0.0.0.0/0
- Outbound:
  - Allow TCP 8080 to ECS security group

**ECS Security Group**:
- Inbound:
  - Allow TCP 8080 from ALB security group only
- Outbound:
  - Allow TCP 5432 to RDS security group
  - Allow TCP 443 to S3 VPC Endpoint (or 0.0.0.0/0 if no endpoint)

**RDS Security Group**:
- Inbound:
  - Allow TCP 5432 from ECS security group only
- Outbound:
  - None needed

---

## Decision Matrix

### Decision 1: AWS Region

**Question**: Which AWS region should host Attic infrastructure?

**Factors**:
- Developer location (minimize latency for cache hits)
- India team location (if applicable - VPN/DirectConnect availability)
- GitHub Actions runner latency (runners are typically in us-east-1)
- Cost differences (some regions more expensive)

**Options**:

| Region | Pros | Cons | Recommendation |
|--------|------|------|----------------|
| **us-east-1** (N. Virginia) | Lowest cost, GitHub runners here, most services | Outages historically more common | ✅ **Default choice** |
| **us-west-2** (Oregon) | Good latency for West Coast, stable | Slightly higher cost | If team in Pacific timezone |
| **ap-south-1** (Mumbai) | Best for India team | Higher cost, farther from GitHub | Only if team primarily in India |
| **eu-west-1** (Ireland) | Good for Europe | Higher cost, farther from GitHub | Only if team in Europe |

**Recommendation**: **us-east-1** unless team is primarily outside North America.

**Question for DevOps**:
- [ ] Where are developers primarily located? (timezone/country)
- [ ] Where is India team located? Do they access via DirectConnect/VPN?
- [ ] Do you have any region preferences based on existing infrastructure?

---

### Decision 2: Compute Infrastructure (ECS/Fargate vs EC2)

**Question**: Should Attic run on ECS Fargate, ECS EC2, or standalone EC2?

**Options**:

| Option | Monthly Cost | Pros | Cons | Best For |
|--------|--------------|------|------|----------|
| **ECS Fargate** (new) | $15-45 | Serverless, no server management, scales to zero | Higher per-hour cost | Simple deployment, low operational burden |
| **Shared ECS Fargate** | $0-5 | Uses spare capacity on existing cluster | Requires existing cluster | Companies with existing ECS |
| **ECS on EC2** (dedicated) | $9-15 | Lower cost than Fargate, more control | Requires EC2 management | Medium-scale, predictable load |
| **Standalone EC2** | $9-15 | Full control, easy debugging | Most operational burden | DIY approach, advanced users |

**Recommendation**:
- **If you have existing ECS cluster with spare capacity**: Use shared Fargate ✅
- **If starting fresh**: Use dedicated Fargate (operational simplicity outweighs cost)
- **If cost-sensitive and comfortable with EC2**: Use t3a.small reserved instance

**Question for DevOps**:
- [ ] Do you have an existing ECS Fargate cluster with spare capacity?
- [ ] What's your team's comfort level with ECS vs raw EC2?
- [ ] Do you have existing IaC (Pulumi modules) for ECS deployments?
- [ ] Preference for serverless vs always-on compute?

---

### Decision 3: Database Infrastructure

**Question**: Dedicated RDS instance or shared RDS instance?

**Options**:

| Option | Monthly Cost | Pros | Cons | Best For |
|--------|--------------|------|------|----------|
| **Dedicated RDS** (db.t4g.micro) | $13 | Isolated, simple setup | Higher cost | New deployments, isolation needed |
| **Shared RDS** (add database) | $0-2 | Near-zero marginal cost, existing backups | Requires existing RDS | Companies with existing PostgreSQL |
| **RDS Reserved Instance** (1-yr) | $5 | ~60% savings vs on-demand | Upfront payment, commitment | Long-term usage expected |

**Database Requirements**:
- PostgreSQL 15+ (Attic requirement)
- Minimum 1 GB RAM (metadata is small)
- 20 GB storage (grows slowly, mostly metadata)
- Low IOPS requirements (not a hot database)

**Recommendation**:
- **If you have existing PostgreSQL RDS**: Add `attic` database to it ✅
- **If starting fresh**: Use db.t4g.micro (cheapest, ARM-based)
- **If long-term commitment**: Buy 1-year reserved instance

**Question for DevOps**:
- [ ] Do you have an existing PostgreSQL RDS instance (version 15+)?
- [ ] If yes, does it have spare capacity (CPU, RAM, connections)?
- [ ] Are you comfortable adding a new database to existing RDS?
- [ ] Do you have database backup/restore procedures we should align with?

---

### Decision 4: Load Balancer Infrastructure

**Question**: Dedicated ALB or add to existing ALB?

**Options**:

| Option | Monthly Cost | Pros | Cons | Best For |
|--------|--------------|------|------|----------|
| **Dedicated ALB** | $18-25 | Isolated, simple setup | Higher base cost ($16/mo) | New deployments, full control |
| **Shared ALB** (new target group) | $2-5 | Minimal cost (LCU only), existing TLS certs | Requires existing ALB | Companies with existing ALB |

**ALB Requirements**:
- TLS certificate for `attic.yourcompany.com` (or wildcard `*.yourcompany.com`)
- Minimal traffic (~100 requests/hour during active development)
- Health check endpoint monitoring

**Recommendation**:
- **If you have existing ALB for internal services**: Add target group ✅
- **If starting fresh**: Create dedicated ALB (simplicity)

**Question for DevOps**:
- [ ] Do you have an existing ALB for internal/development services?
- [ ] Do you have a wildcard TLS certificate in ACM (e.g., `*.yourcompany.com`)?
- [ ] Can we add `attic.yourcompany.com` DNS record to Route 53?
- [ ] Any DNS/domain approval processes we need to follow?

---

### Decision 5: Cache Namespacing Strategy

**Question**: How should we organize caches in Attic?

**Background**: Attic supports multiple named caches (namespaces) that can inherit from each other. Chunks are deduplicated across caches.

**Options**:

#### Option A: Single Shared Cache
```
Cache: "n3x"
  - All projects, all architectures
  - Simple to configure
  - GitHub Actions: push to "n3x", pull from "n3x"
```

**Pros**: Simple, all projects benefit from shared toolchains
**Cons**: No isolation, harder to analyze per-project cache usage
**Best for**: Single project or small team

#### Option B: Per-Architecture Caches with Base
```
Cache: "base"         (shared toolchains, nixpkgs basics)
Cache: "n3x-x86_64"   (inherits from "base", x86_64-specific)
Cache: "n3x-aarch64"  (inherits from "base", aarch64-specific)
```

**Pros**: Better isolation, optimized for cross-compilation
**Cons**: More configuration, need to configure inheritance
**Best for**: Projects with multiple architectures

#### Option C: Per-Branch Caches
```
Cache: "n3x-main"              (stable branch)
Cache: "n3x-feature-branches"  (all feature branches)
```

**Pros**: Prevents feature branch pollution of main cache
**Cons**: Higher storage (less deduplication), more complexity
**Best for**: Large teams with long-lived feature branches

**Recommendation**: **Option A (single shared cache)** for simplicity. Upgrade to Option B later if needed.

**Question for DevOps**:
- [ ] Do you prefer simple (single cache) or structured (per-arch caches)?
- [ ] Do you have other projects that might use this cache?
- [ ] Any multi-tenancy or cost allocation requirements?

---

### Decision 6: Garbage Collection Policy

**Question**: How aggressively should we clean up old cache entries?

**Background**: Nix builds can reference very old dependencies. Aggressive GC saves storage costs but risks deleting still-needed paths.

**Options**:

| Policy | Storage Cost | Risk | Best For |
|--------|--------------|------|----------|
| **30 days** | Low (~100 GB) | High (may delete active toolchains) | Tight budget, fast iteration |
| **60 days** | Medium (~150 GB) | Medium | Balanced approach |
| **90 days** | Higher (~200 GB) | Low | Conservative, safe |
| **Reference-based** | Variable | Very low (only deletes unreferenced) | Attic's smart GC |
| **Manual** | Highest | None (manual review) | Full control, operational burden |

**Recommendation**: **Reference-based GC** (Attic's default smart GC) - keeps paths referenced by recent builds, regardless of age.

**Attic Configuration**:
```toml
[garbage-collection]
# Keep paths referenced by builds from last 90 days
interval = "24h"         # Run GC daily
retention_days = 90      # Consider paths from last 90 days
```

**Question for DevOps**:
- [ ] Any budget constraints on S3 storage?
- [ ] Preference for aggressive (cheap) vs conservative (safe) GC?
- [ ] Should we start conservative and tune down later?

---

### Decision 7: Access Control Model

**Question**: Who can read from the cache? Who can write?

**Options**:

| Model | Configuration | Security | Best For |
|-------|---------------|----------|----------|
| **Public read, Auth write** | Simple | Medium | Open-source projects, CI efficiency |
| **Fully authenticated** | Token required for all ops | High | Private projects, strict security |
| **IP-restricted** | Limit to CI IPs + VPN | High | Corporate environments |

**Recommendation**: **Public read, authenticated write**
- CI jobs can pull anonymously (faster, simpler GitHub Actions config)
- Only push requires token (prevents unauthorized cache pollution)
- If project goes open-source, cache already public-ready

**Configuration**:
```toml
# In Attic server config
[cache.n3x]
read = "public"          # Anyone can read
push = "require-token"   # Push needs valid token
```

**Token Management**:
- Generate token: `attic-server make-token --cache n3x --push`
- Store in GitHub Secrets: `ATTIC_AUTH_TOKEN`
- Rotate every 90 days (manual or automated)

**Question for DevOps**:
- [ ] Is this project public or private?
- [ ] Any compliance requirements (e.g., cannot allow public read)?
- [ ] Comfort level with public read access?
- [ ] Existing token management systems we should integrate with?

---

### Decision 8: Upstream Cache Strategy

**Question**: Should Attic proxy cache.nixos.org, or should clients configure both?

**Background**: cache.nixos.org hosts official Nixpkgs binaries. Two approaches:

#### Option A: Attic Proxies Upstream (Transparent Proxy)
```
Client → Attic → cache.nixos.org (on cache miss)
                  ↓
                Store in S3 + return to client
```

**Client Config**:
```nix
substituters = [ "https://attic.yourcompany.com/n3x" ];
# Only one substituter needed!
```

**Pros**:
- Simpler client config (single substituter)
- Reduces load on cache.nixos.org
- Caches upstream artifacts locally (faster subsequent hits)

**Cons**:
- Increases Attic storage (stores nixpkgs artifacts)
- More complex Attic config
- Upstream outages affect cache

#### Option B: Direct Upstream (Fallback Chain)
```
Client → Attic (our cache) → cache.nixos.org (fallback)
         ↓ Miss                ↓ Fetch directly
         Query upstream        Return to client
```

**Client Config**:
```nix
substituters = [
  "https://attic.yourcompany.com/n3x"
  "https://cache.nixos.org"
];
```

**Pros**:
- Lower Attic storage (only our builds)
- Simpler Attic config
- Direct upstream access (faster for fresh nixpkgs)

**Cons**:
- Clients need multi-substituter config
- More nixpkgs.org traffic

**Recommendation**: **Option B (Direct Upstream)** - simpler, lower storage costs, sufficient for single project.

**Question for DevOps**:
- [ ] Any network restrictions accessing cache.nixos.org from CI?
- [ ] Preference for storage savings vs config simplicity?

---

### Decision 9: Signing Key Management

**Question**: Where should we store Attic's cache signing key pair?

**Background**: Attic signs all cached artifacts. Clients verify signatures using public key. Private key must be protected.

**Options**:

| Option | Security | Complexity | Cost | Best For |
|--------|----------|------------|------|----------|
| **AWS Secrets Manager** | High | Low | $0.40/secret/mo | Production |
| **SSM Parameter Store** | Medium | Low | $0.05/param/mo | Cost-sensitive |
| **GitHub Secrets** | Medium | Very Low | Free | Simple setups |
| **AWS KMS** | Very High | High | $1/key/mo + API calls | Compliance needs |

**Recommendation**: **AWS Secrets Manager** - good balance of security, ease of use, and integration with ECS.

**Implementation**:
1. Generate key pair: `attic-server gen-keypair`
2. Store private key in Secrets Manager: `attic/signing-key-private`
3. Store public key in Secrets Manager: `attic/signing-key-public` (for convenience)
4. ECS task retrieves private key at startup
5. Public key distributed to CI (GitHub Secrets: `ATTIC_PUBLIC_KEY`)

**Key Rotation**: Manual every 6-12 months (low priority - cache keys rarely rotated)

**Question for DevOps**:
- [ ] Do you have existing Secrets Manager usage patterns?
- [ ] Any preference for KMS integration?
- [ ] Who should have access to rotate keys?

---

## Questions for DevOps Team

### Critical Questions (Required before implementation)

#### Infrastructure Inventory
- [ ] **ECS**: Do you have an existing ECS Fargate cluster? If yes, what's the utilization?
- [ ] **RDS**: Do you have an existing PostgreSQL RDS instance (version 15+)? If yes, current utilization?
- [ ] **ALB**: Do you have an existing ALB for internal services? Can we add a target group?
- [ ] **VPC**: Which VPC should Attic live in? Any subnet/CIDR constraints?
- [ ] **S3**: Any existing S3 buckets for caching/artifacts we could use? Or create new?

#### Access & Permissions
- [ ] **DNS**: Can we create `attic.yourcompany.com` in Route 53? Who approves?
- [ ] **TLS**: Do you have a wildcard ACM certificate (e.g., `*.yourcompany.com`)?
- [ ] **IAM**: Who can create IAM roles for ECS tasks? Any role naming conventions?
- [ ] **Secrets**: Can we use AWS Secrets Manager? Any cost/approval process?

#### Cost & Budget
- [ ] **Budget**: Any budget limits for this infrastructure? (For context: $6-60/mo range)
- [ ] **Savings Plans**: Do you have AWS Compute Savings Plans or RDS Reserved Instances?
- [ ] **Cost Allocation**: Do we need cost tags for billing? (e.g., project=n3x, team=embedded)
- [ ] **S3 Storage**: Any limits on S3 storage growth? (Expecting 150-200 GB steady state)

#### Operations & Monitoring
- [ ] **Monitoring**: Do you use CloudWatch, Datadog, or other monitoring? Integrate with existing?
- [ ] **Logging**: Do you have centralized logging (CloudWatch Logs, ELK, etc.)?
- [ ] **Alerting**: PagerDuty, OpsGenie, email? Who gets alerted on Attic issues?
- [ ] **IaC**: You mentioned Pulumi + Go. Can we see example modules for ECS/RDS/ALB?

#### Network & Security
- [ ] **VPN/DirectConnect**: Does India team access AWS via VPN or DirectConnect?
- [ ] **IP Restrictions**: Should we restrict ALB to specific IPs (office + CI)?
- [ ] **Security Groups**: Any naming conventions or approval processes?
- [ ] **Encryption**: Any KMS requirements, or is S3 SSE-S3 acceptable?

#### Timeline & Priorities
- [ ] **Urgency**: How soon can you allocate time to deploy this? (Estimate: 6-8 hours)
- [ ] **Staging**: Should we deploy to dev/staging environment first?
- [ ] **Go-Live**: Any preferred maintenance windows for deployment?

---

## Implementation Checklist

### Phase 1: Pre-Deployment (DevOps Team - 1-2 hours)

- [ ] Review this design document with team
- [ ] Answer all questions in "Questions for DevOps Team" section
- [ ] Confirm AWS region choice
- [ ] Verify existing infrastructure availability (ECS, RDS, ALB)
- [ ] Create cost projection based on actual infrastructure
- [ ] Get approval for DNS record (`attic.yourcompany.com`)
- [ ] Verify TLS certificate availability in ACM

### Phase 2: Pulumi Module Development (DevOps Team - 3-4 hours)

- [ ] Create Pulumi stack for Attic infrastructure
  - [ ] S3 bucket with versioning and lifecycle rules
  - [ ] RDS PostgreSQL instance (or add database to existing)
  - [ ] ECS task definition (Fargate or EC2)
  - [ ] ALB target group (or create new ALB)
  - [ ] Security groups (ALB, ECS, RDS)
  - [ ] IAM roles (task execution, task role)
  - [ ] Secrets Manager secret for database password
  - [ ] Secrets Manager secret for token signing key
  - [ ] CloudWatch log group
  - [ ] Route 53 DNS record

- [ ] Generate Attic signing key pair
  ```bash
  # Use Attic CLI or generate manually
  attic-server gen-keypair > keypair.json
  # Store private key in Secrets Manager
  # Store public key in parameter store (for CI)
  ```

- [ ] Create Attic server configuration
  ```toml
  # server.toml
  [database]
  url = "postgresql://attic:PASSWORD@RDS_ENDPOINT:5432/attic"

  [storage]
  type = "s3"
  region = "us-east-1"
  bucket = "company-attic-cache"

  [cache.n3x]
  read = "public"
  push = "require-token"

  [garbage-collection]
  interval = "24h"
  retention_days = 90
  ```

- [ ] Review Pulumi code with team (peer review)
- [ ] Run `pulumi preview` and validate resources

### Phase 3: Deployment (DevOps Team - 2-3 hours)

- [ ] Deploy infrastructure: `pulumi up`
- [ ] Verify all resources created successfully
- [ ] Run database migrations (Attic handles automatically on first start)
- [ ] Verify Attic server health: `curl https://attic.yourcompany.com/v1/healthz`
- [ ] Test database connectivity (check ECS logs)
- [ ] Test S3 connectivity (check ECS logs)

### Phase 4: Access Configuration (DevOps Team - 1 hour)

- [ ] Generate Attic push token
  ```bash
  attic login admin https://attic.yourcompany.com <root-token>
  attic cache create n3x
  attic token create ci --cache n3x --push
  ```

- [ ] Store tokens in GitHub Secrets:
  - [ ] `ATTIC_PUBLIC_KEY` - Cache signing public key
  - [ ] `ATTIC_AUTH_TOKEN` - Push token for CI

- [ ] Test cache push from local machine
  ```bash
  attic login ci https://attic.yourcompany.com <token>
  nix build nixpkgs#hello
  attic push n3x result
  ```

- [ ] Test cache pull
  ```bash
  nix build nixpkgs#hello \
    --substituters https://attic.yourcompany.com/n3x \
    --trusted-public-keys "n3x:PUBLIC_KEY_HERE"
  ```

### Phase 5: Monitoring Setup (DevOps Team - 1 hour)

- [ ] Create CloudWatch dashboard for Attic
  - [ ] ECS CPU and memory utilization
  - [ ] RDS connections and CPU
  - [ ] S3 bucket size and request count
  - [ ] ALB target health and request count

- [ ] Create CloudWatch alarms
  - [ ] ECS task stopped (alert immediately)
  - [ ] RDS CPU >80% for 10 minutes
  - [ ] ALB unhealthy targets >0 for 5 minutes
  - [ ] S3 bucket size >500 GB (warning threshold)

- [ ] Configure SNS topic for alarm notifications
- [ ] Test alert delivery (trigger test alarm)

### Phase 6: Documentation (DevOps Team - 1 hour)

- [ ] Document Attic infrastructure in team wiki/docs
  - [ ] Architecture diagram (copy from this doc)
  - [ ] Access URLs and credentials location
  - [ ] Troubleshooting guide
  - [ ] Runbook for common operations

- [ ] Create runbook entries:
  - [ ] How to rotate signing keys
  - [ ] How to manually trigger garbage collection
  - [ ] How to add new cache namespaces
  - [ ] How to generate new tokens
  - [ ] How to scale ECS tasks manually
  - [ ] How to restore from RDS backup

- [ ] Share with development team:
  - [ ] Attic URL: `https://attic.yourcompany.com`
  - [ ] Public key for Nix configuration
  - [ ] CI token instructions (already in GitHub Secrets)

### Phase 7: Handoff to Development Team

- [ ] Notify development team of deployment completion
- [ ] Provide public key for local Nix configuration
- [ ] Review cache usage guidelines (what to push, what not to push)
- [ ] Set up weekly cost review (track S3 + compute costs)
- [ ] Schedule 30-day review (evaluate cache hit rate, costs, performance)

---

## Cost Projections

### Scenario A: Dedicated Infrastructure

**AWS Costs** (us-east-1 pricing):

| Component | Specification | Monthly Cost |
|-----------|---------------|--------------|
| **ECS Fargate** | 0.25 vCPU, 512 MB RAM, 24/7 | $15.00 |
| **RDS PostgreSQL** | db.t4g.micro (1 GB RAM) | $7.20 |
| **RDS Storage** | 20 GB gp3 | $2.40 |
| **ALB** | Base cost + minimal LCU | $18.00 |
| **S3 Storage** | 150 GB (steady state) | $3.45 |
| **S3 Requests** | ~100K GET, 10K PUT/month | $1.00 |
| **Data Transfer** | ~50 GB/month out to internet | $4.50 |
| **CloudWatch Logs** | 5 GB/month | $2.50 |
| **Secrets Manager** | 2 secrets | $0.80 |
| **Total** | | **$54.85/month** |

**GitHub Actions CI Costs**:
- 3 tests × 5 min = 15 min/run
- $0.008/min × 15 min = $0.12/run
- 30 runs/month = **$3.60/month**

**Combined Total**: **~$58/month**

---

### Scenario B: Shared Infrastructure (Best Case)

**AWS Costs** (leveraging existing resources):

| Component | Specification | Monthly Cost |
|-----------|---------------|--------------|
| **Shared ECS Fargate** | Use spare capacity on existing cluster | $0.00 |
| **Shared RDS PostgreSQL** | Add `attic` database to existing instance | $0.00 |
| **Shared ALB** | Add target group to existing ALB | $3.00 |
| **S3 Storage** | 150 GB (steady state) | $3.45 |
| **S3 Requests** | ~100K GET, 10K PUT/month | $1.00 |
| **Data Transfer** | ~50 GB/month (within AWS or to VPN) | $2.00 |
| **CloudWatch Logs** | 5 GB/month | $2.50 |
| **Secrets Manager** | 2 secrets | $0.80 |
| **Total** | | **$12.75/month** |

**GitHub Actions CI Costs**:
- Same as Scenario A: **$3.60/month**

**Combined Total**: **~$16/month**

---

### Scenario C: Cost-Optimized Dedicated

**AWS Costs** (1-year reserved instances):

| Component | Specification | Monthly Cost |
|-----------|---------------|--------------|
| **ECS on EC2** | t3a.small (1-year RI, 50% upfront) | $6.50 |
| **RDS PostgreSQL** | db.t4g.micro (1-year RI, no upfront) | $4.50 |
| **RDS Storage** | 20 GB gp3 | $2.40 |
| **ALB** | Base cost + minimal LCU | $18.00 |
| **S3 Storage** | 150 GB (steady state, Intelligent-Tiering) | $2.60 |
| **S3 Requests** | ~100K GET, 10K PUT/month | $1.00 |
| **Data Transfer** | ~50 GB/month out to internet | $4.50 |
| **CloudWatch Logs** | 5 GB/month | $2.50 |
| **Secrets Manager** | 2 secrets | $0.80 |
| **Total** | | **$42.80/month** |

**Upfront Cost**: $140 (EC2 RI partial prepayment)

**GitHub Actions CI Costs**: **$3.60/month**

**Combined Total**: **~$46/month** (after amortizing upfront cost)

---

### ROI Analysis

**Baseline (No Cache)**:
- CI costs: 3 tests × 45 min × $0.008/min × 30 runs/month = **$324/month**

**With Attic** (Scenario B - Shared Infrastructure):
- CI costs: $3.60/month
- Attic infrastructure: $12.75/month
- **Total: $16.35/month**
- **Savings: $307.65/month (95% reduction)**
- **Payback: Immediate**

**With Attic** (Scenario A - Dedicated Infrastructure):
- CI costs: $3.60/month
- Attic infrastructure: $54.85/month
- **Total: $58.45/month**
- **Savings: $265.55/month (82% reduction)**
- **Payback: Immediate**

**Break-even**: Even in worst case (dedicated infrastructure), Attic pays for itself immediately.

---

## Monitoring & Operations

### Key Metrics to Monitor

#### Cache Performance
- **Cache hit rate**: Target >70% after initial warmup
- **Cache miss rate**: Should decrease over time
- **Push success rate**: Should be >99%
- **Pull latency (p95)**: Target <2 seconds

#### Infrastructure Health
- **ECS task health**: Should always show 1-2 healthy tasks
- **ALB target health**: Should always be healthy
- **RDS connections**: Monitor for connection pool exhaustion
- **RDS CPU**: Should stay <50% average, <80% peak
- **S3 storage growth**: Track weekly, alert if exceeds budget

#### Cost Tracking
- **S3 storage costs**: Track weekly (should stabilize after 90 days)
- **Data transfer costs**: Monitor for unexpected spikes
- **RDS costs**: Should be constant (unless instance upgraded)
- **ECS costs**: Should be constant (unless scaling)

### CloudWatch Dashboard Example

```json
{
  "widgets": [
    {
      "type": "metric",
      "properties": {
        "metrics": [
          ["AWS/ApplicationELB", "TargetResponseTime", {"stat": "Average"}],
          [".", "RequestCount", {"stat": "Sum"}],
          ["AWS/ECS", "CPUUtilization", {"stat": "Average"}],
          [".", "MemoryUtilization", {"stat": "Average"}],
          ["AWS/RDS", "CPUUtilization", {"stat": "Average"}],
          [".", "DatabaseConnections", {"stat": "Average"}],
          ["AWS/S3", "BucketSizeBytes", {"stat": "Average"}]
        ],
        "period": 300,
        "stat": "Average",
        "region": "us-east-1",
        "title": "Attic Infrastructure Health"
      }
    }
  ]
}
```

### Alarms to Configure

| Alarm | Condition | Action |
|-------|-----------|--------|
| **ECS Task Stopped** | Task count = 0 | Page on-call immediately |
| **ALB Unhealthy Targets** | Unhealthy >0 for 5 min | Page on-call |
| **RDS CPU High** | CPU >80% for 10 min | Alert DevOps Slack |
| **RDS Low Storage** | Free storage <2 GB | Alert DevOps Slack |
| **S3 Storage High** | Bucket >500 GB | Warning email (cost review) |
| **High Error Rate** | ALB 5xx >10/min | Alert DevOps Slack |

### Maintenance Tasks

| Task | Frequency | Owner | Procedure |
|------|-----------|-------|-----------|
| **Review costs** | Weekly | DevOps | Check AWS Cost Explorer |
| **Check cache hit rate** | Weekly | DevOps | Review CloudWatch metrics |
| **Review storage growth** | Weekly | DevOps | Check S3 bucket size |
| **Rotate tokens** | Quarterly | DevOps | Generate new token, update GitHub Secrets |
| **Test backups** | Monthly | DevOps | Restore RDS snapshot to test instance |
| **Update Attic version** | Quarterly | DevOps | Deploy new container image |
| **Review GC policy** | Quarterly | Dev + DevOps | Tune retention based on usage |

---

## Security Considerations

### Data Classification
- **Cache Artifacts**: Internal - may contain proprietary code patterns
- **Database**: Internal - contains metadata about builds
- **Logs**: Internal - may contain build paths and timestamps
- **Signing Keys**: Secret - must be protected

### Threat Model

| Threat | Risk | Mitigation |
|--------|------|------------|
| **Unauthorized cache poisoning** | High | Require token for push, sign all artifacts |
| **Cache data exfiltration** | Medium | Encrypt S3 at rest, HTTPS in transit |
| **Service disruption (DoS)** | Medium | ALB rate limiting, WAF (optional) |
| **Credential theft** | High | Use Secrets Manager, rotate regularly |
| **RDS unauthorized access** | High | Security groups (ECS only), no public access |

### Compliance Checklist

- [ ] **Encryption at rest**: S3 SSE-S3 or SSE-KMS enabled
- [ ] **Encryption in transit**: HTTPS enforced (ALB, RDS SSL)
- [ ] **Access logging**: ALB access logs to S3, CloudWatch Logs enabled
- [ ] **Authentication**: Token-based for write operations
- [ ] **Least privilege IAM**: ECS task roles have minimal permissions
- [ ] **Network isolation**: RDS in private subnet, no public access
- [ ] **Backup & DR**: RDS automated backups (7 days), S3 versioning enabled
- [ ] **Secret rotation**: Documented procedure, quarterly schedule

---

## Disaster Recovery

### Backup Strategy

| Component | Backup Method | Frequency | Retention | Recovery Time |
|-----------|---------------|-----------|-----------|---------------|
| **RDS PostgreSQL** | Automated snapshot | Daily | 7 days | <1 hour |
| **S3 Bucket** | Versioning + replication (optional) | Continuous | 90 days | Minutes |
| **ECS Config** | Pulumi state in S3 | On change | Indefinite | Minutes |
| **Secrets** | Manual backup (encrypted) | On change | Indefinite | Minutes |

### Recovery Procedures

#### Scenario 1: ECS Task Failure
1. Check ECS logs in CloudWatch
2. Verify task health check endpoint
3. If network issue: Check security groups
4. If application issue: Rollback to previous task definition
5. ECS will auto-restart task (no manual intervention needed)

**RTO**: <5 minutes (automatic)
**RPO**: 0 (stateless service)

#### Scenario 2: RDS Failure
1. Check RDS event log in AWS Console
2. If hardware failure: AWS auto-fails over to standby (Multi-AZ)
3. If database corruption: Restore from latest snapshot
4. Update Attic ECS task with new RDS endpoint (if changed)

**RTO**: 15-30 minutes (manual restore) or <1 minute (Multi-AZ auto-failover)
**RPO**: 5 minutes (point-in-time restore)

#### Scenario 3: S3 Data Loss
1. S3 versioning enabled - recover deleted objects
2. If bucket deleted: Cannot recover (ensure lifecycle policy prevents)
3. If entire region failure: Cross-region replication (optional, not implemented by default)

**RTO**: Minutes (versioning restore)
**RPO**: 0 (versioning is synchronous)

#### Scenario 4: Complete Region Failure
1. Deploy Attic infrastructure in different region using Pulumi
2. Copy S3 bucket to new region (if cross-region replication not enabled)
3. Restore RDS snapshot to new region
4. Update GitHub Secrets with new Attic URL
5. Update DNS record to point to new ALB

**RTO**: 2-4 hours (manual redeployment)
**RPO**: 5 minutes (RDS snapshot) + last successful cache push

### Disaster Recovery Testing

- [ ] **Test 1**: Manually stop ECS task, verify auto-restart (Quarterly)
- [ ] **Test 2**: Restore RDS snapshot to test instance, verify data (Monthly)
- [ ] **Test 3**: Recover deleted S3 object using versioning (Quarterly)
- [ ] **Test 4**: Deploy Attic to secondary region (Annually)

---

## Next Steps

### For DevOps Team

1. **Review this document** with your team (estimate: 30-60 minutes)
2. **Answer all questions** in "Questions for DevOps Team" section
3. **Schedule implementation** (estimate: 6-8 hours, can be split across multiple days)
4. **Review Pulumi examples** from similar services you've deployed
5. **Coordinate with development team** on timeline and handoff

### For Development Team

1. **Wait for DevOps deployment** (will notify when complete)
2. **Receive credentials**:
   - Attic URL (e.g., `https://attic.yourcompany.com`)
   - Public key for Nix configuration
   - GitHub Secrets already configured
3. **Test locally** (optional):
   ```bash
   nix build .#checks.x86_64-linux.k3s-cluster-simple \
     --substituters https://attic.yourcompany.com/n3x \
     --trusted-public-keys "n3x:PUBLIC_KEY_HERE"
   ```
4. **Proceed with Phase 4** (GitHub Actions Integration) of CI validation plan

### Timeline

| Phase | Duration | Who | Deliverable |
|-------|----------|-----|-------------|
| **Design Review** (this doc) | 1-2 hours | DevOps + Dev | Answered questions, finalized decisions |
| **Pulumi Development** | 3-4 hours | DevOps | IaC code ready for deployment |
| **Deployment** | 2-3 hours | DevOps | Running Attic infrastructure |
| **Testing & Handoff** | 1 hour | DevOps | Credentials shared, docs updated |
| **Total** | **7-10 hours** | DevOps | Ready for CI integration |

---

## Appendix A: Attic CLI Cheat Sheet

```bash
# Installation (for DevOps admin tasks)
nix profile install github:zhaofengli/attic

# Login to Attic server
attic login <name> https://attic.yourcompany.com <token>

# Create a new cache
attic cache create <cache-name>

# Configure cache settings
attic cache configure <cache-name> \
  --read-policy public \
  --push-policy require-token

# Generate a token
attic token create <token-name> \
  --cache <cache-name> \
  --push

# Push a Nix store path
attic push <cache-name> /nix/store/...

# Push from a result symlink
attic push <cache-name> ./result

# List caches
attic cache list

# Show cache info
attic cache info <cache-name>

# Delete a cache (DANGEROUS)
attic cache delete <cache-name>

# Manual garbage collection
attic gc <cache-name>
```

---

## Appendix B: Pulumi Module Skeleton (Go)

```go
package main

import (
    "github.com/pulumi/pulumi-aws/sdk/v6/go/aws/ec2"
    "github.com/pulumi/pulumi-aws/sdk/v6/go/aws/ecs"
    "github.com/pulumi/pulumi-aws/sdk/v6/go/aws/lb"
    "github.com/pulumi/pulumi-aws/sdk/v6/go/aws/rds"
    "github.com/pulumi/pulumi-aws/sdk/v6/go/aws/s3"
    "github.com/pulumi/pulumi-aws/sdk/v6/go/aws/secretsmanager"
    "github.com/pulumi/pulumi/sdk/v3/go/pulumi"
)

func main() {
    pulumi.Run(func(ctx *pulumi.Context) error {
        // 1. Create S3 bucket for cache storage
        bucket, err := s3.NewBucket(ctx, "attic-cache", &s3.BucketArgs{
            Bucket: pulumi.String("company-attic-cache"),
            Versioning: &s3.BucketVersioningArgs{
                Enabled: pulumi.Bool(true),
            },
        })
        if err != nil {
            return err
        }

        // 2. Create RDS PostgreSQL instance (or reference existing)
        // TODO: Implement based on decision (dedicated vs shared)

        // 3. Create ECS task definition
        // TODO: Implement based on decision (Fargate vs EC2)

        // 4. Create ALB target group (or reference existing ALB)
        // TODO: Implement based on decision (dedicated vs shared)

        // 5. Create security groups
        // TODO: Implement

        // 6. Create IAM roles
        // TODO: Implement

        // 7. Create Secrets Manager secrets
        // TODO: Implement

        // Export outputs
        ctx.Export("bucketName", bucket.Bucket)
        ctx.Export("atticUrl", pulumi.String("https://attic.yourcompany.com"))

        return nil
    })
}
```

---

## Appendix C: References

- **Attic Documentation**: https://docs.attic.rs/
- **Attic GitHub**: https://github.com/zhaofengli/attic
- **Nix Binary Cache Guide**: https://nixos.org/manual/nix/stable/command-ref/new-cli/nix3-help-stores.html#binary-cache-store
- **AWS ECS Best Practices**: https://docs.aws.amazon.com/AmazonECS/latest/bestpracticesguide/intro.html
- **AWS RDS PostgreSQL**: https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_PostgreSQL.html
- **GitHub Actions Nix**: https://github.com/DeterminateSystems/nix-installer

---

## Document Revision History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2026-01-17 | Dev Team | Initial design document for DevOps handoff |

---

**End of Document**

**Next Action**: DevOps team to review and answer questions in "Questions for DevOps Team" section. Schedule follow-up meeting to finalize decisions and begin Pulumi implementation.
