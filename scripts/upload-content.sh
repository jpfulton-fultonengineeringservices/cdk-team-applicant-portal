#!/usr/bin/env bash
# upload-content.sh
#
# Syncs a local content folder to the applicant portal S3 bucket and
# creates a CloudFront cache invalidation so changes are served immediately.
#
# Usage:
#   COMPANY_NAME=acme CONTENT_DIR=./content ./scripts/upload-content.sh
#
# Required environment variables:
#   COMPANY_NAME  — matches the companyName CDK context value (e.g. "acme")
#   CONTENT_DIR   — local folder containing index.html, error.html, etc.
#
# Optional environment variables:
#   AWS_PROFILE   — AWS CLI profile to use (falls back to default)
#   AWS_REGION    — AWS region (defaults to us-east-1)

set -euo pipefail

: "${COMPANY_NAME:?COMPANY_NAME environment variable is required (e.g. COMPANY_NAME=acme)}"
: "${CONTENT_DIR:?CONTENT_DIR environment variable is required (e.g. CONTENT_DIR=./content)}"

STACK_NAME="ApplicantPortal-${COMPANY_NAME}"
AWS_REGION="${AWS_REGION:-us-east-1}"

echo "Stack:       ${STACK_NAME}"
echo "Region:      ${AWS_REGION}"
echo "Content dir: ${CONTENT_DIR}"
echo ""

if [[ ! -d "${CONTENT_DIR}" ]]; then
  echo "ERROR: Content directory '${CONTENT_DIR}' does not exist." >&2
  exit 1
fi

if [[ ! -f "${CONTENT_DIR}/index.html" ]]; then
  echo "ERROR: ${CONTENT_DIR}/index.html is missing. The portal requires an index.html." >&2
  exit 1
fi

echo "Fetching CloudFormation stack outputs..."
OUTPUTS=$(aws cloudformation describe-stacks \
  --stack-name "${STACK_NAME}" \
  --region "${AWS_REGION}" \
  --query "Stacks[0].Outputs" \
  --output json)

BUCKET=$(echo "${OUTPUTS}" | \
  python3 -c "import sys,json; outputs=json.load(sys.stdin); print(next(o['OutputValue'] for o in outputs if o.get('ExportName') == '${STACK_NAME}-ContentBucketName'))")

DIST_ID=$(echo "${OUTPUTS}" | \
  python3 -c "import sys,json; outputs=json.load(sys.stdin); print(next(o['OutputValue'] for o in outputs if o.get('ExportName') == '${STACK_NAME}-DistributionId'))")

if [[ -z "${BUCKET}" ]]; then
  echo "ERROR: Could not find ContentBucketName output in stack ${STACK_NAME}." >&2
  exit 1
fi

if [[ -z "${DIST_ID}" ]]; then
  echo "ERROR: Could not find DistributionId output in stack ${STACK_NAME}." >&2
  exit 1
fi

echo "Bucket:       s3://${BUCKET}"
echo "Distribution: ${DIST_ID}"
echo ""

echo "Syncing content to S3..."
aws s3 sync "${CONTENT_DIR}" "s3://${BUCKET}/" \
  --delete \
  --region "${AWS_REGION}" \
  --cache-control "no-cache, no-store, must-revalidate"

echo ""
echo "Creating CloudFront cache invalidation..."
INVALIDATION_ID=$(aws cloudfront create-invalidation \
  --distribution-id "${DIST_ID}" \
  --paths "/*" \
  --query "Invalidation.Id" \
  --output text)

echo "Invalidation created: ${INVALIDATION_ID}"
echo ""
echo "Done. Changes will be live within ~60 seconds as the invalidation propagates."
