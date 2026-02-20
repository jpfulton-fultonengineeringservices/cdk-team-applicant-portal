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
#   PROFILE_ARGS       Bash array — set by build_profile_args
#   ACCOUNT_ID         AWS account ID — set by verify_aws_credentials
#   COMPANY_NAME       Normalized slug — potentially updated by resolve_portal_stack
#   STACK_NAME         Full stack name — set by resolve_portal_stack
#   DISCOVERED_STACKS  Array of stack names — set by discover_portal_stacks

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
# discover_portal_stacks
#
# Queries CloudFormation for deployed ApplicantPortal-* stacks. Populates the
# global DISCOVERED_STACKS array with matching stack names.
#
# Returns 0 if at least one stack was found, 1 otherwise.
# Never prints errors — callers decide how to handle zero/multi results.
#
# Reads globals: REGION, PROFILE_ARGS
# Sets globals:  DISCOVERED_STACKS
# ---------------------------------------------------------------------------
discover_portal_stacks() {
  DISCOVERED_STACKS=()
  local raw
  raw=$(aws cloudformation list-stacks \
    --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE \
    --region "${REGION}" \
    "${PROFILE_ARGS[@]}" \
    --query "StackSummaries[?starts_with(StackName, 'ApplicantPortal-')].StackName" \
    --output text 2>/dev/null || true)

  while IFS=$'\t\n' read -r line; do
    [[ -n "${line}" ]] && DISCOVERED_STACKS+=("${line}")
  done <<< "${raw}"

  [[ ${#DISCOVERED_STACKS[@]} -gt 0 ]]
}

# ---------------------------------------------------------------------------
# _get_portal_url_for_stack <stack-name>
#
# Fetches the PortalUrl output for a given stack. Prints the URL or an empty
# string if the output is not found. Non-fatal — used for display only.
#
# Reads globals: REGION, PROFILE_ARGS
# ---------------------------------------------------------------------------
_get_portal_url_for_stack() {
  local sname="$1"
  local url
  url=$(aws cloudformation describe-stacks \
    --stack-name "${sname}" \
    --region "${REGION}" \
    "${PROFILE_ARGS[@]}" \
    --query "Stacks[0].Outputs[?ExportName=='${sname}-PortalUrl'].OutputValue" \
    --output text 2>/dev/null || true)
  if [[ "${url}" == "None" ]]; then
    url=""
  fi
  echo "${url}"
}

# ---------------------------------------------------------------------------
# select_stack_interactive
#
# Presents a numbered menu when DISCOVERED_STACKS has 2+ entries. Reads the
# user's selection and sets STACK_NAME and COMPANY_NAME accordingly.
#
# For each stack, fetches the PortalUrl output to provide context.
#
# Reads globals: DISCOVERED_STACKS, REGION, PROFILE_ARGS
# Sets globals:  STACK_NAME, COMPANY_NAME
# ---------------------------------------------------------------------------
select_stack_interactive() {
  local count=${#DISCOVERED_STACKS[@]}

  # Non-interactive stdin cannot drive a menu — fail fast with guidance.
  if [[ ! -t 0 ]]; then
    echo "ERROR: Multiple ApplicantPortal stacks found, but stdin is not a terminal." >&2
    echo "       Specify one with --company:" >&2
    for s in "${DISCOVERED_STACKS[@]}"; do
      echo "         --company ${s#ApplicantPortal-}" >&2
    done
    exit 1
  fi

  echo "" >&2
  echo "Multiple ApplicantPortal stacks found in ${REGION}:" >&2
  echo "" >&2

  local i=0
  while [[ ${i} -lt ${count} ]]; do
    local sname="${DISCOVERED_STACKS[${i}]}"
    local url
    url="$(_get_portal_url_for_stack "${sname}")"
    local display_num=$((i + 1))
    if [[ -n "${url}" ]]; then
      printf '  %d) %s  (%s)\n' "${display_num}" "${sname}" "${url}" >&2
    else
      printf '  %d) %s\n' "${display_num}" "${sname}" >&2
    fi
    i=$((i + 1))
  done

  echo "" >&2

  local selection=""
  while true; do
    if ! read -r -p "Select stack [1-${count}]: " selection; then
      echo "" >&2
      echo "ERROR: Unexpected end of input. Specify a stack with --company." >&2
      exit 1
    fi
    case "${selection}" in
      ''|*[!0-9]*)
        echo "Please enter a number between 1 and ${count}." >&2
        continue
        ;;
    esac
    if [[ "${selection}" -ge 1 && "${selection}" -le "${count}" ]]; then
      break
    fi
    echo "Please enter a number between 1 and ${count}." >&2
  done

  local idx=$((selection - 1))
  STACK_NAME="${DISCOVERED_STACKS[${idx}]}"
  COMPANY_NAME="${STACK_NAME#ApplicantPortal-}"
}

# ---------------------------------------------------------------------------
# resolve_portal_stack
#
# Unified stack resolution — CloudFormation first, cdk.json fallback.
#
# Strategy:
#   1. If COMPANY_NAME is set (via --company), normalize it, derive STACK_NAME.
#   2. Otherwise, query CloudFormation for ApplicantPortal-* stacks:
#      a. Exactly 1 stack → auto-select.
#      b. 2+ stacks → interactive menu (or error if YES=true / CI mode).
#      c. 0 stacks or AWS error → fall through to step 3.
#   3. Fallback: detect company from cdk.json, normalize, derive STACK_NAME.
#   4. Still nothing → clear error with guidance.
#
# Reads globals:  COMPANY_NAME, REGION, PROFILE_ARGS, YES
# Sets globals:   COMPANY_NAME (normalized), STACK_NAME
# ---------------------------------------------------------------------------
resolve_portal_stack() {
  # --- Path 1: explicit --company flag ---
  if [[ -n "${COMPANY_NAME}" ]]; then
    COMPANY_NAME="$(normalize_company_name "${COMPANY_NAME}")"
    if [[ -z "${COMPANY_NAME}" ]]; then
      echo "ERROR: --company could not be normalized to a valid slug." >&2
      echo "       Ensure the name contains at least one letter or digit." >&2
      exit 1
    fi
    STACK_NAME="ApplicantPortal-${COMPANY_NAME}"
    return 0
  fi

  # --- Path 2: discover from CloudFormation ---
  echo "Searching for deployed ApplicantPortal stacks in ${REGION}..." >&2
  if discover_portal_stacks; then
    local count=${#DISCOVERED_STACKS[@]}

    if [[ ${count} -eq 1 ]]; then
      STACK_NAME="${DISCOVERED_STACKS[0]}"
      COMPANY_NAME="${STACK_NAME#ApplicantPortal-}"
      echo "Found: ${STACK_NAME}" >&2
      return 0
    fi

    # 2+ stacks
    if [[ "${YES}" == "true" ]]; then
      echo "ERROR: Multiple ApplicantPortal stacks found. Specify one with --company:" >&2
      for s in "${DISCOVERED_STACKS[@]}"; do
        echo "         --company ${s#ApplicantPortal-}" >&2
      done
      exit 1
    fi

    select_stack_interactive
    return 0
  fi

  # --- Path 3: fallback to cdk.json ---
  echo "No deployed stacks found via CloudFormation. Checking cdk.json..." >&2
  local detected
  detected="$(detect_company_from_cdk_json || true)"
  if [[ -n "${detected}" ]]; then
    echo "Auto-detected company from cdk.json: ${detected}" >&2
    COMPANY_NAME="$(normalize_company_name "${detected}")"
    if [[ -z "${COMPANY_NAME}" ]]; then
      echo "ERROR: Company name from cdk.json could not be normalized to a valid slug." >&2
      exit 1
    fi
    STACK_NAME="ApplicantPortal-${COMPANY_NAME}"
    return 0
  fi

  # --- Nothing found ---
  echo "ERROR: Could not determine which ApplicantPortal stack to use." >&2
  echo "" >&2
  echo "       No deployed ApplicantPortal-* stacks were found in ${REGION}," >&2
  echo "       and no companyName was found in cdk.json." >&2
  echo "" >&2
  echo "       Options:" >&2
  echo "         --company <name>   Specify the company name explicitly" >&2
  echo "         --region <region>  Try a different AWS region" >&2
  echo "         --profile <name>   Try a different AWS profile/account" >&2
  exit 1
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
  echo "Verifying AWS credentials..." >&2
  local identity
  if ! identity=$(aws sts get-caller-identity --region "${REGION}" "${PROFILE_ARGS[@]}" 2>&1); then
    echo "ERROR: AWS credentials check failed. Is your profile/environment configured?" >&2
    echo "       ${identity}" >&2
    exit 1
  fi
  ACCOUNT_ID=$(echo "${identity}" | grep -o '"Account": "[^"]*"' | cut -d'"' -f4)
}

# ---------------------------------------------------------------------------
# print_stack_info
#
# Prints the Stack / Account / Region / Portal summary block. Fetches the
# PortalUrl stack output for display; gracefully skips if absent.
#
# Reads globals: STACK_NAME, ACCOUNT_ID, REGION, PROFILE_ARGS
# ---------------------------------------------------------------------------
print_stack_info() {
  echo "" >&2
  echo "Stack:   ${STACK_NAME}" >&2
  echo "Account: ${ACCOUNT_ID}" >&2
  echo "Region:  ${REGION}" >&2
  local portal_url
  portal_url="$(_get_portal_url_for_stack "${STACK_NAME}")"
  if [[ -n "${portal_url}" ]]; then
    echo "Portal:  ${portal_url}" >&2
  fi
  echo "" >&2
}

# ---------------------------------------------------------------------------
# _describe_stack_cached
#
# Calls describe-stacks for STACK_NAME, caching the raw JSON response in
# _STACK_DESCRIBE_CACHE. Subsequent calls for the same STACK_NAME return the
# cached value. Returns the describe-stacks exit code; on failure the cache
# holds the error text.
#
# Reads globals: STACK_NAME, REGION, PROFILE_ARGS
# Sets globals:  _STACK_DESCRIBE_CACHE, _STACK_DESCRIBE_CACHE_NAME
# ---------------------------------------------------------------------------
_STACK_DESCRIBE_CACHE=""
_STACK_DESCRIBE_CACHE_NAME=""
_STACK_DESCRIBE_CACHE_RC=0

_describe_stack_cached() {
  if [[ "${_STACK_DESCRIBE_CACHE_NAME}" == "${STACK_NAME}" ]]; then
    return ${_STACK_DESCRIBE_CACHE_RC}
  fi
  _STACK_DESCRIBE_CACHE_NAME="${STACK_NAME}"
  if _STACK_DESCRIBE_CACHE=$(aws cloudformation describe-stacks \
      --stack-name "${STACK_NAME}" \
      --region "${REGION}" \
      "${PROFILE_ARGS[@]}" 2>&1); then
    _STACK_DESCRIBE_CACHE_RC=0
  else
    _STACK_DESCRIBE_CACHE_RC=1
  fi
  return ${_STACK_DESCRIBE_CACHE_RC}
}

# ---------------------------------------------------------------------------
# get_stack_output <export-suffix>
#
# Resolves a CloudFormation output exported as "${STACK_NAME}-<suffix>".
# Prints the output value on success. Exits with a helpful error message if
# the stack does not exist or the output is missing.
#
# Uses _describe_stack_cached to avoid redundant API calls when multiple
# outputs are fetched from the same stack.
#
# Reads globals: STACK_NAME, REGION, PROFILE_ARGS
# ---------------------------------------------------------------------------
get_stack_output() {
  local suffix="$1"
  local export_name="${STACK_NAME}-${suffix}"

  if ! _describe_stack_cached; then
    if echo "${_STACK_DESCRIBE_CACHE}" | grep -q "does not exist"; then
      echo "ERROR: Stack '${STACK_NAME}' not found in ${REGION}." >&2
      if discover_portal_stacks && [[ ${#DISCOVERED_STACKS[@]} -gt 0 ]]; then
        echo "       Found deployed portal stack(s):" >&2
        for s in "${DISCOVERED_STACKS[@]}"; do
          echo "         --company ${s#ApplicantPortal-}" >&2
        done
      else
        echo "       Check --company and --region, and verify the stack has been deployed." >&2
      fi
    else
      echo "ERROR: Could not describe stack '${STACK_NAME}':" >&2
      echo "       ${_STACK_DESCRIBE_CACHE}" >&2
    fi
    exit 1
  fi

  local value
  if command -v jq &>/dev/null; then
    value=$(echo "${_STACK_DESCRIBE_CACHE}" \
      | jq -r --arg en "${export_name}" \
          '.Stacks[0].Outputs[] | select(.ExportName == $en) | .OutputValue // ""' \
          2>/dev/null || true)
  else
    value=$(aws cloudformation describe-stacks \
      --stack-name "${STACK_NAME}" \
      --region "${REGION}" \
      "${PROFILE_ARGS[@]}" \
      --query "Stacks[0].Outputs[?ExportName=='${export_name}'].OutputValue" \
      --output text)
  fi

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
