#!/usr/bin/env bash
# upload-content.sh
#
# Syncs a local content folder to the applicant portal S3 bucket and creates
# a CloudFront cache invalidation so changes are served immediately.
# Run with --help for full usage.

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
DEFAULT_REGION="us-east-1"
DEFAULT_CONTENT_DIR="./content"

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

usage() {
  cat <<EOF
Usage:
  ${SCRIPT_NAME} [--content <dir>] [options]

Syncs a local content folder to the portal S3 bucket and creates a CloudFront
invalidation so changes are live within ~60 seconds.

Options:
  -d, --content <dir>    Local content directory (default: ${DEFAULT_CONTENT_DIR})
  -c, --company <name>   Company name — auto-detected from cdk.json, or discovered
                         from deployed CloudFormation stacks if omitted
  -p, --profile <name>   AWS CLI profile to use
  -r, --region <region>  AWS region (default: ${DEFAULT_REGION})
      --no-delete        Do not remove files from S3 that are absent locally
      --wait             Wait for the CloudFront invalidation to complete (~30–60s)
  -y, --yes              Skip confirmation prompt (useful in CI / automation)
      --dry-run          Show what would be synced without uploading anything
  -h, --help             Show this help message

Notes:
  By default, files present in S3 but absent from the local content directory
  are deleted from the bucket (mirrors standard content deployment). Use
  --no-delete to preserve existing S3 files not in the local directory.

  The content directory must contain at minimum index.html and error.html.

Examples:
  # Sync ./content, company auto-detected from cdk.json
  ${SCRIPT_NAME}

  # Explicit content directory and company
  ${SCRIPT_NAME} --content ./my-content --company acme

  # With an AWS profile, wait for the invalidation to complete
  ${SCRIPT_NAME} --company acme --profile my-aws-profile --wait

  # Preview what would change without uploading anything
  ${SCRIPT_NAME} --dry-run
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

CONTENT_DIR="${CONTENT_DIR:-${DEFAULT_CONTENT_DIR}}"
COMPANY_NAME="${COMPANY_NAME:-}"
AWS_PROFILE="${AWS_PROFILE:-}"
REGION="${AWS_REGION:-${DEFAULT_REGION}}"
NO_DELETE=false
WAIT=false
YES=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--content)  CONTENT_DIR="$2";  shift 2 ;;
    -c|--company)  COMPANY_NAME="$2"; shift 2 ;;
    -p|--profile)  AWS_PROFILE="$2";  shift 2 ;;
    -r|--region)   REGION="$2";       shift 2 ;;
    --no-delete)   NO_DELETE=true;     shift   ;;
    --wait)        WAIT=true;          shift   ;;
    -y|--yes)      YES=true;           shift   ;;
    --dry-run)     DRY_RUN=true;       shift   ;;
    -h|--help)     usage; exit 0       ;;
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
# Helpers — mirrors invite-user.sh; both mirror lib/config/portal-config.ts
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

# Query CloudFormation for deployed ApplicantPortal-* stacks and return the single
# matching stack name. Errors to stderr and returns non-zero if zero or multiple
# stacks are found (requiring the user to be explicit with --company).
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

# Normalize if a name was found; if still empty, defer to CloudFormation discovery
# after credentials are verified (see "Resolve stack name" below).
if [[ -n "${COMPANY_NAME}" ]]; then
  COMPANY_NAME="$(normalize_company_name "${COMPANY_NAME}")"
  if [[ -z "${COMPANY_NAME}" ]]; then
    echo "ERROR: --company could not be normalized to a valid slug." >&2
    echo "       Ensure the name contains at least one letter or digit." >&2
    exit 1
  fi
fi

# Validate content directory and required files
if [[ ! -d "${CONTENT_DIR}" ]]; then
  echo "ERROR: Content directory '${CONTENT_DIR}' does not exist." >&2
  echo "       Pass a different path with --content <dir>." >&2
  exit 1
fi

if [[ ! -f "${CONTENT_DIR}/index.html" ]]; then
  echo "ERROR: '${CONTENT_DIR}/index.html' is missing." >&2
  echo "       The portal requires index.html as the CloudFront default root object." >&2
  exit 1
fi

if [[ ! -f "${CONTENT_DIR}/error.html" ]]; then
  echo "ERROR: '${CONTENT_DIR}/error.html' is missing." >&2
  echo "       The portal's CloudFront error responses (403, 404) point to /error.html." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# AWS CLI check and credentials verification
# ---------------------------------------------------------------------------

if ! command -v aws &>/dev/null; then
  echo "ERROR: AWS CLI not found. Install from https://aws.amazon.com/cli/" >&2
  exit 1
fi

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
# Resolve stack name — from --company / cdk.json, or by discovering deployed stacks
# ---------------------------------------------------------------------------

if [[ -z "${COMPANY_NAME}" ]]; then
  echo "No company name provided, searching for deployed portal stacks in ${REGION}..."
  STACK_NAME="$(discover_portal_stack)"
  COMPANY_NAME="${STACK_NAME#ApplicantPortal-}"
  echo "Found: ${STACK_NAME}"
else
  STACK_NAME="ApplicantPortal-${COMPANY_NAME}"
fi

echo ""
echo "Stack:   ${STACK_NAME}"
echo "Account: ${ACCOUNT_ID}"
echo "Region:  ${REGION}"
echo ""

# ---------------------------------------------------------------------------
# Resolve S3 bucket and CloudFront distribution ID from CloudFormation outputs
# ---------------------------------------------------------------------------

echo "Fetching stack outputs from CloudFormation..."
if ! STACK_DESCRIBE=$(aws cloudformation describe-stacks \
    --stack-name "${STACK_NAME}" \
    --region "${REGION}" \
    "${PROFILE_ARGS[@]}" 2>&1); then
  if echo "${STACK_DESCRIBE}" | grep -q "does not exist"; then
    echo "ERROR: Stack '${STACK_NAME}' not found in ${REGION}." >&2
    discovered="$(discover_portal_stack 2>/dev/null || true)"
    if [[ -n "${discovered}" ]]; then
      echo "       Found a deployed portal stack: ${discovered}" >&2
      echo "       Try: --company ${discovered#ApplicantPortal-}" >&2
    else
      echo "       Check --company and --region, and verify the stack has been deployed." >&2
    fi
  else
    echo "ERROR: Could not describe stack '${STACK_NAME}':" >&2
    echo "       ${STACK_DESCRIBE}" >&2
  fi
  exit 1
fi

BUCKET=$(aws cloudformation describe-stacks \
  --stack-name "${STACK_NAME}" \
  --region "${REGION}" \
  "${PROFILE_ARGS[@]}" \
  --query "Stacks[0].Outputs[?ExportName=='${STACK_NAME}-ContentBucketName'].OutputValue" \
  --output text)

DIST_ID=$(aws cloudformation describe-stacks \
  --stack-name "${STACK_NAME}" \
  --region "${REGION}" \
  "${PROFILE_ARGS[@]}" \
  --query "Stacks[0].Outputs[?ExportName=='${STACK_NAME}-DistributionId'].OutputValue" \
  --output text)

if [[ -z "${BUCKET}" || "${BUCKET}" == "None" ]]; then
  echo "ERROR: ContentBucketName output not found in stack '${STACK_NAME}'." >&2
  echo "       The stack may be incomplete or still deploying." >&2
  exit 1
fi

if [[ -z "${DIST_ID}" || "${DIST_ID}" == "None" ]]; then
  echo "ERROR: DistributionId output not found in stack '${STACK_NAME}'." >&2
  echo "       The stack may be incomplete or still deploying." >&2
  exit 1
fi

echo "Bucket:       s3://${BUCKET}"
echo "Distribution: ${DIST_ID}"

# ---------------------------------------------------------------------------
# Summary and confirmation
# ---------------------------------------------------------------------------

if [[ "${NO_DELETE}" == true ]]; then
  DELETE_NOTE="Existing S3 files not in the local directory will be preserved (--no-delete)."
else
  DELETE_NOTE="Files absent locally will be DELETED from S3. Pass --no-delete to skip."
fi

echo ""
echo "  Content:      ${CONTENT_DIR}"
echo "  Destination:  s3://${BUCKET}/"
echo "  Invalidation: /* (all paths, all CloudFront edge locations)"
echo "  Sync mode:    ${DELETE_NOTE}"
echo ""

# ---------------------------------------------------------------------------
# Dry run — show what would sync but make no changes
# ---------------------------------------------------------------------------

if [[ "${DRY_RUN}" == true ]]; then
  echo "Dry-run: files that would be synced (no changes will be made)..."
  echo ""

  SYNC_ARGS=(
    s3 sync "${CONTENT_DIR}" "s3://${BUCKET}/"
    --dryrun
    --region "${REGION}"
    --cache-control "no-cache, no-store, must-revalidate"
  )
  [[ "${NO_DELETE}" == false ]] && SYNC_ARGS+=(--delete)
  [[ ${#PROFILE_ARGS[@]} -gt 0 ]] && SYNC_ARGS+=("${PROFILE_ARGS[@]}")
  aws "${SYNC_ARGS[@]}"

  echo ""
  echo "[dry-run] Would create CloudFront invalidation for distribution ${DIST_ID} at path /*"
  echo "[dry-run] No changes made."
  exit 0
fi

# ---------------------------------------------------------------------------
# Confirmation prompt
# ---------------------------------------------------------------------------

if [[ "${YES}" == false ]]; then
  read -r -p "Proceed? [y/N] " _confirm
  if [[ ! "${_confirm}" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
  fi
fi

echo ""

# ---------------------------------------------------------------------------
# Sync to S3
# ---------------------------------------------------------------------------

echo "Syncing content to s3://${BUCKET}/..."

SYNC_ARGS=(
  s3 sync "${CONTENT_DIR}" "s3://${BUCKET}/"
  --region "${REGION}"
  --cache-control "no-cache, no-store, must-revalidate"
)
[[ "${NO_DELETE}" == false ]] && SYNC_ARGS+=(--delete)
[[ ${#PROFILE_ARGS[@]} -gt 0 ]] && SYNC_ARGS+=("${PROFILE_ARGS[@]}")
aws "${SYNC_ARGS[@]}"

# ---------------------------------------------------------------------------
# CloudFront invalidation
# ---------------------------------------------------------------------------

echo ""
echo "Creating CloudFront invalidation..."
INVALIDATION_ID=$(aws cloudfront create-invalidation \
  --distribution-id "${DIST_ID}" \
  --paths "/*" \
  --query "Invalidation.Id" \
  --output text \
  "${PROFILE_ARGS[@]}")

echo "Invalidation ID: ${INVALIDATION_ID}"

if [[ "${WAIT}" == true ]]; then
  echo "Waiting for invalidation to complete (typically 30–60 seconds)..."
  aws cloudfront wait invalidation-completed \
    --distribution-id "${DIST_ID}" \
    --id "${INVALIDATION_ID}" \
    "${PROFILE_ARGS[@]}"
  echo ""
  echo "Done. Invalidation complete — changes are now live at all edge locations."
else
  echo ""
  echo "Done. Changes will be live within ~60 seconds as the invalidation propagates."
  echo "Check invalidation status with:"
  echo "  aws cloudfront get-invalidation --distribution-id ${DIST_ID} --id ${INVALIDATION_ID}"
fi
