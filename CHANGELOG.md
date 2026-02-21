# Changelog

All notable changes to this project will be documented in this file.

This file is automatically maintained by [release-please](https://github.com/googleapis/release-please).
Do not edit it manually — commit messages following [Conventional Commits](https://www.conventionalcommits.org/)
drive the version bumps and changelog entries.

## [1.2.0](https://github.com/jpfulton-fultonengineeringservices/cdk-team-applicant-portal/compare/v1.1.1...v1.2.0) (2026-02-21)


### Features

* **ci:** enforce conventional commit format on PR titles ([#16](https://github.com/jpfulton-fultonengineeringservices/cdk-team-applicant-portal/issues/16)) ([7e3bd1b](https://github.com/jpfulton-fultonengineeringservices/cdk-team-applicant-portal/commit/7e3bd1be01599152417bf55f861ecd711021cb47))

## [1.1.1](https://github.com/jpfulton-fultonengineeringservices/cdk-team-applicant-portal/compare/v1.1.0...v1.1.1) (2026-02-20)


### Bug Fixes

* **edge:** resolve cookie module import causing 503 on authenticated requests ([#13](https://github.com/jpfulton-fultonengineeringservices/cdk-team-applicant-portal/issues/13)) ([b549a52](https://github.com/jpfulton-fultonengineeringservices/cdk-team-applicant-portal/commit/b549a522a7704cc3fb5c57af6632cc2828a0ed90))

## [1.1.0](https://github.com/jpfulton-fultonengineeringservices/cdk-team-applicant-portal/compare/v1.0.0...v1.1.0) (2026-02-19)


### Features

* **edge:** upgrade Lambda@Edge runtime to Node.js 24 ([8f0faef](https://github.com/jpfulton-fultonengineeringservices/cdk-team-applicant-portal/commit/8f0faef2a6776058d3d3a67d378c963c18a78aa2))

## 1.0.0 (2026-02-19)


### Features

* add .editorconfig for consistent coding styles across the project ([400a459](https://github.com/jpfulton-fultonengineeringservices/cdk-team-applicant-portal/commit/400a45943bb17e5c307349d91a27be8a29056f86))
* add AWS MCP server configuration and setup documentation ([e9e1373](https://github.com/jpfulton-fultonengineeringservices/cdk-team-applicant-portal/commit/e9e1373ad4b92e52dec485ed4bee396a2ee5b2b9))
* add CHANGELOG.md for project documentation ([3eaa1e7](https://github.com/jpfulton-fultonengineeringservices/cdk-team-applicant-portal/commit/3eaa1e7f7eb26379741d8de2f9a848fdab0c4b7d))
* add CODE_OF_CONDUCT.md to establish community guidelines ([d1bfa57](https://github.com/jpfulton-fultonengineeringservices/cdk-team-applicant-portal/commit/d1bfa57f12ad40fe0f081da9d1131cd70587f1ab))
* add CODEOWNERS file to define repository ownership ([974bf12](https://github.com/jpfulton-fultonengineeringservices/cdk-team-applicant-portal/commit/974bf12cd710c4d13104ac44aa308210c456ab32))
* add CONTRIBUTING.md and SECURITY.md for improved contribution and security guidelines ([d4ed629](https://github.com/jpfulton-fultonengineeringservices/cdk-team-applicant-portal/commit/d4ed6293684e5e855b8c48d47e019772f3be3b67))
* add ESLint and Prettier configuration files for improved code quality ([cda3b36](https://github.com/jpfulton-fultonengineeringservices/cdk-team-applicant-portal/commit/cda3b36b9ef66438c02d0ca18aec91ed3b095248))
* add GitHub workflows for CI, DCO checks, and release management ([5350874](https://github.com/jpfulton-fultonengineeringservices/cdk-team-applicant-portal/commit/5350874d6278b2a544e70ccb66bac785d76fb11c))
* add initial CDK setup for Applicant Portal project ([72443af](https://github.com/jpfulton-fultonengineeringservices/cdk-team-applicant-portal/commit/72443af6f2dd22ffa9943f1c0b3b7aea1ab65476))
* add issue and pull request templates for improved contribution process ([f46feab](https://github.com/jpfulton-fultonengineeringservices/cdk-team-applicant-portal/commit/f46feab358e9e849c1bbba4fe4d04c19912ffd94))
* add LICENSE and NOTICE files for project compliance ([0d661f6](https://github.com/jpfulton-fultonengineeringservices/cdk-team-applicant-portal/commit/0d661f6be2abb11e71bc93463ccec0848538dd61))
* add licensing information and improve code formatting across multiple files ([b54a0af](https://github.com/jpfulton-fultonengineeringservices/cdk-team-applicant-portal/commit/b54a0afed7edd70ec8e0e84c8c0eacb3db90cfb3))
* add release configuration files for automated versioning and changelog management ([e381c48](https://github.com/jpfulton-fultonengineeringservices/cdk-team-applicant-portal/commit/e381c48a12e638157a8da3989581bc773fbef4e0))
* enhance company name handling in invite-user.sh and upload-content.sh ([bfb7b58](https://github.com/jpfulton-fultonengineeringservices/cdk-team-applicant-portal/commit/bfb7b586fac3586ff29a9fe57528d492607a04e3))
* implement company name normalization in portal configuration ([eb305bf](https://github.com/jpfulton-fultonengineeringservices/cdk-team-applicant-portal/commit/eb305bf4bcf7128368c97e66aa64ea6369ae7710))
* update package.json and yarn.lock for improved linting and formatting tools ([2a0065b](https://github.com/jpfulton-fultonengineeringservices/cdk-team-applicant-portal/commit/2a0065b25e3e9312982dbbbc8ef0ae36a9f16adf))


### Bug Fixes

* add validation for company name normalization in scripts ([8af50d3](https://github.com/jpfulton-fultonengineeringservices/cdk-team-applicant-portal/commit/8af50d3746b421668c8188729a804a59a0398109))
* enhance user invitation email body for personalization ([343c63e](https://github.com/jpfulton-fultonengineeringservices/cdk-team-applicant-portal/commit/343c63e0a10aa93c3acf7366b55739869d698e2f))
* improve architecture diagram formatting in README.md ([99335ad](https://github.com/jpfulton-fultonengineeringservices/cdk-team-applicant-portal/commit/99335ad86fc83545f37ea9cfb12638f6a973cc15))
* normalize company name during app initialization ([e04470f](https://github.com/jpfulton-fultonengineeringservices/cdk-team-applicant-portal/commit/e04470fa6d89b1bcbfff23cebf1b47fbc08fbad2))
* update README.md for improved architecture diagram formatting ([0e0889c](https://github.com/jpfulton-fultonengineeringservices/cdk-team-applicant-portal/commit/0e0889c3579e7ccdab3e15d4f3549cc39bfa0209))
* update SMS message format in user invitation ([65d6e33](https://github.com/jpfulton-fultonengineeringservices/cdk-team-applicant-portal/commit/65d6e330c2a92b3513a2b93cc52121108ab4fcf6))

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
