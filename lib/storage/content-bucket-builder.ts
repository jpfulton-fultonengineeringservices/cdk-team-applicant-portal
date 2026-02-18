import * as cdk from 'aws-cdk-lib';
import { Construct } from 'constructs';
import * as s3 from 'aws-cdk-lib/aws-s3';
import { NagSuppressions } from 'cdk-nag';

export interface ContentBucketConfig {
    readonly companyName: string;
}

export interface ContentBucketResult {
    readonly bucket: s3.Bucket;
}

/**
 * Creates an S3 bucket for applicant portal static content with security best practices.
 *
 * - Private (no public access)
 * - S3-managed encryption at rest
 * - SSL enforced
 * - CloudFront accesses via OAC (no public bucket policy)
 * - Content uploaded manually via the upload-content.sh script
 */
export class ContentBucketBuilder {
    static create(scope: Construct, config: ContentBucketConfig): ContentBucketResult {
        const bucket = new s3.Bucket(scope, 'ContentBucket', {
            bucketName: `${config.companyName}-applicant-portal-${cdk.Stack.of(scope).account}-${cdk.Stack.of(scope).region}`,
            blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
            encryption: s3.BucketEncryption.S3_MANAGED,
            enforceSSL: true,
            versioned: false,
            removalPolicy: cdk.RemovalPolicy.RETAIN,
            lifecycleRules: [
                {
                    id: 'DeleteIncompleteMultipartUploads',
                    enabled: true,
                    abortIncompleteMultipartUploadAfter: cdk.Duration.days(7),
                },
            ],
        });

        NagSuppressions.addResourceSuppressions(
            bucket,
            [
                {
                    id: 'AwsSolutions-S1',
                    reason: 'Server access logging would require a separate logs bucket. CloudFront access logs (on the distribution) provide equivalent visibility. Content-only bucket; no API-level access outside of CloudFront OAC.',
                },
            ]
        );

        new cdk.CfnOutput(scope, 'ContentBucketName', {
            value: bucket.bucketName,
            description: 'S3 bucket name for portal content (use with upload-content.sh)',
            exportName: `${cdk.Stack.of(scope).stackName}-ContentBucketName`,
        });

        return { bucket };
    }
}
