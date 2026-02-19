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
import * as cloudfront from 'aws-cdk-lib/aws-cloudfront';
import * as acm from 'aws-cdk-lib/aws-certificatemanager';
import { ApplicantPortalProps, validateConfig } from './config/portal-config.js';
import { ContentBucketBuilder } from './storage/content-bucket-builder.js';
import { CognitoAuthBuilder } from './auth/cognito-auth-builder.js';
import { CertificateBuilder } from './distribution/certificate-builder.js';
import { CloudFrontBuilder } from './distribution/cloudfront-builder.js';

export interface ApplicantPortalStackProps extends cdk.StackProps, ApplicantPortalProps {}

/**
 * ApplicantPortalStack
 *
 * Deploys a Cognito-authenticated, CloudFront-served portal for engineering
 * team applicants. Applicants log in via the Cognito Hosted UI and access
 * static HTML documents served from a private S3 bucket.
 *
 * Required CDK context:
 *   dnsName     — fully qualified domain name (e.g. apply.acme.com)
 *   companyName — short resource prefix (e.g. acme)
 *
 * Optional CDK context:
 *   certificateArn — existing ACM certificate ARN in us-east-1
 *
 * This stack MUST be deployed to us-east-1 (Lambda@Edge + CloudFront ACM constraint).
 */
export class ApplicantPortalStack extends cdk.Stack {
  public readonly bucket: s3.IBucket;
  public readonly distribution: cloudfront.Distribution;
  public readonly certificate: acm.ICertificate;

  constructor(scope: Construct, id: string, props: ApplicantPortalStackProps) {
    super(scope, id, props);

    const config = validateConfig(props);

    // S3 content bucket
    const { bucket } = ContentBucketBuilder.create(this, {
      companyName: config.companyName,
    });
    this.bucket = bucket;

    // ACM certificate (us-east-1 required — enforced in bin/app.ts)
    const { certificate } = CertificateBuilder.create(this, {
      dnsName: config.dnsName,
      certificateArn: config.certificateArn,
    });
    this.certificate = certificate;

    // Cognito User Pool + SSM config parameter
    // The SSM parameter name is /{companyName}/applicant-portal/cognito-config
    // The Lambda@Edge function constructs this path from companyName at bundle time.
    CognitoAuthBuilder.create(this, {
      dnsName: config.dnsName,
      companyName: config.companyName,
    });

    // CloudFront distribution + Lambda@Edge viewer-request function
    const { distribution } = CloudFrontBuilder.create(this, {
      dnsName: config.dnsName,
      companyName: config.companyName,
      bucket,
      certificate,
    });
    this.distribution = distribution;

    cdk.Tags.of(this).add('Project', 'applicant-portal');
    cdk.Tags.of(this).add('ManagedBy', 'cdk');
  }
}
