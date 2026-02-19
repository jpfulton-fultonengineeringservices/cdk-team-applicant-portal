#!/usr/bin/env bash
# invite-user.sh
#
# Creates an applicant account in Cognito and sends a temporary-password
# invitation, or resends an existing invitation. Run with --help for full usage.

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
DEFAULT_REGION="us-east-1"

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
  -c, --company <name>   Company name — auto-detected from cdk.json if omitted
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
COMPANY_NAME=""
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
# Helpers
# ---------------------------------------------------------------------------

# Mirrors normalizeCompanyName() in lib/config/portal-config.ts so the derived
# stack name always matches what CDK created.
normalize_company_name() {
  local raw="$1"
  echo "${raw}" \
    | sed -E 's/^[[:space:]]+//' \
    | sed -E 's/[[:space:]]+$//' \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9 -]//g' \
    | sed -E 's/[[:space:]]+/-/g' \
    | sed -E 's/-{2,}/-/g' \
    | sed -E 's/^-|-$//g'
}

# Walk up the directory tree looking for cdk.json and extract companyName context.
detect_company_from_cdk_json() {
  local dir="${PWD}"
  while [[ "${dir}" != "/" ]]; do
    local cdk_json="${dir}/cdk.json"
    if [[ -f "${cdk_json}" ]]; then
      local raw=""
      if command -v jq &>/dev/null; then
        raw=$(jq -r '.context.companyName // empty' "${cdk_json}" 2>/dev/null || true)
      elif command -v node &>/dev/null; then
        raw=$(node -e \
          "try{const c=require('${cdk_json}');const v=(c.context||{}).companyName;if(v)process.stdout.write(v)}catch(e){}" \
          2>/dev/null || true)
      fi
      if [[ -n "${raw}" ]]; then
        echo "${raw}"
        return 0
      fi
      # Found cdk.json but no companyName context set — stop walking
      return 1
    fi
    dir="$(dirname "${dir}")"
  done
  return 1
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

# Auto-detect company name from cdk.json if not provided
if [[ -z "${COMPANY_NAME}" ]]; then
  detected="$(detect_company_from_cdk_json || true)"
  if [[ -n "${detected}" ]]; then
    COMPANY_NAME="${detected}"
    echo "Auto-detected company from cdk.json: ${COMPANY_NAME}"
  fi
fi

if [[ -z "${COMPANY_NAME}" ]]; then
  echo "ERROR: --company is required (could not auto-detect from cdk.json)." >&2
  echo "       Run '${SCRIPT_NAME} --help' for usage." >&2
  exit 1
fi

# Normalize to match CDK's derived stack name
COMPANY_NAME="$(normalize_company_name "${COMPANY_NAME}")"

if [[ -z "${EMAIL}" ]]; then
  echo "ERROR: --email is required." >&2
  exit 1
fi

if ! echo "${EMAIL}" | grep -qE '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'; then
  echo "ERROR: '${EMAIL}' does not look like a valid email address." >&2
  exit 1
fi

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
# AWS CLI check and credentials verification
# ---------------------------------------------------------------------------

if ! command -v aws &>/dev/null; then
  echo "ERROR: AWS CLI not found. Install from https://aws.amazon.com/cli/" >&2
  exit 1
fi

# Build profile args array (avoids word-splitting issues with empty strings)
PROFILE_ARGS=()
[[ -n "${AWS_PROFILE}" ]] && PROFILE_ARGS=(--profile "${AWS_PROFILE}")

echo "Verifying AWS credentials..."
if ! IDENTITY=$(aws sts get-caller-identity --region "${REGION}" "${PROFILE_ARGS[@]}" 2>&1); then
  echo "ERROR: AWS credentials check failed. Is your profile/environment configured?" >&2
  echo "       ${IDENTITY}" >&2
  exit 1
fi

ACCOUNT_ID=$(echo "${IDENTITY}" | grep -o '"Account": "[^"]*"' | cut -d'"' -f4)

# ---------------------------------------------------------------------------
# Resolve User Pool ID from CloudFormation outputs
# ---------------------------------------------------------------------------

STACK_NAME="ApplicantPortal-${COMPANY_NAME}"

echo ""
echo "Stack:   ${STACK_NAME}"
echo "Account: ${ACCOUNT_ID}"
echo "Region:  ${REGION}"
echo ""

echo "Fetching User Pool ID from CloudFormation..."
if ! STACK_DESCRIBE=$(aws cloudformation describe-stacks \
    --stack-name "${STACK_NAME}" \
    --region "${REGION}" \
    "${PROFILE_ARGS[@]}" 2>&1); then
  if echo "${STACK_DESCRIBE}" | grep -q "does not exist"; then
    echo "ERROR: Stack '${STACK_NAME}' not found in ${REGION}." >&2
    echo "       Check --company and --region, and verify the stack has been deployed." >&2
  else
    echo "ERROR: Could not describe stack '${STACK_NAME}':" >&2
    echo "       ${STACK_DESCRIBE}" >&2
  fi
  exit 1
fi

USER_POOL_ID=$(aws cloudformation describe-stacks \
  --stack-name "${STACK_NAME}" \
  --region "${REGION}" \
  "${PROFILE_ARGS[@]}" \
  --query "Stacks[0].Outputs[?ExportName=='${STACK_NAME}-UserPoolId'].OutputValue" \
  --output text)

if [[ -z "${USER_POOL_ID}" || "${USER_POOL_ID}" == "None" ]]; then
  echo "ERROR: UserPoolId output not found in stack '${STACK_NAME}'." >&2
  echo "       The stack may be incomplete or still deploying." >&2
  exit 1
fi

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

if [[ "${YES}" == false ]]; then
  read -r -p "Proceed? [y/N] " _confirm
  if [[ ! "${_confirm}" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
  fi
fi

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
