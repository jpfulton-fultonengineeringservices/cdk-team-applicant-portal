#!/usr/bin/env bash
# invite-user.sh
#
# Creates an applicant account in Cognito. Cognito sends the applicant an email
# with a temporary password. On first login they will be prompted to set a
# permanent password via the hosted UI.
#
# Usage:
#   COMPANY_NAME=acme ./scripts/invite-user.sh applicant@example.com "First" "Last"
#
# Required environment variables:
#   COMPANY_NAME — matches the companyName CDK context value (e.g. "acme")
#
# Required arguments:
#   $1  email address
#   $2  given name (first name)
#   $3  family name (last name)
#
# Optional environment variables:
#   AWS_PROFILE  — AWS CLI profile to use (falls back to default)
#   AWS_REGION   — AWS region (defaults to us-east-1)

set -euo pipefail

: "${COMPANY_NAME:?COMPANY_NAME environment variable is required (e.g. COMPANY_NAME=acme)}"

EMAIL="${1:?Usage: $0 <email> <given-name> <family-name>}"
GIVEN_NAME="${2:?Usage: $0 <email> <given-name> <family-name>}"
FAMILY_NAME="${3:?Usage: $0 <email> <given-name> <family-name>}"

STACK_NAME="ApplicantPortal-${COMPANY_NAME}"
AWS_REGION="${AWS_REGION:-us-east-1}"

echo "Stack:       ${STACK_NAME}"
echo "Region:      ${AWS_REGION}"
echo "Email:       ${EMAIL}"
echo "Name:        ${GIVEN_NAME} ${FAMILY_NAME}"
echo ""

echo "Fetching User Pool ID from CloudFormation..."
USER_POOL_ID=$(aws cloudformation describe-stacks \
  --stack-name "${STACK_NAME}" \
  --region "${AWS_REGION}" \
  --query "Stacks[0].Outputs[?ExportName=='${STACK_NAME}-UserPoolId'].OutputValue" \
  --output text)

if [[ -z "${USER_POOL_ID}" ]]; then
  echo "ERROR: Could not find UserPoolId output in stack ${STACK_NAME}." >&2
  exit 1
fi

echo "User Pool: ${USER_POOL_ID}"
echo ""

echo "Creating applicant account..."
aws cognito-idp admin-create-user \
  --user-pool-id "${USER_POOL_ID}" \
  --username "${EMAIL}" \
  --user-attributes \
    Name=email,Value="${EMAIL}" \
    Name=email_verified,Value=true \
    Name=given_name,Value="${GIVEN_NAME}" \
    Name=family_name,Value="${FAMILY_NAME}" \
  --desired-delivery-mediums EMAIL \
  --region "${AWS_REGION}"

echo ""
echo "Invitation sent to ${EMAIL}."
echo "The applicant will receive an email with a temporary password."
echo "They will be prompted to set a permanent password on first login."
echo ""
echo "To resend the invitation (e.g. if it expired):"
echo "  aws cognito-idp admin-create-user \\"
echo "    --user-pool-id ${USER_POOL_ID} \\"
echo "    --username ${EMAIL} \\"
echo "    --message-action RESEND \\"
echo "    --region ${AWS_REGION}"
