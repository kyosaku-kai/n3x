# Debian Package Governance Best Practices for Isar-Based Embedded Linux

**Date**: 2026-02-06
**Purpose**: Actionable governance strategy for application packages built with Isar

## Key Finding

Debian provides a comprehensive governance framework: [Debian Policy Manual](https://www.debian.org/doc/debian-policy/), [Lintian](https://lintian.debian.org/manual/) (1400+ checks), [autopkgtest/DEP-8](https://dep-team.pages.debian.net/deps/dep8/), and debhelper.

Isar **intentionally disables** these tools during build for speed (`--no-run-lintian --no-run-piuparts --no-run-autopkgtest` in `dpkg.bbclass`). This creates a governance gap that must be filled at the package source level.

## The Isar Governance Gap

| Mechanism | Isar Status | Strength |
|-----------|-------------|----------|
| Lintian | Disabled | None |
| Piuparts | Disabled | None |
| autopkgtest | Disabled | None |
| Rootfs quality check | Enabled | Weak |
| SSH key safety | Enforced | Strong |
| Standards-Version | Hardcoded 3.9.6 (2013) | Outdated |

**Expected pattern**: Package developers validate during development, Isar trusts pre-validated packages, integration testing validates the complete image.

## Recommended Strategy: Package-Level Enforcement

### Package Repository Template

```
myapp/
├── .pre-commit-config.yaml      # Hooks for debian/control lint
├── .gitlab-ci.yml               # CI with lintian + autopkgtest
├── debian/
│   ├── control                  # Standards-Version: 4.6.2+
│   ├── rules                    # debhelper ≥13, hardening=+all
│   ├── myapp.service            # systemd conventions
│   ├── myapp.lintian-overrides  # Documented overrides only
│   ├── tests/
│   │   ├── control              # DEP-8 test declaration
│   │   └── smoke-test           # Basic functionality test
│   └── source/
│       └── format               # 3.0 (quilt) or 3.0 (native)
└── src/
```

### CI Acceptance Criteria

For packages to be accepted into the Isar build:

- Lintian exits with no errors (`lintian --fail-on error`)
- autopkgtest passes all tests
- Standards-Version >= 4.6.0
- All binaries in FHS-compliant paths (`/usr/bin`, `/usr/sbin`, `/usr/lib/<pkg>`)
- Systemd services pass `systemd-analyze verify`
- Hardening flags enabled (PIE, RELRO, stack-protector)

### Optional: Re-enable Lintian in Isar

```bitbake
# conf/local.conf — selective validation during ISAR builds
SBUILD_LINTIAN ?= "1"
```

Or as a post-build validation class:

```bitbake
# meta/classes/package-governance.bbclass
do_package_validate() {
    lintian --fail-on error "${DEPLOY_DIR_DEB}/${PN}_${PV}*.deb" || \
        bbfatal "Lintian validation failed for ${PN}"
}
addtask package_validate after do_deploy_deb before do_build
```

## Quick Reference

### Key Paths

| Path | Purpose |
|------|---------|
| `/usr/bin` | User commands |
| `/usr/sbin` | System admin commands |
| `/usr/lib/<pkg>` | Internal binaries, plugins |
| `/usr/lib/systemd/system/` | Package-provided unit files |
| `/etc/<pkg>/` | Configuration (dpkg-tracked conffiles) |

### Systemd Service Hardening

```ini
[Service]
DynamicUser=yes
ProtectSystem=strict
PrivateTmp=yes
NoNewPrivileges=yes
SystemCallFilter=@system-service
```

### Maintainer Script Rules

- `set -e` required, POSIX shell preferred
- Scripts must be idempotent (safe to run multiple times)
- `postinst configure` is the only place for user interaction (via debconf)
- Use `#DEBHELPER#` substitution tokens

## References

- [Debian Policy Manual v4.7.3.0](https://www.debian.org/doc/debian-policy/)
- [Lintian User's Manual](https://lintian.debian.org/manual/)
- [autopkgtest / DEP-8 Specification](https://dep-team.pages.debian.net/deps/dep8/)
- [Debian pkg-systemd Packaging Guide](https://wiki.debian.org/Teams/pkg-systemd/Packaging)
- [Salsa CI Pipeline](https://salsa.debian.org/salsa-ci-team/pipeline)
- [Debian Hardening Walkthrough](https://wiki.debian.org/HardeningWalkthrough)
- [git-buildpackage Manual - Hooks](https://honk.sigxcpu.org/projects/git-buildpackage/manual-html/gbp.building.hooks.html)
