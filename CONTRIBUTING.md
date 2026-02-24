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

- Write clear, descriptive commit messages
- Keep commits focused on a single logical change
- Use personal email addresses for git commits (not corporate email)

## Contributor Identity

Contributors should use personal email addresses for git commits. Corporate affiliation, where applicable, is indicated through GitHub organization membership and the `MAINTAINERS` file. This approach keeps corporate email addresses out of the git history while still providing clear attribution and affiliation.

## Code of Conduct

Be respectful and constructive in all interactions. We are committed to providing a welcoming and inclusive experience for everyone.

## Reporting Issues

When reporting issues, please do not include any confidential or proprietary information in issue titles, descriptions, or comments. Issue templates include a reminder about this requirement.

## License

By contributing, you agree that your contributions will be licensed under the same license as the project.
