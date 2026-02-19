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
import { Template, Match } from 'aws-cdk-lib/assertions';
import { ApplicantPortalStack } from '../lib/applicant-portal-stack.js';
import { normalizeCompanyName } from '../lib/config/portal-config.js';

function makeStack(overrides: Record<string, string> = {}): cdk.Stack {
  const app = new cdk.App({
    context: {
      dnsName: 'apply.test.example.com',
      companyName: 'testco',
      ...overrides,
    },
  });

  return new ApplicantPortalStack(app, 'TestStack', {
    env: { account: '123456789012', region: 'us-east-1' },
    dnsName: overrides['dnsName'] ?? 'apply.test.example.com',
    companyName: overrides['companyName'] ?? 'testco',
    certificateArn: overrides['certificateArn'],
  });
}

describe('normalizeCompanyName', () => {
  test('multi-word with comma and uppercase -> lowercase-with-dashes', () => {
    expect(normalizeCompanyName('Fulton Engineering Services, LLC')).toBe(
      'fulton-engineering-services-llc',
    );
  });

  test('surrounding whitespace and trailing period are stripped', () => {
    expect(normalizeCompanyName('  Acme Corp.  ')).toBe('acme-corp');
  });

  test('apostrophe and ampersand are stripped without leaving double hyphens', () => {
    expect(normalizeCompanyName("O'Brien & Associates")).toBe('obrien-associates');
  });

  test('already-valid slug passes through unchanged', () => {
    expect(normalizeCompanyName('acme')).toBe('acme');
  });

  test('already-valid slug with hyphens passes through unchanged', () => {
    expect(normalizeCompanyName('my-company')).toBe('my-company');
  });
});

describe('validateConfig companyName normalization', () => {
  test('throws when companyName normalizes to an empty string', () => {
    expect(() => {
      const app = new cdk.App();
      new ApplicantPortalStack(app, 'TestStack', {
        env: { account: '123456789012', region: 'us-east-1' },
        dnsName: 'apply.test.example.com',
        companyName: '!!!',
      });
    }).toThrow(/"companyName" could not be normalized/);
  });
});

describe('ApplicantPortalStack', () => {
  let template: Template;

  beforeAll(() => {
    const stack = makeStack();
    template = Template.fromStack(stack);
  });

  // -------------------------------------------------------------------------
  // S3 Content Bucket
  // -------------------------------------------------------------------------
  describe('S3 content bucket', () => {
    test('is created with private access and SSL enforcement', () => {
      template.hasResourceProperties('AWS::S3::Bucket', {
        PublicAccessBlockConfiguration: {
          BlockPublicAcls: true,
          BlockPublicPolicy: true,
          IgnorePublicAcls: true,
          RestrictPublicBuckets: true,
        },
      });
    });

    test('has SSL enforcement bucket policy', () => {
      template.hasResourceProperties('AWS::S3::BucketPolicy', {
        PolicyDocument: {
          Statement: Match.arrayWith([
            Match.objectLike({
              Action: 's3:*',
              Condition: { Bool: { 'aws:SecureTransport': 'false' } },
              Effect: 'Deny',
            }),
          ]),
        },
      });
    });
  });

  // -------------------------------------------------------------------------
  // Cognito User Pool
  // -------------------------------------------------------------------------
  describe('Cognito User Pool', () => {
    test('has self-signup disabled', () => {
      template.hasResourceProperties('AWS::Cognito::UserPool', {
        AdminCreateUserConfig: {
          AllowAdminCreateUserOnly: true,
        },
      });
    });

    test('has email sign-in alias', () => {
      template.hasResourceProperties('AWS::Cognito::UserPool', {
        UsernameAttributes: ['email'],
      });
    });

    test('has MFA set to OPTIONAL', () => {
      template.hasResourceProperties('AWS::Cognito::UserPool', {
        MfaConfiguration: 'OPTIONAL',
      });
    });

    test('creates a hosted UI domain', () => {
      template.resourceCountIs('AWS::Cognito::UserPoolDomain', 1);
    });

    test('creates a user pool client with implicit grant', () => {
      template.hasResourceProperties('AWS::Cognito::UserPoolClient', {
        AllowedOAuthFlows: Match.arrayWith(['implicit']),
      });
    });
  });

  // -------------------------------------------------------------------------
  // SSM Parameter
  // -------------------------------------------------------------------------
  describe('SSM cognito config parameter', () => {
    test('is created', () => {
      template.hasResourceProperties('AWS::SSM::Parameter', {
        Name: '/testco/applicant-portal/cognito-config',
        Type: 'String',
      });
    });
  });

  // -------------------------------------------------------------------------
  // ACM Certificate
  // -------------------------------------------------------------------------
  describe('ACM certificate', () => {
    test('is created when no certificateArn is provided', () => {
      template.resourceCountIs('AWS::CertificateManager::Certificate', 1);
    });

    test('uses DNS validation', () => {
      template.hasResourceProperties('AWS::CertificateManager::Certificate', {
        DomainName: 'apply.test.example.com',
        ValidationMethod: 'DNS',
      });
    });

    test('imports existing certificate when certificateArn is provided', () => {
      const stack = makeStack({
        certificateArn: 'arn:aws:acm:us-east-1:123456789012:certificate/existing',
      });
      const t = Template.fromStack(stack);
      // No new certificate resource should be created
      t.resourceCountIs('AWS::CertificateManager::Certificate', 0);
    });
  });

  // -------------------------------------------------------------------------
  // CloudFront Distribution
  // -------------------------------------------------------------------------
  describe('CloudFront distribution', () => {
    test('is created', () => {
      template.resourceCountIs('AWS::CloudFront::Distribution', 1);
    });

    test('enforces HTTPS redirect', () => {
      template.hasResourceProperties('AWS::CloudFront::Distribution', {
        DistributionConfig: {
          DefaultCacheBehavior: {
            ViewerProtocolPolicy: 'redirect-to-https',
          },
        },
      });
    });

    test('uses TLS 1.2 minimum', () => {
      template.hasResourceProperties('AWS::CloudFront::Distribution', {
        DistributionConfig: {
          ViewerCertificate: {
            MinimumProtocolVersion: 'TLSv1.2_2021',
          },
        },
      });
    });

    test('has custom domain configured', () => {
      template.hasResourceProperties('AWS::CloudFront::Distribution', {
        DistributionConfig: {
          Aliases: ['apply.test.example.com'],
        },
      });
    });

    test('has a Lambda@Edge function associated with viewer request', () => {
      template.hasResourceProperties('AWS::CloudFront::Distribution', {
        DistributionConfig: {
          DefaultCacheBehavior: {
            LambdaFunctionAssociations: Match.arrayWith([
              Match.objectLike({
                EventType: 'viewer-request',
              }),
            ]),
          },
        },
      });
    });
  });

  // -------------------------------------------------------------------------
  // Stack outputs
  // -------------------------------------------------------------------------
  describe('CloudFormation outputs', () => {
    test('exports ContentBucketName', () => {
      template.hasOutput('ContentBucketName', {
        Export: { Name: 'TestStack-ContentBucketName' },
      });
    });

    test('exports DistributionId', () => {
      template.hasOutput('DistributionId', {
        Export: { Name: 'TestStack-DistributionId' },
      });
    });

    test('exports UserPoolId', () => {
      template.hasOutput('UserPoolId', {
        Export: { Name: 'TestStack-UserPoolId' },
      });
    });
  });
});
