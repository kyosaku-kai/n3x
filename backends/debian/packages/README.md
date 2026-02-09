# backends/debian/packages/ - Application Package Development

This directory is the primary development interface for application developers.
Create Debian packages here using standard Debian packaging workflows.

## Quick Start

```bash
# 1. Copy the template
cp -r backends/debian/packages/template backends/debian/packages/my-app
cd backends/debian/packages/my-app

# 2. Update package metadata
#    Edit debian/control, debian/changelog, debian/copyright
#    Replace all instances of "PACKAGE-NAME" with your package name

# 3. Add your code
#    - Source packages: put code in src/
#    - Binary wrappers: download in build.nix
#    - Config packages: put files in debian/

# 4. Build locally
nix build '.#packages.x86_64-linux.my-app'

# 5. Inspect the output
ls -la result/
dpkg-deb --contents result/my-app_*.deb

# 6. Commit and push
```

## Current Status

**What works now**:
- Build .deb packages locally with `nix build '.#packages.x86_64-linux.<name>'`
- Verify package contents with `dpkg-deb --contents`
- Flake check validates all packages build: `nix flake check --no-build`

**Coming soon** (after JFrog apt repository setup):
- CI automatically publishes packages to apt repository
- ISAR images consume packages via standard apt
- Full VM test validation in CI pipeline

## Package Types

### Source Package (Default)

Compiles from source code. Use the template as-is.

```
my-app/
├── debian/
│   ├── control
│   ├── rules
│   ├── changelog
│   ├── copyright
│   └── source/format
├── src/
│   └── main.c
└── build.nix
```

### Binary Wrapper Package

Wraps a pre-built upstream binary (like k3s).

```
k3s/
├── debian/
│   ├── control
│   ├── rules              # override_dh_auto_build: skip
│   ├── changelog
│   ├── k3s-server.service # Both service units included
│   ├── k3s-agent.service  # Neither enabled by default
│   ├── k3s-server.default # /etc/default configs
│   └── k3s-agent.default
└── build.nix              # downloads k3s binary
```

**Note**: The unified `k3s` package includes both server and agent modes.
Enable the appropriate service for node role:
- Server: `systemctl enable k3s-server.service`
- Agent: `systemctl enable k3s-agent.service`

### Config-Only Package

Installs configuration files only.

```
k3s-system-config/
├── debian/
│   ├── control
│   ├── rules
│   ├── changelog
│   ├── k3s.modules-load    # /etc/modules-load.d/
│   ├── k3s.sysctl          # /etc/sysctl.d/
│   ├── disable-swap.service
│   └── iptables-legacy.sh
└── build.nix
```

## debian/ Directory Reference

| File | Required | Purpose |
|------|----------|---------|
| `control` | Yes | Package metadata, dependencies |
| `rules` | Yes | Build script (use `dh` sequencer) |
| `changelog` | Yes | Version history |
| `copyright` | Yes | License information |
| `source/format` | Yes | Should be `3.0 (quilt)` |
| `*.service` | If systemd | Systemd unit files |
| `*.default` | Optional | /etc/default config |
| `postinst` | Optional | Post-install script |
| `prerm` | Optional | Pre-remove script |
| `*.install` | Optional | File installation list |
| `*.conffiles` | Optional | Mark config files (auto for /etc) |

## Best Practices

### Version Numbering

Use format: `UPSTREAM-DEBIAN` (e.g., `1.35.0-1`)

- `1.35.0` - upstream version
- `-1` - Debian revision (increment for packaging-only changes)

### Systemd Services

```ini
[Service]
Type=notify              # Preferred over Type=forking
ExecStart=/usr/bin/app   # Direct binary, no shell wrapper
Restart=on-failure
```

### Configuration Files

- **Static defaults**: Put in debian/, mark as conffiles
- **Node-specific**: Generate in postinst, don't mark as conffiles

### Dependencies

In `debian/control`:
```
Depends: ${shlibs:Depends}, ${misc:Depends}, curl, iptables
```

- `${shlibs:Depends}` - auto-detected shared library deps
- `${misc:Depends}` - debhelper dependencies
- Explicit packages as needed

## Integration with ISAR (Future)

Once JFrog apt repository is configured, packages built here will be published
automatically. ISAR images will consume them via:

```yaml
# kas overlay
local_conf_header:
  my-packages: |
    IMAGE_PREINSTALL:append = " my-app"
```

No ISAR recipe needed - standard apt packaging.

## Directory Structure

```
backends/debian/packages/
├── README.md              # This file
├── template/              # Copy this to start
├── k3s/                   # K3s binary (server + agent modes)
└── k3s-system-config/     # K3s kernel/system configuration
```

## Need Help?

- Debian packaging: https://www.debian.org/doc/manuals/maint-guide/
- debhelper: `man dh`
- This repo's tests: `../../tests/README.md`
