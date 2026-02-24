# Contributing to n3x

Thank you for your interest in contributing to n3x. This document provides guidelines for contributing to this project.

## Confidentiality Notice

This project originated within a corporate environment and has been published as open source. Contributors must take care to ensure that no confidential or proprietary information is introduced into the repository. Specifically, the following must not appear in any file content, file paths, or commit messages:

- Corporate names, internal product codenames, or project identifiers
- Internal domain names, hostnames, or infrastructure identifiers
- Internal email addresses
- References to unreleased products, proprietary processes, or trade secrets

GitHub Secret Scanning with push protection is enabled on this repository. Pushes containing content that matches organizational compliance patterns will be automatically rejected.

### Organizational Acronym Pattern — False Positives

One of the scanning patterns (Pattern 6, "Organizational acronym") matches a common three-letter acronym that also appears in legitimate technical contexts — for example, ARM Pointer Authentication Code. If your push is blocked due to a false positive:

1. Review the blocking message to confirm it is a false positive
2. Follow the URL in the rejection message to submit a bypass request with a clear justification (e.g., "ARM architecture technical reference, not an organizational identifier")
3. A designated reviewer will evaluate and approve or deny the request
4. Approved bypass requests allow the push to proceed

Bypass requests expire after 7 days if not reviewed.

## Getting Started

1. Fork the repository
2. Create a feature branch from `main`
3. Make your changes
4. Submit a pull request

## Commit Guidelines

This project uses [Conventional Commits](https://www.conventionalcommits.org/). All commit messages must follow this format:

```
type(scope): description

[optional body]

[optional footer(s)]
```

### Commit Types

| Type | Purpose |
|------|---------|
| `feat` | New feature or capability |
| `fix` | Bug fix |
| `docs` | Documentation changes |
| `ci` | CI/CD pipeline changes |
| `test` | Adding or modifying tests |
| `refactor` | Code restructuring (no behavior change) |
| `chore` | Maintenance tasks, dependency updates |
| `build` | Build system or tooling changes |
| `perf` | Performance improvements |
| `style` | Code style/formatting (no logic change) |

### Scope (optional)

Scope indicates the area of the codebase affected. Recommended scopes for n3x:

- `nixos` -- NixOS backend modules and configurations
- `debian` -- Debian/ISAR backend (kas, recipes, packages)
- `k3s` -- K3s configuration and cluster management
- `network` -- Network profiles and systemd-networkd configuration
- `ci` -- GitHub Actions workflows and CI infrastructure
- `test` -- Test framework and test cases
- `infra` -- Infrastructure (runners, deployment)

Custom scopes are allowed. Use what makes sense for the change.

### Examples

```
feat(debian): add SWUpdate OTA support
fix(network): correct VLAN tagging on bond interfaces
ci: add ARM64 runner support
docs: update architecture decision records
test(k3s): add DHCP cluster formation test
refactor(nixos): extract network config to shared module
chore: update flake inputs
build(debian): pin kas-container to v5.1
feat!: remove deprecated single-node deployment mode
```

### Breaking Changes

Append `!` after the type/scope to indicate a breaking change:

```
feat(k3s)!: require etcd for all server nodes
```

Or include `BREAKING CHANGE:` in the commit body/footer.

### Enforcement

Conventional commits are enforced at two levels:

1. **Local**: A `commit-msg` git hook validates the format. The hook is installed automatically when you enter a dev shell via `nix develop`. You can also set it up manually: `git config core.hooksPath .githooks`
2. **Server**: GitHub branch rulesets validate commit messages on push to protected branches.

### Additional Rules

- Keep commits focused on a single logical change
- Use personal email addresses for git commits (not corporate email)
- Description should be lowercase and not end with a period

## Contributor Identity

Contributors should use personal email addresses for git commits. Corporate affiliation, where applicable, is indicated through GitHub organization membership and the `MAINTAINERS` file. This approach keeps corporate email addresses out of the git history while still providing clear attribution and affiliation.

## Code of Conduct

Be respectful and constructive in all interactions. We are committed to providing a welcoming and inclusive experience for everyone.

## Reporting Issues

When reporting issues, please do not include any confidential or proprietary information in issue titles, descriptions, or comments. Issue templates include a reminder about this requirement.

## License

By contributing, you agree that your contributions will be licensed under the same license as the project.
