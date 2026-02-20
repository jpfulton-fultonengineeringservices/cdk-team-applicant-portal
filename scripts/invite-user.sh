#!/usr/bin/env bash
# invite-user.sh
#
# Creates an applicant account in Cognito and sends a temporary-password
# invitation, or resends an existing invitation. Run with --help for full usage.

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_REGION="us-east-1"

source "${SCRIPT_DIR}/lib/portal-common.sh"

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

usage() {
  cat <<EOF
Usage:
  ${SCRIPT_NAME} --email <email> --first <name> --last <name> [options]
  ${SCRIPT_NAME} --resend --email <email> [options]

Invite an applicant to the portal. Cognito emails them a temporary password;
on first login they set a permanent password via the Cognito Hosted UI.
Applicants cannot self-register — each must be explicitly invited.

Required:
  -e, --email <email>    Applicant email address
  -f, --first <name>     Given (first) name          [not required with --resend]
  -l, --last  <name>     Family (last) name           [not required with --resend]

Options:
  -c, --company <name>   Company name — auto-discovered from deployed CloudFormation
                         stacks, or detected from cdk.json if omitted
  -p, --profile <name>   AWS CLI profile to use
  -r, --region <region>  AWS region (default: ${DEFAULT_REGION})
      --resend           Resend invitation to a user whose invite expired
  -y, --yes              Skip confirmation prompt (useful in CI / automation)
      --dry-run          Validate all inputs and resolve the User Pool without making changes
  -h, --help             Show this help message

Examples:
  # Company auto-detected from cdk.json
  ${SCRIPT_NAME} --email jane@example.com --first Jane --last Smith

  # All options explicit
  ${SCRIPT_NAME} --email jane@example.com --first Jane --last Smith \\
    --company acme --profile my-aws-profile

  # Resend an invitation that expired
  ${SCRIPT_NAME} --resend --email jane@example.com --company acme

  # Verify credentials and stack lookup without creating a user
  ${SCRIPT_NAME} --email jane@example.com --first Jane --last Smith --dry-run
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

EMAIL=""
FIRST_NAME=""
LAST_NAME=""
COMPANY_NAME="${COMPANY_NAME:-}"
AWS_PROFILE="${AWS_PROFILE:-}"
REGION="${AWS_REGION:-${DEFAULT_REGION}}"
RESEND=false
YES=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -e|--email)   EMAIL="$2";        shift 2 ;;
    -f|--first)   FIRST_NAME="$2";   shift 2 ;;
    -l|--last)    LAST_NAME="$2";    shift 2 ;;
    -c|--company) COMPANY_NAME="$2"; shift 2 ;;
    -p|--profile) AWS_PROFILE="$2";  shift 2 ;;
    -r|--region)  REGION="$2";       shift 2 ;;
    --resend)     RESEND=true;        shift   ;;
    -y|--yes)     YES=true;           shift   ;;
    --dry-run)    DRY_RUN=true;       shift   ;;
    -h|--help)    usage; exit 0       ;;
    -*)
      echo "ERROR: Unknown option '$1'. Run '${SCRIPT_NAME} --help' for usage." >&2
      exit 1
      ;;
    *)
      echo "ERROR: Unexpected argument '$1'. This script uses named flags." >&2
      echo "       Run '${SCRIPT_NAME} --help' for usage." >&2
      exit 1
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

if [[ -z "${EMAIL}" ]]; then
  echo "ERROR: --email is required." >&2
  exit 1
fi

validate_email "${EMAIL}"

if [[ "${RESEND}" == false ]]; then
  if [[ -z "${FIRST_NAME}" ]]; then
    echo "ERROR: --first is required." >&2
    echo "       To resend an existing invitation: ${SCRIPT_NAME} --resend --email ${EMAIL}" >&2
    exit 1
  fi
  if [[ -z "${LAST_NAME}" ]]; then
    echo "ERROR: --last is required." >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# AWS CLI check, credentials, and stack resolution
# ---------------------------------------------------------------------------

require_aws_cli
build_profile_args
verify_aws_credentials
resolve_portal_stack
print_stack_info

# ---------------------------------------------------------------------------
# Resolve User Pool ID from CloudFormation outputs
# ---------------------------------------------------------------------------

echo "Fetching User Pool ID from CloudFormation..."
USER_POOL_ID="$(get_stack_output "UserPoolId")"
echo "User Pool: ${USER_POOL_ID}"

# ---------------------------------------------------------------------------
# Summary and confirmation
# ---------------------------------------------------------------------------

echo ""
if [[ "${RESEND}" == true ]]; then
  echo "  Action: Resend invitation"
  echo "  Email:  ${EMAIL}"
else
  echo "  Action: Create new applicant account"
  echo "  Email:  ${EMAIL}"
  echo "  Name:   ${FIRST_NAME} ${LAST_NAME}"
fi
echo ""

if [[ "${DRY_RUN}" == true ]]; then
  echo "[dry-run] All inputs valid. No changes made."
  exit 0
fi

confirm_or_abort

echo ""

# ---------------------------------------------------------------------------
# Create account or resend invitation
# ---------------------------------------------------------------------------

if [[ "${RESEND}" == true ]]; then
  echo "Resending invitation to ${EMAIL}..."
  aws cognito-idp admin-create-user \
    --user-pool-id "${USER_POOL_ID}" \
    --username "${EMAIL}" \
    --message-action RESEND \
    --region "${REGION}" \
    "${PROFILE_ARGS[@]}"
else
  # Check if the user already exists before attempting creation
  if aws cognito-idp admin-get-user \
      --user-pool-id "${USER_POOL_ID}" \
      --username "${EMAIL}" \
      --region "${REGION}" \
      "${PROFILE_ARGS[@]}" &>/dev/null; then
    echo "ERROR: A user with email '${EMAIL}' already exists in this User Pool." >&2
    echo "       To resend their invitation:" >&2
    echo "         ${SCRIPT_NAME} --resend --email ${EMAIL} --company ${COMPANY_NAME}" >&2
    exit 1
  fi

  echo "Creating applicant account..."
  aws cognito-idp admin-create-user \
    --user-pool-id "${USER_POOL_ID}" \
    --username "${EMAIL}" \
    --user-attributes \
      Name=email,Value="${EMAIL}" \
      Name=email_verified,Value=true \
      Name=given_name,Value="${FIRST_NAME}" \
      Name=family_name,Value="${LAST_NAME}" \
    --desired-delivery-mediums EMAIL \
    --region "${REGION}" \
    "${PROFILE_ARGS[@]}"
fi

echo ""
echo "Done. Invitation sent to ${EMAIL}."
echo "The applicant will receive a temporary password valid for 7 days."
echo "They will be prompted to set a permanent password on first login."
