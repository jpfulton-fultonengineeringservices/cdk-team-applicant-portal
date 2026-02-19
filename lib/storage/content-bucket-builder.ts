// Copyright 2025-2026 J. Patrick Fulton
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

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

    NagSuppressions.addResourceSuppressions(bucket, [
      {
        id: 'AwsSolutions-S1',
        reason:
          'Server access logging would require a separate logs bucket. CloudFront access logs (on the distribution) provide equivalent visibility. Content-only bucket; no API-level access outside of CloudFront OAC.',
      },
    ]);

    new cdk.CfnOutput(scope, 'ContentBucketName', {
      value: bucket.bucketName,
      description: 'S3 bucket name for portal content (use with upload-content.sh)',
      exportName: `${cdk.Stack.of(scope).stackName}-ContentBucketName`,
    });

    return { bucket };
  }
}
