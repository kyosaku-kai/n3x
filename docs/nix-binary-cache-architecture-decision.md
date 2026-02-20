# Nix Binary Cache Architecture Decision Record

## Context and Scope

This document covers the binary cache layer of our embedded Linux build infrastructure. The broader system uses Nix at the top level to orchestrate builds of Debian-based images targeting multiple hardware platforms via the Yocto Isar project. Builds run across three environments: GitLab Runner instances on EC2, on-premise bare metal servers, and developer workstations.

The overall caching strategy operates across several layers, ordered by impact (outermost first):

1. **Nix binary cache** — the subject of this document. A cache hit here skips the entire Isar/Yocto build for a given derivation. This is the highest-impact caching layer.
2. **Debian package caching (Artifactory + apt-cacher-ng)** — two Artifactory-hosted Debian repositories (one upstream mirror, one for internal packages) with apt-cacher-ng deployed as a local write-through cache on every build node. This accelerates Debian package fetching inside Isar builds when a Nix cache miss forces a rebuild.
3. **Yocto sstate and download directory** — the innermost, most granular caching layer. Allocated on fast local ephemeral storage (e.g., NVMe on EC2 instances). Deliberately treated as disposable and low priority because hits at layers 1 and 2 eliminate the need for sstate in most cases.

The problem addressed here is: how should we implement the Nix binary cache layer such that build outputs are shared efficiently across all three environments, with minimal operational complexity and cost?

---

## Solutions Evaluated

### Option A: Attic with S3 Backend

Attic is a self-hostable Nix binary cache server backed by S3-compatible storage. It provides content-defined chunking (CDC) for sub-NAR deduplication, multi-tenant cache isolation, managed signing via JWT tokens, LRU garbage collection, and a dedicated CLI tool for push/pull operations.

In this option, all environments push to and pull from a single Attic instance (or replicated instances) backed by an S3 bucket.

**Advantages:**

- Native S3 support with effectively infinite storage and no capacity planning.
- CDC deduplication at the chunk level (16-256KB variable-size chunks) across NARs, which is more granular than filesystem-level dedup.
- Multi-tenant cache separation for logical isolation between CI branches, developers, etc.
- Upstream cache filtering when pushing (skips paths already in cache.nixos.org).
- Built-in LRU garbage collection with configurable retention periods.
- S3 provides 11-nines durability and geographic availability via CloudFront.
- JWT-based authentication means no SSH key distribution for push operations.

**Disadvantages:**

- Attic is self-described as an "early prototype" — the API is not stabilized and it has not yet been packaged in nixpkgs.
- Requires a running Rust daemon, a PostgreSQL or SQLite database, S3 credentials management, and JWT token lifecycle management.
- Per-request S3 costs accumulate with high cache-check frequency. Nix performs a HEAD request per store path during substitution, and builds can check hundreds of paths. At ~1000 builds/day checking ~200 paths each, S3 request costs alone could reach $100-150/month.
- S3 egress charges apply when developers or on-premise servers pull from outside AWS.
- Replication between sites is limited to "point everything at the same S3 bucket." There is no efficient incremental sync mechanism for distributing cache state to on-premise infrastructure.
- The Attic service itself is another component to monitor, debug, and upgrade. Failures in Attic's chunking pipeline or database are outside the team's core expertise.
- Double compression: Attic compresses NARs (zstd by default) before storing them. If the backing storage also compresses (as ZFS would), the second compression pass is wasted CPU with no gain.

### Option B: Attic with ZFS Backend

A variant of Option A where Attic's storage backend is replaced with local ZFS filesystems (declared via disko) instead of S3. ZFS provides transparent compression, optional block-level deduplication, snapshots, and efficient replication via `zfs send/recv`.

**Advantages over Option A:**

- Eliminates S3 per-request and egress costs.
- ZFS `send/recv` enables efficient incremental replication between sites, transferring only changed blocks. This is fundamentally more bandwidth-efficient than any S3-based sync.
- ZFS compression (zstd) is transparent and avoids double-compression issues.
- ZFS snapshots provide atomic cache state management and rollback capability.
- Predictable, mostly-fixed costs (server + disk) rather than usage-based pricing.
- Low-latency local reads (microseconds vs. S3's milliseconds).

**Disadvantages:**

- Retains all of Attic's operational complexity (daemon, database, token management) in addition to ZFS management.
- Attic's local filesystem backend is less tested than its S3 backend.
- Two complex systems to operate and debug when problems arise.

### Option C: Harmonia on ZFS (No Attic) — Selected

Replace Attic entirely with Harmonia, a Rust-based Nix binary cache server from the nix-community that serves `/nix/store` directly over HTTP. Place the nix store on ZFS filesystems declared via disko. Use standard Nix tooling (`nix copy`, post-build hooks, remote builders) to populate the cache. Share cache data between nodes via **HTTP substituters** rather than ZFS replication.

**Advantages:**

- Dramatically simpler operational surface. The entire cache infrastructure consists of: a NixOS service declaration for Harmonia, a signing keypair, and ZFS datasets. No separate database, no token management, no chunking pipeline.
- Harmonia is packaged in nixpkgs, has a NixOS module, is actively maintained, and is purpose-built for this exact use case. It signs NARs on the fly, does transparent zstd wire compression, supports TLS natively, and exposes Prometheus metrics.
- ZFS compression on `/nix/store` consistently delivers 1.5-2x compression ratios with negligible CPU overhead, based on real-world NixOS user data. This substantially reduces storage requirements without any application-layer complexity.
- ZFS snapshots enable atomic cache state management: snapshot before garbage collection, rollback if needed, keep snapshots as GC roots for release builds.
- No double compression. NARs are stored uncompressed in the nix store, ZFS compresses at the block level, and Harmonia applies zstd compression on the wire when serving to clients. Each layer compresses exactly once where it is most effective.
- Cache population uses standard Nix tools that the team already knows. No proprietary client tool or API.
- The entire stack is declarable in Nix via disko and NixOS modules, consistent with the project's "Nix all the way down" philosophy.
- With two or more GitLab runner nodes and on-premise servers already in operation, there is no single point of failure.

**Disadvantages and accepted tradeoffs:**

- No content-defined chunking. ZFS block-level compression and (optionally) dedup operate on fixed-size blocks, which is less granular than Attic's CDC for near-identical NARs. In practice, ZFS compression captures most of the storage savings, and the marginal improvement from CDC does not justify the operational complexity of Attic.
- No multi-tenant isolation. All users share one nix store per cache node. For a single team building the same product, this is not a meaningful limitation.
- No built-in LRU garbage collection. Retention policy must be managed via `nix-collect-garbage`, GC roots, and/or ZFS snapshot lifecycle. This is more manual but also more predictable.
- No upstream cache filtering on push. `nix copy` will copy paths that are also available in cache.nixos.org. With ZFS compression, the storage overhead is minimal, and this means builds never depend on upstream cache availability.

### Why Not ZFS Replication?

An earlier version of this design proposed using ZFS `send/recv` for replication between cache nodes. This was rejected for the following reasons:

1. **ZFS does not support multi-master replication.** ZFS `send/recv` requires a single-master topology where one node is the authoritative writer and others receive read-only replicas. If both source and destination have written past the last shared snapshot, they have "diverged" and cannot be merged.

2. **Our topology requires multiple active builders.** EC2 runners build ISAR images, on-premise servers run VM tests and HIL tests. Both environments are active contributors to the cache, not passive consumers.

3. **Nix's content-addressing makes HTTP substitution sufficient.** Because Nix derivations are content-addressed (identical inputs → identical outputs), the same build on different nodes produces the same store path. There are no "conflicts" to resolve — if `/nix/store/abc123-foo` exists on any node, it is identical everywhere.

4. **HTTP substituters are simpler and more resilient.** Each node queries all configured substituters before building. If a path exists on any peer, it downloads via HTTP. If not, it builds locally. No replication daemons, no master election, no sync lag.

**ZFS remains valuable** for local storage because:
- zstd compression: 1.5-2x space savings (500GB effective → 750-1000GB)
- Checksumming: Detects silent data corruption (bit rot)
- Snapshots: Pre-GC safety, instant rollback
- ARC cache: Intelligent read caching for Nix access patterns

---

## Decision

We will use **Option C: Harmonia on ZFS with HTTP Substituters** for the Nix binary cache layer.

The deciding factors are:

1. **Operational simplicity** — Harmonia + ZFS requires no database, no token management, no replication daemons.
2. **Multi-master compatibility** — HTTP substituters work with multiple active build nodes; ZFS replication does not.
3. **Nix-native architecture** — Relies on Nix's content-addressing for cache sharing rather than fighting it with external replication.
4. **ZFS value retention** — Compression, checksumming, and snapshots provide significant benefits without replication complexity.

Each node runs:
- ZFS-backed `/nix/store` with zstd compression
- Harmonia serving the local store
- Caddy reverse proxy with TLS (internal CA)
- Substituter configuration pointing to all peer nodes

---

## ZFS Configuration Guidance

### Compression vs. Deduplication

ZFS offers both transparent compression and block-level deduplication. Based on analysis and real-world data from NixOS users:

- **Compression (recommended: `zstd` or `lz4`):** Consistently achieves 1.5-2x ratios on `/nix/store` with negligible CPU overhead and zero additional RAM. The `zstd` algorithm at its default level (3) provides better ratios than `gzip-9` while being significantly faster. The `lz4` algorithm is faster still with slightly lower ratios. Either is a safe default.

- **Deduplication:** Achieves an additional 1.35-1.79x on top of compression for `/nix/store` data. However, ZFS dedup is famously RAM-intensive — the dedup table (DDT) must ideally fit in the ARC (ZFS's in-memory cache). One NixOS user with ~750GB of store data reported 100-180GB of ARC usage on a 256GB machine. If the DDT does not fit in RAM, writes degrade severely as ZFS reads DDT entries from disk for every block written.

**Our recommendation:** Start with compression only (`zstd`). Skip dedup initially. Monitor `zfs get compressratio` over time. If storage pressure becomes a concern and the cache nodes have sufficient spare RAM, dedup can be enabled on a per-dataset basis for newly written data at any time. On EC2 instances where RAM is the most expensive resource, dedup is unlikely to be cost-effective. On bare metal on-premise servers with ample RAM, it may become attractive later.

### Dataset Layout

Consider separating the nix store used for caching into its own ZFS dataset so that compression, dedup, recordsize, and snapshot policies can be tuned independently:

```
pool/nix/store     compression=zstd  atime=off  recordsize=128K
```

Setting `atime=off` avoids unnecessary write amplification on a read-heavy store. The default `recordsize=128K` is appropriate for the large files typical in a nix store.

---

## Cache Population: Interfaces and Automation

A critical operational question is how build outputs reach the cache nodes after a build completes. Harmonia is a read-only server — it serves the local `/nix/store` over HTTP but does not accept uploads. This means store paths must be placed into the cache node's nix store through other means. There are several options, and importantly, the explicit `nix copy` call can be made transparent to users.

### Method 1: Explicit `nix copy` via SSH

The most direct approach. After a build completes, the builder copies the closure to the cache node:

```sh
nix copy --to ssh://cache-node ./result
```

This requires SSH access from the builder to the cache node. The `ssh-ng://` protocol variant is preferred as it is more efficient for large transfers.

**When to use:** Quick setup, scripted CI pipelines where the push step is explicit. Suitable for an initial deployment.

**Limitation:** Requires the builder to remember (or be scripted) to run the copy. SSH key distribution is required.

### Method 2: Post-Build Hook (Recommended for CI and Build Nodes)

Nix supports a `post-build-hook` configuration option that executes a script after every successful build. This is the recommended mechanism for automatic, transparent cache population. The hook runs in the context of the Nix daemon (as root in multi-user mode), so the signing key can be kept inaccessible to unprivileged users.

On each build node, configure `nix.conf` (or the equivalent NixOS option) with:

```nix
{
  nix.settings.post-build-hook = "/etc/nix/upload-to-cache.sh";
  nix.settings.secret-key-files = [ "/etc/nix/cache-private-key.pem" ];
}
```

The hook script:

```sh
#!/bin/sh
set -eu
set -f
export IFS=' '
exec nix copy --to ssh-ng://cache-node $OUT_PATHS
```

The `$OUT_PATHS` environment variable is automatically set by the Nix daemon to the space-separated list of output paths that were just built.

**When to use:** All CI runners and dedicated build servers. This is the primary mechanism and eliminates the need for any user or pipeline to explicitly push to the cache.

**Important caveats:**

- The post-build hook runs synchronously and blocks the build loop. If the cache node is unreachable or slow, builds will stall. A production deployment should either use a robust network link (which is the case for co-located CI runners) or wrap the hook in a script that enqueues paths for asynchronous upload.
- An asynchronous variant can be implemented by having the hook append paths to a queue file, with a separate systemd service draining the queue via `nix copy`. This decouples build performance from cache upload latency.

Example of an asynchronous queue approach:

```sh
#!/bin/sh
# /etc/nix/upload-to-cache.sh (post-build hook)
set -eu
set -f
export IFS=' '
for path in $OUT_PATHS; do
  echo "$path" >> /var/lib/nix-cache-queue/pending
done
```

```nix
# Systemd service to drain the queue
systemd.services.nix-cache-uploader = {
  description = "Upload queued store paths to binary cache";
  serviceConfig = {
    Type = "oneshot";
    ExecStart = toString (pkgs.writeShellScript "drain-cache-queue" ''
      QUEUE="/var/lib/nix-cache-queue/pending"
      LOCK="/var/lib/nix-cache-queue/lock"
      [ -f "$QUEUE" ] || exit 0
      exec ${pkgs.util-linux}/bin/flock "$LOCK" ${pkgs.bash}/bin/bash -c '
        [ -f "'"$QUEUE"'" ] || exit 0
        mv "'"$QUEUE"'" "'"$QUEUE"'.processing"
        ${pkgs.nix}/bin/nix copy \
          --to ssh-ng://cache-node \
          $(cat "'"$QUEUE"'.processing")
        rm "'"$QUEUE"'.processing"
      '
    '');
  };
};

systemd.timers.nix-cache-uploader = {
  wantedBy = [ "timers.target" ];
  timerConfig = {
    OnUnitActiveSec = "30s";
    OnBootSec = "60s";
  };
};
```

### Method 3: Co-Located Builder and Cache (Simplest for CI)

If the CI runner IS the cache node — i.e., the GitLab runner process runs on the same machine that hosts Harmonia — then no push step is needed at all. Builds produce outputs directly into the local `/nix/store`, and Harmonia immediately serves them. This is the simplest possible configuration and eliminates the SSH requirement entirely for CI.

For our GitLab runner nodes in EC2, this is the recommended topology: each runner node runs both the GitLab runner and Harmonia. Builds populate the local store, Harmonia serves it immediately, and other nodes can fetch via HTTP substituter.

Developer workstations and other build environments that are not themselves cache nodes would still need one of the other methods to contribute their build outputs.

### Method 4: Nix Remote Builders / Remote Store

Nix natively supports distributed builds where a local machine offloads build execution to a remote machine. When configured to use a cache node as a remote builder, the build happens on the cache node directly, and the output lands in its nix store without any explicit copy step.

Configure on a developer workstation:

```nix
{
  nix.distributedBuilds = true;
  nix.settings.builders-use-substitutes = true;
  nix.buildMachines = [
    {
      hostName = "cache-node";
      sshUser = "nixbuild";
      sshKey = "/root/.ssh/nixbuild";
      system = "x86_64-linux";
      maxJobs = 8;
      supportedFeatures = [ "nixos-test" "big-parallel" "kvm" ];
    }
  ];
}
```

Alternatively, to build in a remote store without involving the local store at all:

```sh
nix build --eval-store auto --store ssh-ng://cache-node .#myDerivation
```

**When to use:** Developer workstations that want to offload heavy builds to a powerful cache/build node, automatically populating the cache in the process. Also useful when the developer's machine lacks the resources for a full Isar image build.

**Limitation:** Requires SSH access. The build output does not end up in the developer's local store unless explicitly copied back, which may or may not be desired.

### Method 5: SSH Is Not Strictly Required

While SSH is the most common transport for `nix copy` and remote builds, it is not the only option. Consider these alternatives for environments where SSH key distribution is difficult:

- **Nix's `ssh-ng://` store** uses the Nix daemon wire protocol over SSH and is more efficient than plain `ssh://` for bulk operations.
- **The experimental `unix://` store** can forward over any tunnel, not just SSH. Combined with WireGuard or Tailscale, this can simplify connectivity.
- **`nix copy --to file:///path`** can write to a local directory that is shared via NFS or other network filesystem. Harmonia's `real_nix_store` configuration option allows serving the nix store from a non-default location, which could be an NFS mount. This eliminates SSH entirely for the push path, though it introduces NFS management.
- For the co-located builder model (Method 3), no network transport is needed at all for the push path.

### Recommended Configuration by Environment

| Environment | Cache Read | Cache Write | Notes |
|---|---|---|---|
| GitLab Runner (EC2) | Local + HTTP from all peers | Local (co-located nix store) | Build and cache on the same node. Query peers before building. |
| On-Premise Build Server | Local + HTTP from all peers | Local (co-located nix store) | Builds land locally. Query EC2 nodes and local peers. |
| Developer Workstation | HTTPS from all Harmonia nodes | Post-build hook via SSH, or remote builder offload | Developers pull from cache over HTTP; push via post-build hook or by building on a remote node. |
| nixos-anywhere Server Management | HTTPS from designated Harmonia node | Not applicable (consumer only) | Deployment processes only pull from the cache. |

### Substituter Configuration

All nodes should configure all other nodes as substituters with appropriate priorities:

```nix
{
  nix.settings = {
    substituters = [
      # Local peers first (lowest latency)
      "https://cache.nuc-1.n3x.internal?priority=10"
      "https://cache.nuc-2.n3x.internal?priority=10"
      # EC2 runners
      "https://cache.ec2-x86.n3x.example.com?priority=20"
      "https://cache.ec2-graviton.n3x.example.com?priority=20"
      # Upstream last
      "https://cache.nixos.org?priority=40"
    ];
    trusted-public-keys = [
      "cache.n3x.example.com-1:AAAA..."
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
    ];
    # Tolerate unavailable caches
    connect-timeout = 5;
    fallback = true;
  };
}
```

### TLS Configuration

All Harmonia traffic uses HTTPS with an internal root CA:

- **Caddy** reverse proxy in front of Harmonia handles TLS termination
- **Internal CA** (generated offline, root cert distributed via NixOS module)
- **ACME or static certs** issued by internal CA to each node
- Developer workstations and CI runners trust the internal CA root

This establishes production-grade PKI patterns for the build infrastructure.

---

## Cache Sharing Topology (HTTP Substituters)

![Build Caching Architecture](diagrams/build-caching.drawio.svg)

```
  GitLab Runner A (EC2)          GitLab Runner B (EC2)
  ┌────────────────────┐        ┌────────────────────┐
  │ NixOS + disko/ZFS  │◄──────►│ NixOS + disko/ZFS  │
  │ Harmonia + Caddy   │  HTTPS │ Harmonia + Caddy   │
  │ GitLab Runner      │  subs  │ GitLab Runner      │
  │ zstd compression   │        │ zstd compression   │
  └────────┬───────────┘        └───────────┬────────┘
           │                                │
           │    HTTPS substituter           │
           │    (bidirectional)             │
           ▼                                ▼
  On-Premise Cache/Build Node(s)
  ┌────────────────────────────┐
  │ NixOS + disko/ZFS          │
  │ Harmonia + Caddy           │
  │ zstd compression           │
  │ KVM for VM tests           │
  │ Serves developers on LAN   │
  └────────────────────────────┘
           │
           │ HTTPS (substituter)
           ▼
  Developer Workstations
```

**How it works:**

1. Each node builds derivations into its local ZFS-backed `/nix/store`
2. Harmonia immediately serves the local store over HTTPS (via Caddy with internal CA TLS)
3. Before building, Nix queries all configured substituters (peer nodes)
4. If a path exists on any peer → download via HTTPS
5. If not found anywhere → build locally
6. Nix's content-addressing guarantees identical store paths for identical inputs (no conflicts)

---

## What We Give Up by Not Using Attic

For completeness, the following Attic capabilities are explicitly not present in this architecture. Each is accompanied by the rationale for why it is acceptable.

**Content-defined chunking (CDC) deduplication.** Attic breaks NARs into variable-size chunks and deduplicates at the chunk level across all cached paths. This is more granular than ZFS's fixed-block dedup. However, ZFS compression alone achieves 1.5-2x on nix store data, which captures the majority of storage savings. The marginal improvement from CDC for our workload (large Isar image builds with relatively few near-identical variants) does not justify the complexity of running Attic's chunking pipeline and database.

**Multi-tenant cache isolation.** Not needed for a single team building a single product line.

**JWT-based authentication for push operations.** Replaced by SSH authentication (for post-build hooks and `nix copy`) or eliminated entirely (for co-located builder/cache nodes). SSH key management is already part of our infrastructure.

**Upstream cache filtering.** When pushing, Attic skips paths available in cache.nixos.org to save storage. Without this, we cache some upstream paths redundantly. With ZFS compression, the storage cost is minimal, and we gain independence from upstream cache availability, which is beneficial for reproducibility and reliability of an embedded product build.

**LRU garbage collection with per-cache retention policies.** Replaced by a combination of: `nix-collect-garbage` with GC roots pinned to recent successful CI builds; and ZFS snapshot lifecycle management (keep snapshots for N release builds, destroy older ones, let ZFS reclaim unreferenced blocks). This requires a small amount of custom automation but provides more predictable and auditable behavior.

---

## Next Steps

See **Plan 023: CI Infrastructure and Runner Deployment** for the full task breakdown. Key milestones:

1. **NUC Prototype Cluster (Tasks 3-9):** Deploy 2+ NUCs on isolated LAN with disko-managed ZFS, Harmonia, Caddy, and internal CA. Validate HTTP substitution, measure ZFS compression ratios, and gather operational insights before AWS deployment.

2. **EC2 Deployment (Tasks 11-12, 15-16):** Apply learnings from prototype to EC2 runner configurations. Deploy x86_64 and Graviton runners with 500GB gp3 EBS volumes for ZFS-backed nix stores.

3. **On-Prem Production (Tasks 10, 17):** Deploy finalized on-prem runner configuration with KVM for VM tests and HIL test capability.

4. **CI Integration (Tasks 18-21):** Implement GitLab CI jobs for package builds, ISAR image assembly, VM tests, and artifact publishing.

5. **Ongoing Monitoring:** Track storage growth via `zfs get compressratio` and `zfs list`. Evaluate whether dedup should be enabled on nodes with sufficient RAM (bare metal on-prem, not EC2).
