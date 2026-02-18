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
     * Short name used as a prefix for named AWS resources (S3 bucket, Cognito domain, SSM paths).
     * Must be lowercase alphanumeric and hyphens only.
     *
     * Example: 'acme'
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
 * Validate and normalize portal configuration read from CDK context.
 */
export function validateConfig(props: ApplicantPortalProps): PortalConfig {
    if (!props.dnsName || props.dnsName.trim() === '') {
        throw new Error('CDK context "dnsName" is required. Set it in cdk.json or pass --context dnsName=apply.example.com');
    }
    if (!props.companyName || props.companyName.trim() === '') {
        throw new Error('CDK context "companyName" is required. Set it in cdk.json or pass --context companyName=example');
    }
    if (!/^[a-z0-9-]+$/.test(props.companyName)) {
        throw new Error('"companyName" must be lowercase alphanumeric and hyphens only (e.g. "acme", "my-company")');
    }

    return {
        dnsName: props.dnsName.trim(),
        companyName: props.companyName.trim(),
        certificateArn: props.certificateArn && props.certificateArn.trim() !== '' ? props.certificateArn.trim() : undefined,
    };
}
