#!/usr/bin/env bash
# upload-content.sh
#
# Syncs a local content folder to the applicant portal S3 bucket and creates
# a CloudFront cache invalidation so changes are served immediately.
# Run with --help for full usage.

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_REGION="us-east-1"
DEFAULT_CONTENT_DIR="./content"

source "${SCRIPT_DIR}/lib/portal-common.sh"

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
  -c, --company <name>   Company name — auto-discovered from deployed CloudFormation
                         stacks, or detected from cdk.json if omitted
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
    -d|--content)  require_arg "$1" "${2:-}" $#; CONTENT_DIR="$2";  shift 2 ;;
    -c|--company)  require_arg "$1" "${2:-}" $#; COMPANY_NAME="$2"; shift 2 ;;
    -p|--profile)  require_arg "$1" "${2:-}" $#; AWS_PROFILE="$2";  shift 2 ;;
    -r|--region)   require_arg "$1" "${2:-}" $#; REGION="$2";       shift 2 ;;
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
# Validation
# ---------------------------------------------------------------------------

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
# AWS CLI check, credentials, and stack resolution
# ---------------------------------------------------------------------------

ensure_dependencies
build_profile_args
verify_aws_credentials
resolve_portal_stack

echo "Fetching stack outputs from CloudFormation..."
prefetch_stack_outputs
print_stack_info
BUCKET="$(get_stack_output "ContentBucketName")"
DIST_ID="$(get_stack_output "DistributionId")"

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

confirm_or_abort

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
