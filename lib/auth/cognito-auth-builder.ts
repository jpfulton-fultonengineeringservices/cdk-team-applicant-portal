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
import * as cognito from 'aws-cdk-lib/aws-cognito';
import * as ssm from 'aws-cdk-lib/aws-ssm';
import * as logs from 'aws-cdk-lib/aws-logs';
import { NagSuppressions } from 'cdk-nag';

export interface CognitoAuthConfig {
  readonly dnsName: string;
  readonly companyName: string;
}

export interface CognitoAuthResult {
  readonly userPool: cognito.UserPool;
  readonly userPoolClient: cognito.UserPoolClient;
  readonly cognitoDomain: cognito.UserPoolDomain;
  readonly cognitoConfigParameter: ssm.StringParameter;
}

/**
 * Creates a Cognito User Pool for the applicant portal.
 *
 * Design choices:
 * - Essentials feature plan (no advanced threat protection)
 * - Invite-only (admin creates users via invite-user.sh)
 * - Optional TOTP MFA
 * - No passkeys (overkill for this use case)
 * - OAuth implicit flow via Cognito Hosted UI
 * - Cognito configuration stored in SSM for Lambda@Edge to read at runtime
 */
export class CognitoAuthBuilder {
  static create(scope: Construct, config: CognitoAuthConfig): CognitoAuthResult {
    const userPool = new cognito.UserPool(scope, 'UserPool', {
      userPoolName: `${config.companyName}-applicant-portal`,
      selfSignUpEnabled: false,
      signInAliases: {
        email: true,
      },
      autoVerify: {
        email: true,
      },
      standardAttributes: {
        email: {
          required: true,
          mutable: false,
        },
        givenName: {
          required: true,
          mutable: true,
        },
        familyName: {
          required: true,
          mutable: true,
        },
      },
      passwordPolicy: {
        minLength: 10,
        requireLowercase: true,
        requireUppercase: true,
        requireDigits: true,
        requireSymbols: true,
        tempPasswordValidity: cdk.Duration.days(7),
      },
      accountRecovery: cognito.AccountRecovery.EMAIL_ONLY,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
      mfa: cognito.Mfa.OPTIONAL,
      mfaSecondFactor: {
        sms: false,
        otp: true,
      },
      featurePlan: cognito.FeaturePlan.ESSENTIALS,
      userInvitation: {
        emailSubject: 'Your applicant portal invitation',
        // Cognito requires both {username} and {####} in the email body and smsMessage.
        emailBody: `Hello {username},\n\nYou have been invited to access the ${config.companyName} applicant portal.\n\nYour temporary password is: {####}\n\nPlease visit https://${config.dnsName} to log in and complete your setup.\n\nThis invitation will expire in 7 days.`,
        smsMessage: '{username}, your temporary password for the applicant portal is {####}',
      },
    });

    // Cognito Hosted UI domain prefix
    const domainPrefix = `${config.companyName}-applicant-portal`;

    const cognitoDomain = userPool.addDomain('HostedUiDomain', {
      cognitoDomain: {
        domainPrefix,
      },
    });

    const userPoolClient = new cognito.UserPoolClient(scope, 'UserPoolClient', {
      userPool,
      userPoolClientName: `${config.companyName}-applicant-portal-client`,
      generateSecret: false,
      oAuth: {
        flows: {
          implicitCodeGrant: true,
        },
        scopes: [cognito.OAuthScope.OPENID, cognito.OAuthScope.EMAIL, cognito.OAuthScope.PROFILE],
        callbackUrls: [`https://${config.dnsName}/oauth2/callback`],
        logoutUrls: [`https://${config.dnsName}/`],
      },
      supportedIdentityProviders: [cognito.UserPoolClientIdentityProvider.COGNITO],
      writeAttributes: new cognito.ClientAttributes().withStandardAttributes({
        email: true,
        givenName: true,
        familyName: true,
      }),
      readAttributes: new cognito.ClientAttributes().withStandardAttributes({
        email: true,
        emailVerified: true,
        givenName: true,
        familyName: true,
      }),
      preventUserExistenceErrors: true,
      authSessionValidity: cdk.Duration.minutes(3),
      idTokenValidity: cdk.Duration.hours(12),
      accessTokenValidity: cdk.Duration.hours(12),
      refreshTokenValidity: cdk.Duration.days(30),
    });

    // CloudWatch log group for Cognito authentication events
    new logs.LogGroup(scope, 'CognitoLogGroup', {
      logGroupName: `/aws/cognito/userpool/${config.companyName}-applicant-portal`,
      retention: logs.RetentionDays.ONE_MONTH,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    // Store Cognito configuration in SSM so Lambda@Edge can read it at runtime.
    // This avoids embedding resolved values at CDK synth time and eliminates the
    // need for a two-phase deploy.
    const cognitoConfigParameter = new ssm.StringParameter(scope, 'CognitoConfigParameter', {
      parameterName: `/${config.companyName}/applicant-portal/cognito-config`,
      description: 'Cognito configuration for Lambda@Edge JWT validation',
      stringValue: JSON.stringify({
        userPoolId: userPool.userPoolId,
        clientId: userPoolClient.userPoolClientId,
        region: cdk.Stack.of(scope).region,
        cognitoDomainPrefix: domainPrefix,
        appDomain: config.dnsName,
      }),
    });

    // CloudFormation outputs
    new cdk.CfnOutput(scope, 'UserPoolId', {
      value: userPool.userPoolId,
      description: 'Cognito User Pool ID',
      exportName: `${cdk.Stack.of(scope).stackName}-UserPoolId`,
    });

    new cdk.CfnOutput(scope, 'UserPoolClientId', {
      value: userPoolClient.userPoolClientId,
      description: 'Cognito User Pool Client ID',
      exportName: `${cdk.Stack.of(scope).stackName}-UserPoolClientId`,
    });

    new cdk.CfnOutput(scope, 'CognitoHostedUiUrl', {
      value: `https://${domainPrefix}.auth.${cdk.Stack.of(scope).region}.amazoncognito.com/login`,
      description: 'Cognito Hosted UI login URL',
    });

    new cdk.CfnOutput(scope, 'CognitoConfigSsmParam', {
      value: cognitoConfigParameter.parameterName,
      description: 'SSM parameter name containing Cognito config for Lambda@Edge',
    });

    CognitoAuthBuilder.addNagSuppressions(scope, userPool);

    return {
      userPool,
      userPoolClient,
      cognitoDomain,
      cognitoConfigParameter,
    };
  }

  private static addNagSuppressions(scope: Construct, userPool: cognito.UserPool): void {
    NagSuppressions.addResourceSuppressions(
      userPool,
      [
        {
          id: 'AwsSolutions-COG2',
          reason:
            'MFA is set to OPTIONAL per product decision. Applicants are short-term users; mandatory MFA would create support burden for a temporary credential.',
        },
        {
          id: 'AwsSolutions-COG3',
          reason:
            'Advanced security (threat protection) requires the PLUS feature plan. Essentials plan is intentional for this use case.',
        },
      ],
      true,
    );
  }
}
