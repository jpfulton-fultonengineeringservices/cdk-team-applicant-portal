# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is an **AWS CDK project** (TypeScript) that deploys a Cognito-authenticated applicant portal. The architecture uses CloudFront + Lambda@Edge + S3 + Cognito to serve static HTML content with JWT-based authentication at the edge.

**Critical constraint**: This stack **MUST** be deployed to `us-east-1` due to Lambda@Edge and CloudFront ACM certificate requirements.

## Build and Test Commands

```bash
# Install dependencies (Yarn 4 with Corepack)
yarn install

# Compile TypeScript
yarn build

# Watch mode for development
yarn watch

# Run tests (Jest)
yarn test

# Clean compiled files
yarn clean
```

## CDK Commands

```bash
# Synthesize CloudFormation template
yarn cdk synth

# Show pending infrastructure changes
yarn cdk diff

# Deploy stack (requires context parameters)
yarn cdk deploy --context dnsName=apply.acme.com --context companyName=acme

# Deploy with existing ACM certificate
yarn cdk deploy \
  --context dnsName=apply.acme.com \
  --context companyName=acme \
  --context certificateArn=arn:aws:acm:us-east-1:123456789012:certificate/abc-123

# Destroy all resources
yarn cdk destroy
```

## Operational Scripts

All scripts share a common library at `scripts/lib/portal-common.sh` (sourced, not
executed directly) which handles company/stack resolution, credential verification,
and other shared boilerplate. Each script supports `--help`, `--dry-run`, and
`--company` / `--profile` / `--region` flags.

```bash
# Invite an applicant (sends temporary password via email)
./scripts/invite-user.sh --email applicant@example.com --first Jane --last Smith
# Resend an expired invitation
./scripts/invite-user.sh --resend --email applicant@example.com --company acme

# List users (table view, company auto-detected from cdk.json)
./scripts/list-users.sh
# Filter and format options
./scripts/list-users.sh --status FORCE_CHANGE_PASSWORD --format quiet
./scripts/list-users.sh --email jane@ --format csv

# Remove a user (prompts for confirmation)
./scripts/remove-user.sh --email applicant@example.com
# Disable instead of delete
./scripts/remove-user.sh --email applicant@example.com --disable
# Bulk-remove expired invitations via pipe
./scripts/list-users.sh --status FORCE_CHANGE_PASSWORD --format quiet \
  | xargs -I {} ./scripts/remove-user.sh --email {} --company acme --yes

# Upload content to S3 and invalidate CloudFront cache
./scripts/upload-content.sh
CONTENT_DIR=./my-content ./scripts/upload-content.sh --company acme
```

## Architecture

### High-Level Flow

```
Applicant → CloudFront → Lambda@Edge (JWT validation) → S3 (static content)
                              ↓ (unauthenticated)
                      Cognito Hosted UI (login)
```

### Component Organization (Builder Pattern)

The CDK stack uses a builder pattern with specialized modules:

1. **ApplicantPortalStack** (`lib/applicant-portal-stack.ts`)
   - Main orchestration layer
   - Composes all builders to create the complete stack
   - Validates configuration via `validateConfig()`

2. **ContentBucketBuilder** (`lib/storage/content-bucket-builder.ts`)
   - Creates private S3 bucket for static content
   - Enforces SSL-only access via bucket policy
   - Blocks all public access

3. **CognitoAuthBuilder** (`lib/auth/cognito-auth-builder.ts`)
   - Creates User Pool with admin-only user creation (invite-only)
   - Configures OAuth2 implicit flow via Hosted UI
   - Stores configuration in SSM Parameter Store at `/{companyName}/applicant-portal/cognito-config`
   - Lambda@Edge reads this parameter at runtime for JWT validation

4. **CertificateBuilder** (`lib/distribution/certificate-builder.ts`)
   - Uses existing ACM certificate (if `certificateArn` provided)
   - Creates new certificate with DNS validation (if ARN empty)
   - Must be in us-east-1 for CloudFront

5. **CloudFrontBuilder** (`lib/distribution/cloudfront-builder.ts`)
   - Creates CloudFront distribution with custom domain
   - Bundles and attaches Lambda@Edge viewer-request function
   - Uses `NodejsFunction` with esbuild for efficient bundling

6. **Lambda@Edge Viewer Request** (`lib/edge-auth/viewer-request.ts`)
   - Runs at CloudFront edge locations on every request
   - Validates JWT tokens from cookies using JWKS
   - Redirects unauthenticated users to Cognito Hosted UI
   - Handles OAuth2 callback and sets secure cookies
   - Reads Cognito config from SSM Parameter Store

### Configuration Pattern

Configuration is validated centrally via `lib/config/portal-config.ts`:

- Type-safe configuration interface (`ApplicantPortalProps`)
- Runtime validation with helpful error messages
- CDK context parameters: `dnsName`, `companyName`, `certificateArn`

### Authentication Flow

1. User requests `apply.acme.com`
2. Lambda@Edge checks for valid JWT in cookie
3. If invalid/missing: redirect to Cognito Hosted UI
4. User logs in → Cognito redirects to callback with tokens
5. Lambda@Edge validates JWT via JWKS, sets secure HTTPOnly cookie
6. Subsequent requests use cookie for authentication

## Testing Strategy

Tests use Jest with ts-jest (`test/applicant-portal.test.ts`):

- S3 bucket security policies
- Cognito configuration (self-signup disabled, OAuth flow)
- SSM parameter creation
- CloudFront distribution setup
- Lambda@Edge function bundling
- ACM certificate handling

## Key Dependencies

- **aws-cdk-lib** (2.221.0) - CDK constructs
- **cdk-nag** - Automated security compliance checks
- **jsonwebtoken** & **jwks-rsa** - JWT validation in Lambda@Edge
- **cookie** - Cookie parsing for authentication
- **@aws-sdk/client-ssm** - Parameter Store access in Lambda@Edge
- **esbuild** - Fast Lambda bundling via `NodejsFunction`

## Security Features

1. **Private S3 bucket** with public access blocked
2. **SSL/TLS enforcement** via bucket policy (denies non-HTTPS)
3. **JWT validation** at edge using JWKS
4. **XSS protection** via HTML escaping in Lambda@Edge
5. **Secure cookies** (HTTPOnly, Secure, SameSite=Lax)
6. **Invite-only registration** (admin-managed user creation)
7. **Optional TOTP MFA** support
8. **cdk-nag** compliance checks integrated

## Development Notes

- **Node.js 22+** required
- **Yarn 4** managed via Corepack (`corepack enable && corepack prepare yarn@4.7.0 --activate`)
- **TypeScript 5.6** with ES2022 target and NodeNext modules
- **ESM modules** (`.js` extensions in imports required)
- Lambda@Edge code is bundled inline (no separate bundling step needed)
- The `companyName` context is embedded into Lambda@Edge code at bundle time to construct SSM parameter path

## Troubleshooting

- **Certificate validation stuck**: If CDK creates a new ACM certificate, check ACM console for DNS validation record to add to DNS provider
- **CloudFront 403 errors**: Check Lambda@Edge CloudWatch Logs in the region nearest to you (Lambda@Edge logs are regional)
- **User can't log in**: Verify user was created via `invite-user.sh` script (self-signup is disabled)
- **Content not updating**: Run `upload-content.sh` which invalidates CloudFront cache
