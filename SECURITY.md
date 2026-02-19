# Security Policy

## Supported Versions

Only the latest release on `main` is actively supported with security fixes.

| Version | Supported |
| ------- | --------- |
| latest  | Yes       |
| older   | No        |

## Reporting a Vulnerability

**Please do not report security vulnerabilities through public GitHub issues.**

Use [GitHub Security Advisories](https://github.com/jpfulton-fultonengineeringservices/cdk-team-applicant-portal/security/advisories/new) to report a vulnerability privately. This allows us to coordinate disclosure before the issue becomes public.

### What to include

A useful report includes:

- A description of the vulnerability and its potential impact
- Steps to reproduce or a proof-of-concept
- The affected component(s) (e.g., Lambda@Edge handler, CDK stack, deployment scripts)
- Any suggested mitigations or fixes you have already identified

### Response timeline

| Milestone                              | Target                                      |
| -------------------------------------- | ------------------------------------------- |
| Acknowledgement of report              | 48 hours                                    |
| Initial assessment and severity rating | 5 business days                             |
| Fix or mitigation available            | 30 days (critical) / 90 days (moderate/low) |
| Public disclosure                      | After fix is released                       |

We will keep you informed throughout the process and credit you in the release notes unless you prefer to remain anonymous.

## Scope

The following are in scope:

- The Lambda@Edge viewer-request function (`lib/edge-auth/viewer-request.ts`) — authentication and session handling
- CDK construct security misconfigurations (IAM, S3, CloudFront, Cognito)
- The deployment scripts (`scripts/`) — credential handling or injection risks
- Dependencies with known CVEs that affect runtime behavior

The following are **out of scope**:

- AWS account or credential misconfigurations in your own deployment environment
- Vulnerabilities in upstream dependencies without demonstrated impact on this project
- Issues in AWS services themselves (report those to [AWS Security](https://aws.amazon.com/security/vulnerability-reporting/))

## Security Design Notes

This project deploys AWS infrastructure. Key security decisions are documented in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and enforced via [cdk-nag](https://github.com/cdklabs/cdk-nag)
checks that run at synth time.
