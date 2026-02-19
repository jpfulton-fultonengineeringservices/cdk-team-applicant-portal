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
import * as acm from 'aws-cdk-lib/aws-certificatemanager';

export interface CertificateConfig {
  readonly dnsName: string;
  readonly certificateArn?: string;
}

export interface CertificateResult {
  readonly certificate: acm.ICertificate;
}

/**
 * Creates or imports an ACM certificate for the CloudFront distribution.
 *
 * CloudFront requires the certificate to be in us-east-1. The stack enforces
 * this in bin/app.ts.
 *
 * If no certificateArn is provided, a new certificate is created with DNS
 * validation. The validation CNAME records must be added to your DNS provider
 * manually before the certificate will validate and the distribution will
 * become active.
 */
export class CertificateBuilder {
  static create(scope: Construct, config: CertificateConfig): CertificateResult {
    if (config.certificateArn) {
      const certificate = acm.Certificate.fromCertificateArn(
        scope,
        'Certificate',
        config.certificateArn,
      );
      return { certificate };
    }

    const certificate = new acm.Certificate(scope, 'Certificate', {
      domainName: config.dnsName,
      validation: acm.CertificateValidation.fromDns(),
    });

    new cdk.CfnOutput(scope, 'CertificateArn', {
      value: certificate.certificateArn,
      description:
        'ACM certificate ARN — add the DNS validation CNAME records shown in the ACM console',
    });

    new cdk.CfnOutput(scope, 'CertificateValidationNote', {
      value: 'Check the ACM console for CNAME validation records and add them to your DNS provider',
      description: 'Action required before the portal URL will resolve',
    });

    return { certificate };
  }
}
