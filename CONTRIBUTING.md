# Contributing

Thank you for your interest in contributing! This document covers how to get
set up, the standards we follow, and the pull request process.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Development Setup](#development-setup)
- [Building and Testing](#building-and-testing)
- [Code Style](#code-style)
- [Commit Messages](#commit-messages)
- [Developer Certificate of Origin (DCO)](#developer-certificate-of-origin-dco)
- [Pull Request Process](#pull-request-process)
- [Reporting Issues](#reporting-issues)
- [Security Vulnerabilities](#security-vulnerabilities)

---

## Prerequisites

- **Node.js 22+** — [nodejs.org](https://nodejs.org/)
- **Yarn 4** via Corepack:
  ```bash
  corepack enable
  corepack prepare yarn@4.7.0 --activate
  ```
- **AWS CDK CLI** — installed as a dev dependency (`yarn cdk`)
- **AWS CLI** — configured with appropriate credentials (only needed for actual deployments)

---

## Development Setup

```bash
# Clone the repository
git clone https://github.com/jpfulton-fultonengineeringservices/cdk-team-applicant-portal.git
cd cdk-team-applicant-portal

# Install dependencies
yarn install

# Verify the build
yarn build

# Run tests
yarn test
```

---

## Building and Testing

| Command             | Description                         |
| ------------------- | ----------------------------------- |
| `yarn build`        | Compile TypeScript                  |
| `yarn watch`        | Watch mode for development          |
| `yarn test`         | Run Jest test suite                 |
| `yarn lint`         | Run ESLint                          |
| `yarn lint:fix`     | Auto-fix ESLint issues              |
| `yarn format`       | Format with Prettier                |
| `yarn format:check` | Check formatting without writing    |
| `yarn cdk synth`    | Synthesize CloudFormation template  |
| `yarn cdk diff`     | Show pending infrastructure changes |
| `yarn clean`        | Remove compiled output              |

All of `build`, `test`, `lint`, `format:check`, and `cdk synth` must pass before a PR can be merged. The CI workflow enforces this automatically.

---

## Code Style

This project uses **ESLint** and **Prettier** for consistent formatting.

- Run `yarn lint` and `yarn format:check` before submitting a PR, or configure your editor to format on save.
- All TypeScript files must include the Apache 2.0 license header. The ESLint config enforces this — running `yarn lint:fix` will insert it automatically on new files.
- TypeScript strict mode is enabled. Avoid `any` where possible.

---

## Commit Messages

This project uses [Conventional Commits](https://www.conventionalcommits.org/). This is required
because [release-please](https://github.com/googleapis/release-please) reads commit messages to
determine the next semver version and generate the `CHANGELOG.md`.

### Format

```
<type>(<optional scope>): <description>

[optional body]

[optional footers]
```

### Types

| Type       | When to use                                   |
| ---------- | --------------------------------------------- |
| `feat`     | A new feature (triggers a minor version bump) |
| `fix`      | A bug fix (triggers a patch version bump)     |
| `docs`     | Documentation changes only                    |
| `refactor` | Code change that is not a fix or feature      |
| `test`     | Adding or updating tests                      |
| `chore`    | Build process, tooling, or dependency updates |
| `ci`       | CI/CD configuration changes                   |

A `BREAKING CHANGE:` footer (or `!` after the type) triggers a major version bump.

### Examples

```
feat(auth): add TOTP MFA enforcement option
fix(edge): handle missing idToken cookie without throwing
docs: update deployment guide for new ACM cert flow
chore(deps): update aws-cdk-lib to 2.222.0
```

---

## Developer Certificate of Origin (DCO)

All commits must be signed off with a DCO sign-off, certifying that you have the right to
contribute the code under the project's open-source license.

Add `--signoff` (or `-s`) to your commit:

```bash
git commit -s -m "feat: my new feature"
```

This appends a `Signed-off-by: Your Name <your@email.com>` line to the commit message.
The DCO check in CI will reject commits without this line.

The full DCO text is available at [developercertificate.org](https://developercertificate.org/).

---

## Pull Request Process

1. **Fork** the repository and create a feature branch from `main`.
2. Make your changes, following the code style and commit message conventions above.
3. Ensure all CI checks pass locally before opening the PR.
4. Open a pull request against `main` using the provided PR template.
5. At least one review from a code owner is required before merging.
6. PRs are merged via squash or rebase (no merge commits) to maintain a linear history.

### Branch naming

Use a descriptive branch name:

```
feat/add-mfa-enforcement
fix/edge-handler-cookie-null
docs/update-deployment-guide
chore/bump-cdk-lib
```

---

## Reporting Issues

Use the GitHub issue tracker to report bugs or request features. Please use the provided
issue templates — they include prompts for the information that helps us respond quickly.

---

## Security Vulnerabilities

Please **do not** open public issues for security vulnerabilities. Instead, use
[GitHub Security Advisories](https://github.com/jpfulton-fultonengineeringservices/cdk-team-applicant-portal/security/advisories/new).
See [SECURITY.md](SECURITY.md) for the full policy.
