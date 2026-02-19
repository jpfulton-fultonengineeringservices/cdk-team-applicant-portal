# Changelog

All notable changes to this project will be documented in this file.

This file is automatically maintained by [release-please](https://github.com/googleapis/release-please).
Do not edit it manually — commit messages following [Conventional Commits](https://www.conventionalcommits.org/)
drive the version bumps and changelog entries.

## [0.1.0] - 2026-02-19

### Features

- Initial release: CDK stack deploying a Cognito-authenticated, CloudFront-served applicant portal
- Lambda@Edge JWT validation at the edge using JWKS
- Invite-only Cognito User Pool with optional TOTP MFA
- Private S3 bucket for static HTML content served via CloudFront OAC
- ACM certificate provisioning (new or imported)
- SSM Parameter Store integration for runtime Cognito configuration
- cdk-nag security compliance checks
- Operational scripts for applicant invite and content upload
