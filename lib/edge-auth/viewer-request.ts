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

/**
 * Lambda@Edge Viewer Request handler for Cognito JWT authentication.
 *
 * This function runs at CloudFront edge locations on every viewer request.
 * It reads Cognito configuration from SSM Parameter Store on cold start,
 * validates the JWT token from the user's cookie, and either:
 * - Allows the request through to S3 (valid token)
 * - Redirects to the Cognito Hosted UI login page (no token / invalid token)
 * - Handles the OAuth2 callback to extract and store tokens in cookies
 *
 * Bundled by aws-cdk-lib/aws-lambda-nodejs (esbuild) — no separate package.json needed.
 */

import { CloudFrontRequestEvent, CloudFrontRequestResult, CloudFrontRequest } from 'aws-lambda';
import jwt from 'jsonwebtoken';
import jwksClient from 'jwks-rsa';
import * as cookie from 'cookie';
import { SSMClient, GetParameterCommand } from '@aws-sdk/client-ssm';

// ---------------------------------------------------------------------------
// Config loading via SSM (cached after first cold start)
// ---------------------------------------------------------------------------

interface CognitoConfig {
  userPoolId: string;
  clientId: string;
  region: string;
  cognitoDomainPrefix: string;
  appDomain: string;
}

let cachedConfig: CognitoConfig | null = null;

async function loadConfig(): Promise<CognitoConfig> {
  if (cachedConfig) return cachedConfig;

  // SSM parameter name is embedded at bundle time by NodejsFunction via
  // environment variable injected as a define (see cloudfront-builder.ts).
  const paramName = process.env.COGNITO_CONFIG_PARAM;
  if (!paramName) {
    throw new Error('COGNITO_CONFIG_PARAM environment variable is not set');
  }

  // Lambda@Edge runs in us-east-1 for viewer request events, but the SSM
  // parameter also lives in us-east-1 (same region as the stack).
  const ssm = new SSMClient({ region: 'us-east-1' });
  const result = await ssm.send(
    new GetParameterCommand({ Name: paramName, WithDecryption: false }),
  );

  if (!result.Parameter?.Value) {
    throw new Error(`SSM parameter ${paramName} not found or empty`);
  }

  cachedConfig = JSON.parse(result.Parameter.Value) as CognitoConfig;
  return cachedConfig;
}

// ---------------------------------------------------------------------------
// JWKS client cache (keyed by user pool, persists across warm invocations)
// ---------------------------------------------------------------------------

const jwksClientCache = new Map<string, ReturnType<typeof jwksClient>>();

function getJwksClient(config: CognitoConfig): ReturnType<typeof jwksClient> {
  const key = `${config.region}:${config.userPoolId}`;
  if (!jwksClientCache.has(key)) {
    jwksClientCache.set(
      key,
      jwksClient({
        jwksUri: `https://cognito-idp.${config.region}.amazonaws.com/${config.userPoolId}/.well-known/jwks.json`,
        cache: true,
        cacheMaxAge: 600_000, // 10 minutes
      }),
    );
  }
  return jwksClientCache.get(key)!;
}

// ---------------------------------------------------------------------------
// Token helpers
// ---------------------------------------------------------------------------

async function verifyToken(token: string, config: CognitoConfig): Promise<Record<string, unknown>> {
  const decoded = jwt.decode(token, { complete: true });
  if (!decoded || typeof decoded === 'string') {
    throw new Error('Invalid token format');
  }

  const kid = decoded.header.kid;
  if (!kid) throw new Error('No kid in token header');

  const client = getJwksClient(config);
  const signingKey = await client.getSigningKey(kid);
  const publicKey = signingKey.getPublicKey();

  return jwt.verify(token, publicKey, {
    issuer: `https://cognito-idp.${config.region}.amazonaws.com/${config.userPoolId}`,
    audience: config.clientId,
  }) as Record<string, unknown>;
}

function extractToken(request: CloudFrontRequest, config: CognitoConfig): string | null {
  const cookieHeader = request.headers.cookie?.[0]?.value;
  if (!cookieHeader) return null;
  const cookies = cookie.parse(cookieHeader);
  return cookies[`CognitoIdentityServiceProvider.${config.clientId}.idToken`] ?? null;
}

// ---------------------------------------------------------------------------
// Response builders
// ---------------------------------------------------------------------------

function redirectToLogin(
  request: CloudFrontRequest,
  config: CognitoConfig,
): CloudFrontRequestResult {
  const originalUrl = `https://${config.appDomain}${request.uri}${request.querystring ? '?' + request.querystring : ''}`;
  const loginUrl =
    `https://${config.cognitoDomainPrefix}.auth.${config.region}.amazoncognito.com/oauth2/authorize` +
    `?client_id=${config.clientId}` +
    `&response_type=token` +
    `&scope=openid+email+profile` +
    `&redirect_uri=https://${config.appDomain}/oauth2/callback` +
    `&state=${encodeURIComponent(originalUrl)}`;

  return {
    status: '302',
    statusDescription: 'Found',
    headers: {
      location: [{ key: 'Location', value: loginUrl }],
      'cache-control': [{ key: 'Cache-Control', value: 'no-store' }],
    },
  };
}

// ---------------------------------------------------------------------------
// OAuth callback handler
// Tokens arrive in the URL fragment (#) after Cognito implicit-flow redirect.
// We serve a small HTML page that uses JS to extract the tokens from the
// fragment, stores them in cookies, then redirects to the original destination.
// ---------------------------------------------------------------------------

function escapeHtml(raw: string): string {
  return raw
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function handleOAuthCallback(
  request: CloudFrontRequest,
  config: CognitoConfig,
): CloudFrontRequestResult {
  const params = new URLSearchParams(request.querystring || '');
  const error = params.get('error');

  if (error) {
    // Bug 1 fix: escape user-controlled values before embedding in HTML to prevent XSS.
    const safeError = escapeHtml(error);
    const safeDesc = escapeHtml(params.get('error_description') ?? '');
    return {
      status: '400',
      statusDescription: 'Bad Request',
      headers: { 'content-type': [{ key: 'Content-Type', value: 'text/html; charset=utf-8' }] },
      body: `<!DOCTYPE html><html><head><meta charset="utf-8"><title>Authentication Error</title></head><body><h1>Authentication Error</h1><p>${safeError}${safeDesc ? ': ' + safeDesc : ''}</p><p><a href="/">Return to home</a></p></body></html>`,
    };
  }

  // Bug 2 fix: with implicit flow, Cognito puts `state` in the URL *fragment* (#),
  // not the query string. The server cannot read the fragment — only the browser can.
  // We pass the fallback home URL to the client as a safe JSON constant; the client-side
  // JS extracts the real `state` value from the fragment alongside the tokens.
  const fallbackUrl = `https://${config.appDomain}/`;

  const html = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Signing in...</title>
  <style>
    body { font-family: system-ui, sans-serif; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; background: #f4f6f9; }
    .card { background: #fff; border-radius: 8px; padding: 40px 48px; box-shadow: 0 2px 12px rgba(0,0,0,.1); text-align: center; }
    .spinner { width: 36px; height: 36px; border: 3px solid #e0e0e0; border-top-color: #2563eb; border-radius: 50%; animation: spin .8s linear infinite; margin: 16px auto; }
    @keyframes spin { to { transform: rotate(360deg); } }
    .error { color: #dc2626; margin-top: 16px; }
  </style>
</head>
<body>
  <div class="card">
    <h2>Completing sign-in&hellip;</h2>
    <div id="spinner" class="spinner"></div>
    <p id="status">Processing authentication…</p>
    <div id="err" class="error" style="display:none"></div>
  </div>
  <script>
    (function() {
      var CLIENT_ID = ${JSON.stringify(config.clientId)};
      var APP_DOMAIN = ${JSON.stringify(config.appDomain)};
      var FALLBACK_URL = ${JSON.stringify(fallbackUrl)};

      function setStatus(msg) { document.getElementById('status').textContent = msg; }
      function showError(msg) {
        document.getElementById('spinner').style.display = 'none';
        var el = document.getElementById('err');
        el.style.display = 'block';
        el.textContent = 'Error: ' + msg;
        el.insertAdjacentHTML('beforeend', ' <a href="/">Return to home</a>');
      }

      try {
        var hash = window.location.hash.substring(1);
        if (!hash) throw new Error('No token data in URL fragment');

        var params = new URLSearchParams(hash);
        var idToken = params.get('id_token');
        if (!idToken) throw new Error('Missing id_token');

        var accessToken = params.get('access_token');

        // Extract "state" from the fragment (Cognito puts it there for implicit flow),
        // falling back to the server-provided home URL.
        var redirectUrl = params.get('state') || FALLBACK_URL;

        var expires = new Date(Date.now() + 12 * 60 * 60 * 1000).toUTCString();
        var opts = '; domain=.' + APP_DOMAIN + '; path=/; secure; expires=' + expires + '; SameSite=Lax';
        var prefix = 'CognitoIdentityServiceProvider.' + CLIENT_ID;

        document.cookie = prefix + '.idToken=' + idToken + opts;
        if (accessToken) document.cookie = prefix + '.accessToken=' + accessToken + opts;

        setStatus('Sign-in successful! Redirecting…');
        setTimeout(function() { window.location.href = redirectUrl; }, 800);
      } catch (e) {
        showError(e.message || String(e));
      }
    })();
  </script>
</body>
</html>`;

  return {
    status: '200',
    statusDescription: 'OK',
    headers: {
      'content-type': [{ key: 'Content-Type', value: 'text/html; charset=utf-8' }],
      'cache-control': [{ key: 'Cache-Control', value: 'no-store' }],
    },
    body: html,
  };
}

// ---------------------------------------------------------------------------
// Main handler
// ---------------------------------------------------------------------------

export const handler = async (event: CloudFrontRequestEvent): Promise<CloudFrontRequestResult> => {
  const request = event.Records[0].cf.request;
  const uri = request.uri;

  console.log('viewer-request', uri);

  // Always allow the error page through
  if (uri === '/error.html') return request;

  // Handle OAuth2 callback
  if (uri === '/oauth2/callback') {
    const config = await loadConfig();
    return handleOAuthCallback(request, config);
  }

  // Rewrite directory paths to index.html
  if (uri.endsWith('/')) {
    request.uri = uri + 'index.html';
  }

  // Load config and validate token
  const config = await loadConfig();
  const token = extractToken(request, config);

  if (!token) {
    console.log('No token — redirecting to login');
    return redirectToLogin(request, config);
  }

  try {
    const payload = await verifyToken(token, config);
    // Attach the authenticated user's email as a forwarded header for logging
    request.headers['x-auth-email'] = [
      { key: 'X-Auth-Email', value: String(payload['email'] ?? 'unknown') },
    ];
    return request;
  } catch (err) {
    console.error('Token validation failed', err);
    return redirectToLogin(request, config);
  }
};
