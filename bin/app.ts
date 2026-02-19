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
import { AwsSolutionsChecks } from 'cdk-nag';
import { ApplicantPortalStack } from '../lib/applicant-portal-stack.js';
import { normalizeCompanyName } from '../lib/config/portal-config.js';

const app = new cdk.App();

// ---------------------------------------------------------------------------
// Read required parameters from CDK context
// ---------------------------------------------------------------------------
const dnsName: string = app.node.tryGetContext('dnsName') ?? '';
const companyName: string = normalizeCompanyName(app.node.tryGetContext('companyName') ?? '');
const certificateArn: string = app.node.tryGetContext('certificateArn') ?? '';

if (!dnsName || dnsName === 'apply.example.com') {
  console.warn(
    '[WARNING] "dnsName" context is not set or is still the default placeholder.\n' +
      '  Pass --context dnsName=apply.yourcompany.com when running cdk synth/deploy.',
  );
}

if (!companyName || companyName === 'example') {
  console.warn(
    '[WARNING] "companyName" context is not set or is still the default placeholder.\n' +
      '  Pass --context companyName=yourcompany when running cdk synth/deploy.',
  );
}

// ---------------------------------------------------------------------------
// Lambda@Edge and CloudFront ACM certificates MUST be in us-east-1
// ---------------------------------------------------------------------------
const region = process.env.CDK_DEFAULT_REGION ?? process.env.AWS_REGION;
if (region && region !== 'us-east-1') {
  throw new Error(
    `This stack must be deployed to us-east-1 (got "${region}").\n` +
      'Lambda@Edge and CloudFront ACM certificates require us-east-1.\n' +
      'Use: AWS_REGION=us-east-1 yarn cdk deploy  or configure your AWS profile accordingly.',
  );
}

// ---------------------------------------------------------------------------
// Stack instantiation
// ---------------------------------------------------------------------------
const stackId = `ApplicantPortal-${companyName}`;

const stack = new ApplicantPortalStack(app, stackId, {
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: 'us-east-1',
  },
  description: `Cognito-authenticated applicant portal for ${companyName} — managed by CDK`,
  terminationProtection: false,
  dnsName,
  companyName,
  certificateArn: certificateArn || undefined,
});

// ---------------------------------------------------------------------------
// CDK Nag security checks
// ---------------------------------------------------------------------------
cdk.Aspects.of(stack).add(new AwsSolutionsChecks({ verbose: false }));
