# CDK Applicant Portal — Estimated Monthly Costs

> **Data source:** AWS Pricing API (via `aws-pricing-mcp-server`), queried February 2026.
> All prices are ON DEMAND / pay-as-you-go. No Reserved Instances or Savings Plans applied.

---

## Summary

**Expected monthly cost: ~$0.00**

At the intended scale of this portal (10–50 invite-only applicants per hiring cycle), every
service either falls within a permanent free tier or generates costs well below $0.05/month.
The first meaningful billing would occur only if Cognito MAU exceeds 50 users in a month or
CloudFront traffic approaches 10M+ requests/month.

---

## Services Deployed

The following AWS services are provisioned by the `ApplicantPortalStack`:

| Service | Purpose |
|---------|---------|
| Amazon CloudFront | CDN distribution — serves portal content to applicants (PriceClass 100: US, Canada, Europe) |
| AWS Lambda@Edge | Viewer-request auth function — validates Cognito JWT on every CloudFront request |
| Amazon Cognito | User Pool (Essentials plan) — invite-only applicant authentication via Hosted UI |
| Amazon S3 | Two buckets: static content (`index.html`, `error.html`) + CloudFront access logs |
| AWS Systems Manager | Standard StringParameter — stores Cognito config for Lambda@Edge to read |
| Amazon CloudWatch Logs | Two log groups (Lambda@Edge + Cognito), 1-month retention |
| AWS Certificate Manager | Public TLS certificate for the custom domain (us-east-1) |

---

## Assumptions

- Portal is invite-only; user base is **10–50 active applicants per month**
- Each applicant visits ~5 pages per session, up to 2 sessions → **~10 CloudFront requests per user**
- Active hiring period estimate: **5,000 CloudFront requests/month** (conservative ceiling)
- **Caching is intentionally DISABLED** (`CachePolicy.CACHING_DISABLED` in CDK config) — every
  CloudFront request invokes Lambda@Edge (correct for an auth-gated portal)
- Lambda@Edge estimated execution duration: **~200ms** per invocation (SSM GetParameter + JWT
  validation; SSM value is cached in the Lambda execution context after the cold-start fetch)
- Lambda@Edge memory: **128 MB** (0.125 GB) as configured in `CloudFrontBuilder`
- Content bucket stores **2 static HTML files** (~50 KB total)
- SSM parameter is **Standard tier** (CDK default) — storage and API calls at standard throughput are free
- Stack is deployed to **us-east-1** (required for Lambda@Edge + CloudFront ACM constraints)
- No WAF, no Route 53 (DNS is managed externally and not provisioned in this stack)

---

## Unit Pricing (from AWS Pricing API, us-east-1)

### Amazon CloudFront

| Dimension | Rate | Notes |
|-----------|------|-------|
| HTTPS GET requests — US & Canada | $0.0075 per 10,000 requests | `US-Requests-Tier1`, `CA-Requests-Tier1` |
| HTTPS GET requests — Europe | $0.0090 per 10,000 requests | `EU-Requests-Tier1` |
| Data transfer out — US (first 10 TB) | $0.085 / GB | `US-DataTransfer-Out-Bytes` |
| Data transfer out — Europe (first 10 TB) | $0.085 / GB | `EU-DataTransfer-Out-Bytes` |
| Data transfer out — Canada (first 10 TB) | $0.085 / GB | `CA-DataTransfer-Out-Bytes` |

**Free tier (always-on after 12-month new-account free tier expires):**
1 TB data transfer out/month + 10 M HTTP/HTTPS requests/month remain free indefinitely for standard distributions.

### AWS Lambda@Edge

| Dimension | Rate | Notes |
|-----------|------|-------|
| Requests | $0.0000006 per request ($0.60 / 1M) | `Lambda-Edge-Request` — 3× standard Lambda rate |
| Compute duration | $0.00005001 per GB-second | `Lambda-Edge-GB-Second` — 3× standard Lambda rate |

**Free tier (always-on, permanent):** 1,000,000 requests/month + 400,000 GB-seconds/month.
Lambda@Edge shares the standard Lambda free tier.

### Amazon Cognito User Pool

| Tier | MAU Range | Rate |
|------|-----------|------|
| Free | 0 – 50 MAU | $0.00 |
| Tier 1 | 51 – 50,000 MAU | $0.0055 / MAU |
| Tier 2 | 50,001 – 950,000 MAU | $0.0046 / MAU |

Pricing model: **Essentials feature plan**, billed per monthly active user (MAU).

### Amazon S3

| Dimension | Rate | Free Tier (first 12 months) |
|-----------|------|----------------------------|
| Storage (Standard) | $0.023 / GB-month | 5 GB |
| GET requests | $0.0004 / 1,000 requests | 20,000 requests |
| PUT / COPY / POST | $0.005 / 1,000 requests | 2,000 requests |

### AWS Systems Manager — Parameter Store

| Dimension | Rate |
|-----------|------|
| Standard parameter storage | **Free** (up to 10,000 parameters/account) |
| Standard parameter API interactions | **Free** at standard throughput |

### Amazon CloudWatch Logs

| Dimension | Rate | Free Tier (always-on) |
|-----------|------|----------------------|
| Log data ingestion | $0.50 / GB | 5 GB / month |
| Log storage | $0.03 / GB-month | 5 GB / month |

### AWS Certificate Manager

| Dimension | Rate |
|-----------|------|
| Public TLS certificate | **Always free** |

---

## Monthly Cost Calculation

| Service | Estimated Usage | Unit Cost | Monthly Estimate |
|---------|----------------|-----------|-----------------|
| CloudFront requests | 5,000 req × $0.0000007500 | $0.0075 / 10K req | $0.004 |
| CloudFront data transfer | 0.025 GB × $0.085 | $0.085 / GB | $0.002 |
| Lambda@Edge requests | 5,000 req × $0.0000006 | $0.60 / 1M req | $0.003 |
| Lambda@Edge compute | 125 GB-sec × $0.00005001 | $0.00005001 / GB-sec | $0.006 |
| Cognito MAU | ≤50 MAU | $0.00 (free tier) | $0.000 |
| S3 storage | ~0.005 GB | $0.023 / GB-month | $0.001 |
| S3 GET requests | 5,000 req | $0.0004 / 1K req | $0.002 |
| SSM Parameter Store | 1 standard param | Free | $0.000 |
| CloudWatch Logs ingestion | ~0.0005 GB | $0.50 / GB (free tier) | $0.000 |
| CloudWatch Logs storage | ~0.001 GB | $0.03 / GB-month (free tier) | $0.000 |
| ACM certificate | 1 public cert | Always free | $0.000 |
| **Total** | | | **~$0.02 / month** |

> All line items above fall within their respective free tiers at 5,000 requests/month.
> The $0.02 figure represents the theoretical on-demand cost with no free-tier credit applied.

---

## Cost Scaling

| Monthly CloudFront Requests | Lambda@Edge Cost | CloudFront Cost | Cognito (50 MAU) | Approx. Total |
|-----------------------------|-----------------|-----------------|------------------|---------------|
| 5,000 | $0.009 | $0.006 | $0.00 | **~$0.02** |
| 50,000 | $0.09 | $0.06 | $0.00 | **~$0.15** |
| 500,000 | $0.90 | $0.60 | $0.00 | **~$1.50** |
| 1,000,000 | $1.80 | $1.20 | $0.00 | **~$3.00** |
| 10,000,000 | $18.00 | $12.00 | $0.275 | **~$30.00** |

Lambda@Edge is the dominant cost driver at scale because caching is disabled and it fires on
every request. At 10M requests/month, consider adding a post-authentication cache layer.

---

## Exclusions

The following are **not** included in this estimate:

- Route 53 DNS hosting costs (DNS managed externally, not provisioned in this stack)
- WAF (not deployed; suppressed via cdk-nag — `AwsSolutions-CFR2`)
- AWS Shield Advanced (Shield Standard is included automatically at no charge)
- S3 → CloudFront data transfer (free when using Origin Access Control)
- Multi-region Lambda@Edge log group costs (edge regions auto-create log groups; volume is negligible)
- Developer / pipeline / CI costs

---

## Cost Optimization Notes

1. **Caching disabled by design** — `CachePolicy.CACHING_DISABLED` is intentional so that every
   request is authenticated via Lambda@Edge. Lambda@Edge costs scale linearly with traffic. This
   is acceptable at applicant-portal scale; revisit if traffic ever exceeds ~1M requests/month.

2. **SSM caching is already implemented** — the `viewer-request` Lambda@Edge function caches the
   SSM `GetParameter` result in the module-level execution context. Cold starts pay the SSM API
   cost once; all subsequent warm invocations skip it. SSM Standard parameters remain free.

3. **PriceClass 100 is already cost-optimized** — restricting to US, Canada, and Europe avoids the
   higher per-GB and per-request rates of APAC, South America, and other regions
   (`PriceClass.PRICE_CLASS_ALL` would increase data transfer costs by 2–4×).

4. **S3 lifecycle rules are already in place** — incomplete multipart uploads abort after 7 days;
   CloudFront access logs expire after 90 days. No manual hygiene required.

5. **Cognito MAU hygiene** — for recurring hiring cycles, archive or delete applicant accounts
   between cycles to keep the monthly MAU count below the 50-user free tier threshold.
