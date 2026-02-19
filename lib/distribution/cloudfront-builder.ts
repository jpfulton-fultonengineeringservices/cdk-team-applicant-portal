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
import * as origins from 'aws-cdk-lib/aws-cloudfront-origins';
import * as acm from 'aws-cdk-lib/aws-certificatemanager';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as logs from 'aws-cdk-lib/aws-logs';
import { NodejsFunction, OutputFormat } from 'aws-cdk-lib/aws-lambda-nodejs';
import * as path from 'path';
import { NagSuppressions } from 'cdk-nag';

export interface CloudFrontConfig {
  readonly dnsName: string;
  readonly companyName: string;
  readonly bucket: s3.IBucket;
  readonly certificate: acm.ICertificate;
}

export interface CloudFrontResult {
  readonly distribution: cloudfront.Distribution;
  readonly viewerRequestFunction: NodejsFunction;
}

/**
 * Creates the CloudFront distribution and Lambda@Edge viewer-request function.
 *
 * The Lambda@Edge function is built and bundled via NodejsFunction + esbuild —
 * no separate package.json or manual compile step required.
 *
 * The SSM parameter name is passed to the function as an environment variable
 * at bundle time (esbuild `define`), so there is no runtime env var lookup
 * overhead (the value is inlined into the bundle).
 */
export class CloudFrontBuilder {
  static create(scope: Construct, config: CloudFrontConfig): CloudFrontResult {
    // ------------------------------------------------------------------
    // Lambda@Edge: viewer request (auth)
    // ------------------------------------------------------------------
    const viewerRequestLogGroup = new logs.LogGroup(scope, 'ViewerRequestLogGroup', {
      // Lambda@Edge creates log groups in the region where the request is handled.
      // We create one in us-east-1 for the primary region; edge regions create
      // their own automatically.
      logGroupName: `/aws/lambda/us-east-1.${cdk.Stack.of(scope).stackName}-ViewerRequest`,
      retention: logs.RetentionDays.ONE_MONTH,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    // The SSM parameter path is a deterministic string derived from companyName.
    // We use esbuild `define` to inline it as a compile-time constant in the bundle.
    // This is necessary because Lambda@Edge viewer-request functions cannot have
    // runtime environment variables, and CDK tokens cannot be used in esbuild defines.
    const ssmParamName = `/${config.companyName}/applicant-portal/cognito-config`;

    const viewerRequestFunction = new NodejsFunction(scope, 'ViewerRequestFn', {
      entry: path.join(__dirname, '../edge-auth/viewer-request.ts'),
      handler: 'handler',
      runtime: lambda.Runtime.NODEJS_24_X,
      timeout: cdk.Duration.seconds(5),
      memorySize: 128,
      logGroup: viewerRequestLogGroup,
      bundling: {
        format: OutputFormat.CJS,
        minify: true,
        sourceMap: false,
        externalModules: [],
        // Inline the SSM path as a constant at bundle time (replaces process.env.COGNITO_CONFIG_PARAM)
        define: {
          'process.env.COGNITO_CONFIG_PARAM': JSON.stringify(ssmParamName),
        },
        target: 'node24',
      },
    });

    // Grant the function permission to read the SSM parameter by constructing the ARN
    viewerRequestFunction.addToRolePolicy(
      new iam.PolicyStatement({
        actions: ['ssm:GetParameter'],
        resources: [
          `arn:aws:ssm:us-east-1:${cdk.Stack.of(scope).account}:parameter${ssmParamName}`,
        ],
      }),
    );

    // Lambda@Edge functions must be versioned
    const viewerRequestVersion = viewerRequestFunction.currentVersion;

    // ------------------------------------------------------------------
    // CloudFront access logs bucket
    // ------------------------------------------------------------------
    const logsBucket = new s3.Bucket(scope, 'AccessLogsBucket', {
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      encryption: s3.BucketEncryption.S3_MANAGED,
      enforceSSL: true,
      objectOwnership: s3.ObjectOwnership.BUCKET_OWNER_PREFERRED,
      lifecycleRules: [
        {
          id: 'ExpireOldLogs',
          enabled: true,
          expiration: cdk.Duration.days(90),
        },
      ],
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    // ------------------------------------------------------------------
    // Origin Access Control (OAC) — modern replacement for OAI
    // ------------------------------------------------------------------
    const oac = new cloudfront.S3OriginAccessControl(scope, 'OAC', {
      description: `OAC for ${config.companyName} applicant portal`,
    });

    const origin = origins.S3BucketOrigin.withOriginAccessControl(config.bucket, {
      originAccessControl: oac,
    });

    // ------------------------------------------------------------------
    // CloudFront Distribution
    // ------------------------------------------------------------------
    const distribution = new cloudfront.Distribution(scope, 'Distribution', {
      comment: `${config.companyName} applicant portal`,
      domainNames: [config.dnsName],
      certificate: config.certificate,
      defaultRootObject: 'index.html',
      priceClass: cloudfront.PriceClass.PRICE_CLASS_100,
      minimumProtocolVersion: cloudfront.SecurityPolicyProtocol.TLS_V1_2_2021,
      httpVersion: cloudfront.HttpVersion.HTTP2_AND_3,
      enableIpv6: true,
      enableLogging: true,
      logBucket: logsBucket,
      logFilePrefix: 'cloudfront-access-logs/',
      logIncludesCookies: false,
      defaultBehavior: {
        origin,
        viewerProtocolPolicy: cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
        cachePolicy: cloudfront.CachePolicy.CACHING_DISABLED,
        originRequestPolicy: cloudfront.OriginRequestPolicy.CORS_S3_ORIGIN,
        allowedMethods: cloudfront.AllowedMethods.ALLOW_GET_HEAD_OPTIONS,
        cachedMethods: cloudfront.CachedMethods.CACHE_GET_HEAD_OPTIONS,
        edgeLambdas: [
          {
            functionVersion: viewerRequestVersion,
            eventType: cloudfront.LambdaEdgeEventType.VIEWER_REQUEST,
          },
        ],
      },
      errorResponses: [
        {
          httpStatus: 403,
          responseHttpStatus: 403,
          responsePagePath: '/error.html',
          ttl: cdk.Duration.minutes(5),
        },
        {
          httpStatus: 404,
          responseHttpStatus: 404,
          responsePagePath: '/error.html',
          ttl: cdk.Duration.minutes(5),
        },
      ],
    });

    // ------------------------------------------------------------------
    // CloudFormation outputs
    // ------------------------------------------------------------------
    new cdk.CfnOutput(scope, 'DistributionId', {
      value: distribution.distributionId,
      description: 'CloudFront distribution ID (use with upload-content.sh)',
      exportName: `${cdk.Stack.of(scope).stackName}-DistributionId`,
    });

    new cdk.CfnOutput(scope, 'DistributionDomainName', {
      value: distribution.distributionDomainName,
      description: 'CloudFront domain — create a CNAME record pointing your dnsName here',
      exportName: `${cdk.Stack.of(scope).stackName}-DistributionDomainName`,
    });

    new cdk.CfnOutput(scope, 'PortalUrl', {
      value: `https://${config.dnsName}`,
      description: 'Applicant portal URL',
      exportName: `${cdk.Stack.of(scope).stackName}-PortalUrl`,
    });

    // CDK Nag suppressions
    CloudFrontBuilder.addNagSuppressions(scope, logsBucket, distribution, viewerRequestFunction);

    return { distribution, viewerRequestFunction };
  }

  private static addNagSuppressions(
    scope: Construct,
    logsBucket: s3.IBucket,
    distribution: cloudfront.Distribution,
    viewerRequestFunction: NodejsFunction,
  ): void {
    NagSuppressions.addResourceSuppressions(
      logsBucket,
      [
        {
          id: 'AwsSolutions-S1',
          reason:
            'This IS the CloudFront access logs bucket. Enabling server access logging on it would create a circular dependency.',
        },
      ],
      true,
    );

    NagSuppressions.addResourceSuppressions(
      distribution,
      [
        {
          id: 'AwsSolutions-CFR1',
          reason:
            'Geo restrictions are not required for this applicant portal. Applicants may be located anywhere in the world.',
        },
        {
          id: 'AwsSolutions-CFR2',
          reason:
            'WAF integration is not required for this portal. Lambda@Edge authentication provides the primary access control layer.',
        },
        {
          id: 'AwsSolutions-CFR4',
          reason: 'TLS 1.2 minimum protocol is enforced via SecurityPolicyProtocol.TLS_V1_2_2021.',
        },
      ],
      true,
    );

    NagSuppressions.addResourceSuppressions(
      viewerRequestFunction,
      [
        {
          id: 'AwsSolutions-IAM4',
          reason:
            'Lambda@Edge uses AWSLambdaBasicExecutionRole managed policy for CloudWatch Logs. This is the AWS-recommended approach.',
          appliesTo: [
            'Policy::arn:<AWS::Partition>:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole',
          ],
        },
        {
          id: 'AwsSolutions-IAM5',
          reason:
            'Lambda@Edge execution role requires wildcard log group permissions because edge log groups are created dynamically in all regions.',
          appliesTo: ['Resource::*'],
        },
      ],
      true,
    );

    if (viewerRequestFunction.role) {
      NagSuppressions.addResourceSuppressions(
        viewerRequestFunction.role,
        [
          {
            id: 'AwsSolutions-IAM5',
            reason:
              'Lambda@Edge execution role requires wildcard log group permissions because edge log groups are created dynamically in all regions.',
            appliesTo: ['Resource::*'],
          },
        ],
        true,
      );
    }
  }
}
