# portal-common.sh
#
# Shared helpers for ApplicantPortal management scripts.
# Source this file; do not execute it directly.
#
# CALLER CONTRACT — set these before calling library functions:
#   REGION       AWS region (e.g. us-east-1)
#   AWS_PROFILE  AWS CLI profile name, or empty string
#   COMPANY_NAME Company slug, or empty string (auto-detect will run)
#   YES          "true" to skip confirmation prompts, otherwise "false"
#
# GLOBALS SET BY THIS LIBRARY:
#   PROFILE_ARGS  Bash array — set by build_profile_args
#   ACCOUNT_ID    AWS account ID — set by verify_aws_credentials
#   COMPANY_NAME  Normalized slug — potentially updated by resolve_company_name
#   STACK_NAME    Full stack name — set by resolve_stack_name

# ---------------------------------------------------------------------------
# normalize_company_name <raw>
#
# Mirrors normalizeCompanyName() in lib/config/portal-config.ts so the
# derived stack name always matches what CDK created.
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# detect_company_from_cdk_json
#
# Walks up the directory tree looking for cdk.json and extracts companyName
# from the context block. Prints the raw value and returns 0 on success,
# returns 1 if not found or no companyName is set.
# ---------------------------------------------------------------------------
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
# discover_portal_stack
#
# Queries CloudFormation for deployed ApplicantPortal-* stacks and prints the
# single matching stack name. Writes errors to stderr and returns non-zero if
# zero or multiple stacks are found (requiring the user to pass --company).
#
# Reads globals: REGION, PROFILE_ARGS
# ---------------------------------------------------------------------------
discover_portal_stack() {
  local raw
  raw=$(aws cloudformation list-stacks \
    --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE \
    --region "${REGION}" \
    "${PROFILE_ARGS[@]}" \
    --query "StackSummaries[?starts_with(StackName, 'ApplicantPortal-')].StackName" \
    --output text 2>/dev/null || true)

  local stacks=()
  while IFS=$'\t\n' read -r line; do
    [[ -n "${line}" ]] && stacks+=("${line}")
  done <<< "${raw}"

  if [[ ${#stacks[@]} -eq 0 ]]; then
    echo "ERROR: No deployed ApplicantPortal-* stacks found in ${REGION}." >&2
    echo "       Has the stack been deployed? See the deployment guide." >&2
    return 1
  fi

  if [[ ${#stacks[@]} -gt 1 ]]; then
    echo "ERROR: Multiple ApplicantPortal-* stacks found in ${REGION}. Specify one with --company:" >&2
    for s in "${stacks[@]}"; do
      echo "         --company ${s#ApplicantPortal-}" >&2
    done
    return 1
  fi

  echo "${stacks[0]}"
}

# ---------------------------------------------------------------------------
# require_aws_cli
#
# Exits with an error if the AWS CLI is not on PATH.
# ---------------------------------------------------------------------------
require_aws_cli() {
  if ! command -v aws &>/dev/null; then
    echo "ERROR: AWS CLI not found. Install from https://aws.amazon.com/cli/" >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# build_profile_args
#
# Sets global PROFILE_ARGS array from AWS_PROFILE. Avoids word-splitting
# issues when AWS_PROFILE is empty.
# ---------------------------------------------------------------------------
build_profile_args() {
  PROFILE_ARGS=()
  [[ -n "${AWS_PROFILE}" ]] && PROFILE_ARGS=(--profile "${AWS_PROFILE}")
}

# ---------------------------------------------------------------------------
# verify_aws_credentials
#
# Runs sts get-caller-identity to confirm credentials are valid. Sets global
# ACCOUNT_ID. Exits with a clear error on failure.
#
# Reads globals: REGION, PROFILE_ARGS
# Sets globals:  ACCOUNT_ID
# ---------------------------------------------------------------------------
verify_aws_credentials() {
  echo "Verifying AWS credentials..."
  local identity
  if ! identity=$(aws sts get-caller-identity --region "${REGION}" "${PROFILE_ARGS[@]}" 2>&1); then
    echo "ERROR: AWS credentials check failed. Is your profile/environment configured?" >&2
    echo "       ${identity}" >&2
    exit 1
  fi
  ACCOUNT_ID=$(echo "${identity}" | grep -o '"Account": "[^"]*"' | cut -d'"' -f4)
}

# ---------------------------------------------------------------------------
# resolve_company_name
#
# If COMPANY_NAME is empty, attempts auto-detection from cdk.json. Normalizes
# the result. Leaves COMPANY_NAME empty if neither source provides a value
# (stack discovery will run later in resolve_stack_name).
#
# Reads globals:  COMPANY_NAME
# Sets globals:   COMPANY_NAME (normalized)
# ---------------------------------------------------------------------------
resolve_company_name() {
  if [[ -z "${COMPANY_NAME}" ]]; then
    local detected
    detected="$(detect_company_from_cdk_json || true)"
    if [[ -n "${detected}" ]]; then
      COMPANY_NAME="${detected}"
      echo "Auto-detected company from cdk.json: ${COMPANY_NAME}"
    fi
  fi

  if [[ -n "${COMPANY_NAME}" ]]; then
    COMPANY_NAME="$(normalize_company_name "${COMPANY_NAME}")"
    if [[ -z "${COMPANY_NAME}" ]]; then
      echo "ERROR: --company could not be normalized to a valid slug." >&2
      echo "       Ensure the name contains at least one letter or digit." >&2
      exit 1
    fi
  fi
}

# ---------------------------------------------------------------------------
# resolve_stack_name
#
# Sets global STACK_NAME. Uses COMPANY_NAME if set; otherwise falls back to
# CloudFormation stack discovery. Also updates COMPANY_NAME from the
# discovered stack name when discovery is used.
#
# Reads globals:  COMPANY_NAME, REGION, PROFILE_ARGS
# Sets globals:   STACK_NAME, COMPANY_NAME
# ---------------------------------------------------------------------------
resolve_stack_name() {
  if [[ -z "${COMPANY_NAME}" ]]; then
    echo "No company name provided, searching for deployed portal stacks in ${REGION}..."
    STACK_NAME="$(discover_portal_stack)"
    COMPANY_NAME="${STACK_NAME#ApplicantPortal-}"
    echo "Found: ${STACK_NAME}"
  else
    STACK_NAME="ApplicantPortal-${COMPANY_NAME}"
  fi
}

# ---------------------------------------------------------------------------
# print_stack_info
#
# Prints the Stack / Account / Region summary block.
#
# Reads globals: STACK_NAME, ACCOUNT_ID, REGION
# ---------------------------------------------------------------------------
print_stack_info() {
  echo ""
  echo "Stack:   ${STACK_NAME}"
  echo "Account: ${ACCOUNT_ID}"
  echo "Region:  ${REGION}"
  echo ""
}

# ---------------------------------------------------------------------------
# get_stack_output <export-suffix>
#
# Resolves a CloudFormation output exported as "${STACK_NAME}-<suffix>".
# Prints the output value on success. Exits with a helpful error message if
# the stack does not exist or the output is missing.
#
# Reads globals: STACK_NAME, REGION, PROFILE_ARGS
# ---------------------------------------------------------------------------
get_stack_output() {
  local suffix="$1"
  local export_name="${STACK_NAME}-${suffix}"

  local describe
  if ! describe=$(aws cloudformation describe-stacks \
      --stack-name "${STACK_NAME}" \
      --region "${REGION}" \
      "${PROFILE_ARGS[@]}" 2>&1); then
    if echo "${describe}" | grep -q "does not exist"; then
      echo "ERROR: Stack '${STACK_NAME}' not found in ${REGION}." >&2
      local discovered
      discovered="$(discover_portal_stack 2>/dev/null || true)"
      if [[ -n "${discovered}" ]]; then
        echo "       Found a deployed portal stack: ${discovered}" >&2
        echo "       Try: --company ${discovered#ApplicantPortal-}" >&2
      else
        echo "       Check --company and --region, and verify the stack has been deployed." >&2
      fi
    else
      echo "ERROR: Could not describe stack '${STACK_NAME}':" >&2
      echo "       ${describe}" >&2
    fi
    exit 1
  fi

  local value
  value=$(aws cloudformation describe-stacks \
    --stack-name "${STACK_NAME}" \
    --region "${REGION}" \
    "${PROFILE_ARGS[@]}" \
    --query "Stacks[0].Outputs[?ExportName=='${export_name}'].OutputValue" \
    --output text)

  if [[ -z "${value}" || "${value}" == "None" ]]; then
    echo "ERROR: Output '${export_name}' not found in stack '${STACK_NAME}'." >&2
    echo "       The stack may be incomplete or still deploying." >&2
    exit 1
  fi

  echo "${value}"
}

# ---------------------------------------------------------------------------
# validate_email <email>
#
# Validates that the argument looks like an email address. Exits with an
# error message if it does not.
# ---------------------------------------------------------------------------
validate_email() {
  local email="$1"
  if ! echo "${email}" | grep -qE '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'; then
    echo "ERROR: '${email}' does not look like a valid email address." >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# confirm_or_abort [prompt]
#
# Prints an optional prompt and reads a [y/N] response. Exits (abort) if the
# user does not confirm. Skipped entirely when YES=true.
#
# Reads globals: YES
# ---------------------------------------------------------------------------
confirm_or_abort() {
  local prompt="${1:-Proceed? [y/N] }"
  if [[ "${YES}" == "true" ]]; then
    return 0
  fi
  local _confirm
  read -r -p "${prompt}" _confirm
  if [[ ! "${_confirm}" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
  fi
}
