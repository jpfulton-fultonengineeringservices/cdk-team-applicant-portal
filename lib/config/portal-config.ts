/**
 * Configuration for the Applicant Portal CDK stack.
 *
 * Parameters are provided via CDK context (cdk.json or --context flag).
 */

export interface ApplicantPortalProps {
    /**
     * Fully qualified domain name for the portal.
     * Used for CloudFront alternate domain, ACM certificate, and Cognito OAuth callback URL.
     *
     * Example: 'apply.acme.com'
     */
    readonly dnsName: string;

    /**
     * Human-readable company name used as a prefix for named AWS resources
     * (S3 bucket, Cognito domain, SSM paths). Automatically normalized to a
     * lowercase-with-dashes slug.
     *
     * Examples: 'Acme Corp', 'Fulton Engineering Services, LLC', 'acme'
     */
    readonly companyName: string;

    /**
     * Optional ARN of an existing ACM certificate in us-east-1.
     * If omitted or empty, a new certificate is created with DNS validation.
     */
    readonly certificateArn?: string;
}

/**
 * Validated and normalized portal configuration.
 */
export interface PortalConfig {
    readonly dnsName: string;
    readonly companyName: string;
    readonly certificateArn?: string;
}

/**
 * Normalize a raw companyName string into a lowercase-with-dashes slug.
 *
 * Steps:
 *  1. Trim surrounding whitespace
 *  2. Lowercase
 *  3. Strip characters that are not alphanumeric, spaces, or hyphens
 *  4. Collapse runs of whitespace into a single hyphen
 *  5. Collapse runs of hyphens into one
 *  6. Trim leading/trailing hyphens
 *
 * Examples:
 *   "Fulton Engineering Services, LLC" -> "fulton-engineering-services-llc"
 *   "  Acme Corp.  "                   -> "acme-corp"
 *   "O'Brien & Associates"             -> "obrien-associates"
 */
export function normalizeCompanyName(raw: string): string {
    return raw
        .trim()
        .toLowerCase()
        .replace(/[^a-z0-9\s-]/g, '')
        .replace(/\s+/g, '-')
        .replace(/-{2,}/g, '-')
        .replace(/^-|-$/g, '');
}

/**
 * Validate and normalize portal configuration read from CDK context.
 */
export function validateConfig(props: ApplicantPortalProps): PortalConfig {
    if (!props.dnsName || props.dnsName.trim() === '') {
        throw new Error('CDK context "dnsName" is required. Set it in cdk.json or pass --context dnsName=apply.example.com');
    }
    if (!props.companyName || props.companyName.trim() === '') {
        throw new Error('CDK context "companyName" is required. Set it in cdk.json or pass --context companyName=example');
    }

    const companyName = normalizeCompanyName(props.companyName);

    if (!/^[a-z0-9-]+$/.test(companyName)) {
        throw new Error('"companyName" could not be normalized to a valid slug — ensure the name contains at least one letter or digit');
    }

    return {
        dnsName: props.dnsName.trim(),
        companyName,
        certificateArn: props.certificateArn && props.certificateArn.trim() !== '' ? props.certificateArn.trim() : undefined,
    };
}
