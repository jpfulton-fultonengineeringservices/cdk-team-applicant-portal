#!/usr/bin/env bash
# remove-user.sh
#
# Removes or disables an applicant account in the Cognito User Pool.
# Shows account details and prompts for confirmation before acting.
# Run with --help for full usage.

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
  ${SCRIPT_NAME} --email <email> [options]

Remove or disable an applicant account. Account details are displayed before
any action is taken. Deletion is permanent; use --disable for a reversible
alternative that blocks login without deleting the account.

Required:
  -e, --email <email>    Email address of the account to remove

Options:
  -c, --company <name>   Company name — auto-discovered from deployed CloudFormation
                         stacks, or detected from cdk.json if omitted
  -p, --profile <name>   AWS CLI profile to use
  -r, --region <region>  AWS region (default: ${DEFAULT_REGION})
      --disable          Disable the account instead of deleting it (reversible)
  -y, --yes              Skip confirmation prompt (useful in CI / automation)
      --dry-run          Display account details and planned action without making changes
  -h, --help             Show this help message

Examples:
  # Remove a user (prompts for confirmation)
  ${SCRIPT_NAME} --email jane@example.com

  # Disable instead of delete
  ${SCRIPT_NAME} --email jane@example.com --disable

  # Skip confirmation — useful in scripts
  ${SCRIPT_NAME} --email jane@example.com --yes

  # Preview what would happen without making any changes
  ${SCRIPT_NAME} --email jane@example.com --dry-run

  # Pipe from list-users.sh to bulk-remove expired invitations
  ./scripts/list-users.sh --status FORCE_CHANGE_PASSWORD --format quiet \\
    | xargs -I {} ${SCRIPT_NAME} --email {} --company acme --yes
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

EMAIL=""
COMPANY_NAME="${COMPANY_NAME:-}"
AWS_PROFILE="${AWS_PROFILE:-}"
REGION="${AWS_REGION:-${DEFAULT_REGION}}"
DISABLE=false
YES=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -e|--email)   require_arg "$1" "${2:-}" $#; EMAIL="$2";        shift 2 ;;
    -c|--company) require_arg "$1" "${2:-}" $#; COMPANY_NAME="$2"; shift 2 ;;
    -p|--profile) require_arg "$1" "${2:-}" $#; AWS_PROFILE="$2";  shift 2 ;;
    -r|--region)  require_arg "$1" "${2:-}" $#; REGION="$2";       shift 2 ;;
    --disable)    DISABLE=true;       shift   ;;
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

# ---------------------------------------------------------------------------
# AWS CLI check, credentials, and stack resolution
# ---------------------------------------------------------------------------

ensure_dependencies
build_profile_args
verify_aws_credentials
resolve_portal_stack
print_stack_info

# ---------------------------------------------------------------------------
# Resolve User Pool ID from CloudFormation outputs
# ---------------------------------------------------------------------------

echo "Fetching User Pool ID from CloudFormation..."
prefetch_stack_outputs
USER_POOL_ID="$(get_stack_output "UserPoolId")"
echo "User Pool: ${USER_POOL_ID}"

# ---------------------------------------------------------------------------
# Fetch user details
# ---------------------------------------------------------------------------

echo ""
echo "Looking up user '${EMAIL}'..."

USER_JSON=""
if ! USER_JSON=$(aws cognito-idp admin-get-user \
    --user-pool-id "${USER_POOL_ID}" \
    --username "${EMAIL}" \
    --region "${REGION}" \
    "${PROFILE_ARGS[@]}" \
    --output json 2>&1); then
  if echo "${USER_JSON}" | grep -qiE "UserNotFoundException|User does not exist"; then
    echo "ERROR: No user with email '${EMAIL}' exists in this User Pool." >&2
    echo "       Run '${SCRIPT_NAME%remove-user.sh}list-users.sh' to see current users." >&2
    exit 1
  fi
  echo "ERROR: Could not retrieve user '${EMAIL}':" >&2
  echo "       ${USER_JSON}" >&2
  exit 1
fi

GIVEN_NAME="$(extract_user_attr "${USER_JSON}" "given_name")"
FAMILY_NAME="$(extract_user_attr "${USER_JSON}" "family_name")"
FULL_NAME="${GIVEN_NAME} ${FAMILY_NAME}"
FULL_NAME="${FULL_NAME## }"
FULL_NAME="${FULL_NAME%% }"

USER_STATUS="$(extract_user_field "${USER_JSON}" "UserStatus")"
USER_CREATED="$(extract_user_field "${USER_JSON}" "UserCreateDate")"
USER_ENABLED="$(extract_user_field "${USER_JSON}" "Enabled")"
USER_MODIFIED="$(extract_user_field "${USER_JSON}" "UserLastModifiedDate")"

# MFA preferences (non-critical; show if present)
MFA_OPTIONS=""
if command -v jq &>/dev/null; then
  MFA_OPTIONS=$(echo "${USER_JSON}" | jq -r \
    '[.MFAOptions[]? | .DeliveryMedium] | if length > 0 then join(", ") else "none" end' \
    2>/dev/null || echo "none")
else
  MFA_OPTIONS=$(node -e "
    try {
      const u = JSON.parse(process.argv[1]);
      const opts = (u.MFAOptions || []).map(x => x.DeliveryMedium).filter(Boolean);
      process.stdout.write(opts.length ? opts.join(', ') : 'none');
    } catch(e) { process.stdout.write('none'); }
  " "${USER_JSON}" 2>/dev/null || echo "none")
fi

# ---------------------------------------------------------------------------
# Display user details
# ---------------------------------------------------------------------------

echo ""
echo "  Email:    ${EMAIL}"
echo "  Name:     ${FULL_NAME:-<not set>}"
echo "  Status:   ${USER_STATUS}"
echo "  Created:  ${USER_CREATED}"
echo "  Modified: ${USER_MODIFIED}"
echo "  Enabled:  ${USER_ENABLED}"
echo "  MFA:      ${MFA_OPTIONS}"
echo ""

# ---------------------------------------------------------------------------
# Dry run — show details and planned action, then exit
# ---------------------------------------------------------------------------

if [[ "${DRY_RUN}" == true ]]; then
  if [[ "${DISABLE}" == true ]]; then
    echo "[dry-run] Would DISABLE user '${EMAIL}'. No changes made."
  else
    echo "[dry-run] Would PERMANENTLY DELETE user '${EMAIL}'. No changes made."
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# Confirmation prompt
# ---------------------------------------------------------------------------

if [[ "${DISABLE}" == true ]]; then
  confirm_or_abort "Disable user '${EMAIL}'? [y/N] "
else
  confirm_or_abort "Permanently DELETE user '${EMAIL}'? This cannot be undone. [y/N] "
fi

echo ""

# ---------------------------------------------------------------------------
# Execute action
# ---------------------------------------------------------------------------

if [[ "${DISABLE}" == true ]]; then
  echo "Disabling user '${EMAIL}'..."
  aws cognito-idp admin-disable-user \
    --user-pool-id "${USER_POOL_ID}" \
    --username "${EMAIL}" \
    --region "${REGION}" \
    "${PROFILE_ARGS[@]}"
  echo ""
  echo "Done. User '${EMAIL}' has been disabled and can no longer log in."
  echo "To re-enable the account:"
  echo "  aws cognito-idp admin-enable-user --user-pool-id ${USER_POOL_ID} --username ${EMAIL}"
else
  echo "Deleting user '${EMAIL}'..."
  aws cognito-idp admin-delete-user \
    --user-pool-id "${USER_POOL_ID}" \
    --username "${EMAIL}" \
    --region "${REGION}" \
    "${PROFILE_ARGS[@]}"
  echo ""
  echo "Done. User '${EMAIL}' has been permanently deleted."
fi
