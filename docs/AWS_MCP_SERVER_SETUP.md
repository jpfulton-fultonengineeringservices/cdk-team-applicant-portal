# AWS MCP Server Setup

This project's `.cursor/mcp.json` configures five AWS Labs MCP servers that give Cursor's AI agent real-time access to AWS pricing data, documentation, CDK guidance, IAM management, and Well-Architected security assessments. This guide covers everything you need to run them locally.

---

## Table of Contents

- [Prerequisites](#prerequisites)
- [AWS Credentials](#aws-credentials)
- [Required IAM Permissions](#required-iam-permissions)
- [Configured Servers](#configured-servers)
  - [AWS Pricing MCP Server](#aws-pricing-mcp-server)
  - [AWS Well-Architected Security MCP Server](#aws-well-architected-security-mcp-server)
  - [AWS Documentation MCP Server](#aws-documentation-mcp-server)
  - [CDK MCP Server](#cdk-mcp-server)
  - [IAM MCP Server](#iam-mcp-server)
- [Verifying the Setup](#verifying-the-setup)
- [Troubleshooting](#troubleshooting)

---

## Prerequisites

| Requirement | Version | Install |
|---|---|---|
| Python | 3.10+ | `uv python install 3.10` |
| uv | latest | [Astral install guide](https://docs.astral.sh/uv/getting-started/installation/) |
| AWS CLI | v2 | [AWS install guide](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) |

Install `uv` on macOS/Linux:

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
```

Install Python 3.10 via uv:

```bash
uv python install 3.10
```

All servers are invoked via `uvx` (bundled with `uv`), which downloads and runs each MCP server package on demand from PyPI — no separate `pip install` step is needed.

---

## AWS Credentials

All servers (except the Documentation server) require AWS credentials. The recommended approach is to use a named AWS profile.

**Configure a profile:**

```bash
aws configure --profile your-profile-name
```

**Or use environment variables:**

```bash
export AWS_ACCESS_KEY_ID=your-access-key-id
export AWS_SECRET_ACCESS_KEY=your-secret-access-key
export AWS_SESSION_TOKEN=your-session-token   # if using temporary credentials
export AWS_REGION=us-east-1
```

> **Note:** The `.cursor/mcp.json` in this project does not hardcode an `AWS_PROFILE`. It relies on whatever credentials are active in your shell environment (default profile, environment variables, or an IAM role). If you use a named profile, add `"AWS_PROFILE": "your-profile-name"` to the relevant server's `env` block in your local copy of `.cursor/mcp.json`.

---

## Required IAM Permissions

Different servers need different permissions. At minimum, grant the IAM principal used by Cursor the following:

### Pricing & Documentation servers

```json
{
  "Effect": "Allow",
  "Action": ["pricing:*"],
  "Resource": "*"
}
```

> Pricing API calls are free of charge and do not incur AWS costs.

### Well-Architected Security server

Read-only access to security services:

- `guardduty:List*`, `guardduty:Get*`
- `securityhub:Get*`, `securityhub:List*`, `securityhub:Describe*`
- `inspector2:List*`, `inspector2:Get*`
- `access-analyzer:List*`, `access-analyzer:Get*`
- `config:Get*`, `config:List*`, `config:Describe*`
- `resource-explorer-2:Search`, `resource-explorer-2:GetIndex`
- `ec2:Describe*`, `s3:GetBucketEncryption`, `s3:GetBucketPolicy`, `s3:ListAllMyBuckets`

### IAM server

The IAM server requires broad IAM permissions. See the [full policy in the official docs](https://awslabs.github.io/mcp/servers/iam-mcp-server) or scope it down to the operations your team actually needs. At minimum for read-only use:

```json
{
  "Effect": "Allow",
  "Action": [
    "iam:List*",
    "iam:Get*",
    "iam:SimulatePrincipalPolicy"
  ],
  "Resource": "*"
}
```

---

## Configured Servers

### AWS Pricing MCP Server

**Package:** `awslabs.aws-pricing-mcp-server`
**Docs:** https://awslabs.github.io/mcp/servers/aws-pricing-mcp-server

Provides real-time AWS pricing data, cost analysis, and cost report generation. Can scan CDK projects (including this one) to identify services and estimate costs.

**Environment variables used in this project:**

| Variable | Value | Description |
|---|---|---|
| `FASTMCP_LOG_LEVEL` | `ERROR` | Suppresses verbose startup logs |
| `AWS_REGION` | `us-east-1` | Routes requests to the nearest AWS Pricing API endpoint |

**What it enables:**
- Natural language queries against the AWS Pricing API
- CDK project cost analysis via `analyze_cdk_project`
- Generating cost reports (see `docs/ESTIMATED_COSTS.md`)

---

### AWS Well-Architected Security MCP Server

**Package:** `awslabs.well-architected-security-mcp-server`
**Docs:** https://awslabs.github.io/mcp/servers/well-architected-security-mcp-server

Assesses your AWS environment against the Well-Architected Framework Security Pillar. Requires live AWS credentials with read access to security services.

**Environment variables used in this project:**

| Variable | Value | Description |
|---|---|---|
| `AWS_REGION` | `us-east-1` | Region to assess |
| `FASTMCP_LOG_LEVEL` | `ERROR` | Suppresses verbose startup logs |

**What it enables:**
- Checking whether GuardDuty, Security Hub, Inspector, and IAM Access Analyzer are enabled
- Retrieving security findings filtered by severity
- Verifying storage encryption and network security posture
- Generating Well-Architected security assessment reports

---

### AWS Documentation MCP Server

**Package:** `awslabs.aws-documentation-mcp-server`
**Docs:** https://awslabs.github.io/mcp/servers/aws-documentation-mcp-server

Fetches and searches official AWS documentation. Does **not** require AWS credentials.

**Environment variables used in this project:**

| Variable | Value | Description |
|---|---|---|
| `FASTMCP_LOG_LEVEL` | `ERROR` | Suppresses verbose startup logs |
| `AWS_DOCUMENTATION_PARTITION` | `aws` | Use `aws-cn` for AWS China regions |

> **Corporate networks:** If your proxy blocks certain User-Agent strings, add `"MCP_USER_AGENT": "Mozilla/5.0 ..."` to this server's `env` block.

**What it enables:**
- Searching AWS documentation by keyword or phrase
- Fetching specific documentation pages as markdown
- Getting related content recommendations for a documentation URL

---

### CDK MCP Server

**Package:** `awslabs.cdk-mcp-server`
**Docs:** https://awslabs.github.io/mcp/

Provides CDK-specific guidance, construct patterns, CDK Nag rule explanations, and Bedrock agent schema generation. Does **not** require AWS credentials.

**Environment variables used in this project:**

| Variable | Value | Description |
|---|---|---|
| `FASTMCP_LOG_LEVEL` | `ERROR` | Suppresses verbose startup logs |

**What it enables:**
- CDK best practice guidance and construct recommendations
- AWS Solutions Construct pattern lookup
- CDK Nag suppression checks and rule explanations
- Lambda Powertools documentation lookup
- Bedrock agent schema generation

---

### IAM MCP Server

**Package:** `awslabs.iam-mcp-server`
**Docs:** https://awslabs.github.io/mcp/servers/iam-mcp-server

Manages IAM users, roles, groups, and policies. Supports a `--readonly` flag for safe use in production contexts.

**Environment variables used in this project:**

| Variable | Value | Description |
|---|---|---|
| `AWS_REGION` | `us-east-1` | Target region |
| `FASTMCP_LOG_LEVEL` | `ERROR` | Suppresses verbose startup logs |

> **Note:** This server's entry in `.cursor/mcp.json` uses the split `command`/`args` format (`"command": "uvx"`, `"args": ["awslabs.iam-mcp-server@latest"]`) rather than the inline command string used by the other servers. Both forms are equivalent.

**Read-only mode** — to restrict the server to non-mutating operations only, update the `args` array:

```json
"args": ["awslabs.iam-mcp-server@latest", "--readonly"]
```

**What it enables:**
- Listing and inspecting IAM users, roles, groups, and policies
- Simulating IAM policy permissions before applying them
- Creating and managing IAM resources (when not in read-only mode)

---

## Verifying the Setup

After installing `uv`, you can manually smoke-test any server by starting it in the background, waiting a few seconds to confirm it doesn't crash on startup, then killing it:

```bash
uvx awslabs.aws-documentation-mcp-server@latest &
sleep 5 && kill %1 2>/dev/null
echo "Server started OK"
```

```bash
uvx awslabs.cdk-mcp-server@latest &
sleep 5 && kill %1 2>/dev/null
echo "Server started OK"
```

For servers requiring credentials, ensure your AWS credentials are active first:

```bash
aws sts get-caller-identity
```

Then verify the Pricing server:

```bash
uvx awslabs.aws-pricing-mcp-server@latest &
sleep 5 && kill %1 2>/dev/null
echo "Server started OK"
```

Once `uv` is installed and credentials are configured, Cursor will start the servers automatically when you open this project. You can check server status under **Cursor Settings → MCP**.

---

## Troubleshooting

**Slow first load**
The `@latest` suffix causes `uvx` to check PyPI for updates on every Cursor startup. To skip the check after the initial download, remove `@latest` from the command string in `.cursor/mcp.json`. To force a refresh later, run:

```bash
uvx awslabs.aws-pricing-mcp-server@latest --help
# or clear the cache entirely for one package:
uv cache clean awslabs.aws-pricing-mcp-server
```

**"credentials not found" errors**
Run `aws sts get-caller-identity` to confirm your credentials are active. If using SSO, run `aws sso login --profile your-profile` first, then add `"AWS_PROFILE": "your-profile"` to the affected server's `env` block.

**Server shows as disabled in Cursor**
Check **Cursor Settings → MCP** for error details. Common causes: `uv` is not on `$PATH`, Python 3.10 is not installed, or the server failed to start due to a missing environment variable.

**Documentation server returns no results**
Verify `AWS_DOCUMENTATION_PARTITION` is set to `aws` (not `aws-cn`) for standard AWS regions. If behind a corporate proxy, add a `MCP_USER_AGENT` value matching your browser's User-Agent string.
