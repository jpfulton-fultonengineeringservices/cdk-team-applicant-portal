#!/usr/bin/env bash
# list-users.sh
#
# Lists applicant accounts in the Cognito User Pool with filtering and
# multiple output formats. Run with --help for full usage.

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
  ${SCRIPT_NAME} [options]

List applicant accounts in the Cognito User Pool. Supports filtering,
multiple output formats, and composable quiet output for piping.

Options:
  -c, --company <name>          Company name — auto-discovered from deployed CloudFormation
                                stacks, or detected from cdk.json if omitted
  -p, --profile <name>          AWS CLI profile to use
  -r, --region <region>         AWS region (default: ${DEFAULT_REGION})
      --format <fmt>            Output format: table (default), csv, json, quiet
      --status <status>         Filter by Cognito user status:
                                  CONFIRMED, UNCONFIRMED, FORCE_CHANGE_PASSWORD,
                                  RESET_REQUIRED, ARCHIVED, COMPROMISED, UNKNOWN
      --email <prefix>          Filter users whose email starts with <prefix>
      --limit <n>               Show at most N users
      --count                   Print only the total user count
      --dry-run                 Validate inputs and resolve the User Pool without listing
  -h, --help                    Show this help message

Output formats:
  table   Human-readable aligned columns: Email, Name, Status, Created, Enabled
  csv     CSV with header row
  json    Raw AWS JSON array (all pages merged); useful for further processing
  quiet   One email address per line; ideal for piping to remove-user.sh

Examples:
  # List all users (company auto-detected from cdk.json)
  ${SCRIPT_NAME}

  # List only users with expired invitations
  ${SCRIPT_NAME} --status FORCE_CHANGE_PASSWORD

  # Find users matching an email prefix
  ${SCRIPT_NAME} --email jane@

  # Count confirmed users
  ${SCRIPT_NAME} --status CONFIRMED --count

  # Pipe expired-invite emails to remove-user.sh
  ${SCRIPT_NAME} --status FORCE_CHANGE_PASSWORD --format quiet \\
    | xargs -I {} ./scripts/remove-user.sh --email {} --company acme --yes

  # Export full user list as CSV
  ${SCRIPT_NAME} --format csv > users.csv

  # Export raw JSON for scripting
  ${SCRIPT_NAME} --format json --company acme --profile my-aws-profile
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

COMPANY_NAME="${COMPANY_NAME:-}"
AWS_PROFILE="${AWS_PROFILE:-}"
REGION="${AWS_REGION:-${DEFAULT_REGION}}"
FORMAT="table"
FILTER_STATUS=""
FILTER_EMAIL=""
LIMIT=""
COUNT_ONLY=false
YES=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--company) COMPANY_NAME="$2"; shift 2 ;;
    -p|--profile) AWS_PROFILE="$2";  shift 2 ;;
    -r|--region)  REGION="$2";       shift 2 ;;
    --format)     FORMAT="$2";       shift 2 ;;
    --status)     FILTER_STATUS="$2"; shift 2 ;;
    --email)      FILTER_EMAIL="$2"; shift 2 ;;
    --limit)      LIMIT="$2";        shift 2 ;;
    --count)      COUNT_ONLY=true;   shift   ;;
    --dry-run)    DRY_RUN=true;      shift   ;;
    -h|--help)    usage; exit 0      ;;
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
# Validate arguments
# ---------------------------------------------------------------------------

case "${FORMAT}" in
  table|csv|json|quiet) ;;
  *)
    echo "ERROR: Unknown format '${FORMAT}'. Valid values: table, csv, json, quiet." >&2
    exit 1
    ;;
esac

if [[ -n "${FILTER_STATUS}" ]]; then
  case "${FILTER_STATUS}" in
    CONFIRMED|UNCONFIRMED|FORCE_CHANGE_PASSWORD|RESET_REQUIRED|ARCHIVED|COMPROMISED|UNKNOWN) ;;
    *)
      echo "ERROR: Unknown status '${FILTER_STATUS}'." >&2
      echo "       Valid values: CONFIRMED, UNCONFIRMED, FORCE_CHANGE_PASSWORD," >&2
      echo "                     RESET_REQUIRED, ARCHIVED, COMPROMISED, UNKNOWN" >&2
      exit 1
      ;;
  esac
fi

if [[ -n "${LIMIT}" ]]; then
  case "${LIMIT}" in
    ''|*[!0-9]*)
      echo "ERROR: --limit must be a positive integer." >&2
      exit 1
      ;;
  esac
  if [[ "${LIMIT}" -lt 1 ]]; then
    echo "ERROR: --limit must be a positive integer." >&2
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

echo "Fetching User Pool ID from CloudFormation..." >&2
USER_POOL_ID="$(get_stack_output "UserPoolId")"
echo "User Pool: ${USER_POOL_ID}" >&2

# ---------------------------------------------------------------------------
# Dry run — verify everything is reachable but do not list
# ---------------------------------------------------------------------------

if [[ "${DRY_RUN}" == true ]]; then
  echo "[dry-run] All inputs valid. No users listed."
  exit 0
fi

# ---------------------------------------------------------------------------
# Helpers for JSON parsing (jq or node fallback)
# ---------------------------------------------------------------------------

# extract_field_from_user_json <json> <field>
# Extracts a string field from a single Cognito user JSON object. Returns
# empty string if the field is absent. Uses jq when available, node otherwise.
extract_attr() {
  local json="$1"
  local attr_name="$2"
  if command -v jq &>/dev/null; then
    echo "${json}" \
      | jq -r --arg n "${attr_name}" \
          '.Attributes[]? | select(.Name == $n) | .Value // ""' \
          2>/dev/null || true
  else
    node -e "
      try {
        const u = JSON.parse(process.argv[1]);
        const attrs = u.Attributes || u.UserAttributes || [];
        const a = attrs.find(x => x.Name === process.argv[2]);
        process.stdout.write(a ? (a.Value || '') : '');
      } catch(e) {}
    " "${json}" "${attr_name}" 2>/dev/null || true
  fi
}

extract_field() {
  local json="$1"
  local field="$2"
  if command -v jq &>/dev/null; then
    echo "${json}" | jq -r ".${field} // \"\"" 2>/dev/null || true
  else
    node -e "
      try {
        const u = JSON.parse(process.argv[1]);
        const v = u[process.argv[2]];
        process.stdout.write(v !== undefined && v !== null ? String(v) : '');
      } catch(e) {}
    " "${json}" "${field}" 2>/dev/null || true
  fi
}

# merge_json_arrays <file1> <file2> ...
# Reads JSON arrays from stdin lines (one array per line) and merges them.
merge_json_arrays() {
  local combined=""
  while IFS= read -r chunk; do
    [[ -z "${chunk}" ]] && continue
    if [[ -z "${combined}" ]]; then
      combined="${chunk}"
    else
      if command -v jq &>/dev/null; then
        combined=$(printf '%s\n%s' "${combined}" "${chunk}" | jq -s 'add')
      else
        combined=$(node -e "
          const a = JSON.parse(process.argv[1]);
          const b = JSON.parse(process.argv[2]);
          process.stdout.write(JSON.stringify(a.concat(b)));
        " "${combined}" "${chunk}" 2>/dev/null)
      fi
    fi
  done
  echo "${combined:-[]}"
}

# ---------------------------------------------------------------------------
# Pagination: collect all users
# ---------------------------------------------------------------------------

# Cognito supports at most one --filter expression at a time.
# Strategy: if both --email and --status are given, apply the email filter
# server-side (prefix match) and post-filter by status client-side.
# If only one filter is given, apply it server-side.

echo "" >&2

LIST_ARGS=(
  cognito-idp list-users
  --user-pool-id "${USER_POOL_ID}"
  --region "${REGION}"
)
[[ ${#PROFILE_ARGS[@]} -gt 0 ]] && LIST_ARGS+=("${PROFILE_ARGS[@]}")

COGNITO_FILTER=""
POSTFILTER_STATUS=""

if [[ -n "${FILTER_EMAIL}" && -n "${FILTER_STATUS}" ]]; then
  # Email filter server-side; status post-filtered
  COGNITO_FILTER="email ^= \"${FILTER_EMAIL}\""
  POSTFILTER_STATUS="${FILTER_STATUS}"
elif [[ -n "${FILTER_EMAIL}" ]]; then
  COGNITO_FILTER="email ^= \"${FILTER_EMAIL}\""
elif [[ -n "${FILTER_STATUS}" ]]; then
  COGNITO_FILTER="status = \"${FILTER_STATUS}\""
fi

[[ -n "${COGNITO_FILTER}" ]] && LIST_ARGS+=(--filter "${COGNITO_FILTER}")

# Accumulate raw user JSON objects across pages (one JSON array per iteration)
RAW_PAGES=""
PAGINATION_TOKEN=""
PAGE=0

while true; do
  PAGE=$((PAGE + 1))
  CALL_ARGS=("${LIST_ARGS[@]}" --output json)
  [[ -n "${PAGINATION_TOKEN}" ]] && CALL_ARGS+=(--pagination-token "${PAGINATION_TOKEN}")

  PAGE_JSON=$(aws "${CALL_ARGS[@]}")

  # Extract the Users array for this page
  PAGE_USERS=""
  if command -v jq &>/dev/null; then
    PAGE_USERS=$(echo "${PAGE_JSON}" | jq '.Users // []')
    PAGINATION_TOKEN=$(echo "${PAGE_JSON}" | jq -r '.PaginationToken // ""')
  else
    PAGE_USERS=$(node -e "
      try {
        const r = JSON.parse(process.argv[1]);
        process.stdout.write(JSON.stringify(r.Users || []));
      } catch(e) { process.stdout.write('[]'); }
    " "${PAGE_JSON}" 2>/dev/null || echo "[]")
    PAGINATION_TOKEN=$(node -e "
      try {
        const r = JSON.parse(process.argv[1]);
        process.stdout.write(r.PaginationToken || '');
      } catch(e) {}
    " "${PAGE_JSON}" 2>/dev/null || true)
  fi

  if [[ -z "${RAW_PAGES}" ]]; then
    RAW_PAGES="${PAGE_USERS}"
  else
    if command -v jq &>/dev/null; then
      RAW_PAGES=$(printf '%s\n%s' "${RAW_PAGES}" "${PAGE_USERS}" | jq -s 'add')
    else
      RAW_PAGES=$(node -e "
        const a = JSON.parse(process.argv[1]);
        const b = JSON.parse(process.argv[2]);
        process.stdout.write(JSON.stringify(a.concat(b)));
      " "${RAW_PAGES}" "${PAGE_USERS}" 2>/dev/null)
    fi
  fi

  [[ -z "${PAGINATION_TOKEN}" ]] && break
done

# ---------------------------------------------------------------------------
# Parse users into parallel arrays (bash 3.2 compatible)
# ---------------------------------------------------------------------------

# Extract the total user count first, then build display arrays.
# We store parallel arrays: EMAILS, NAMES, STATUSES, CREATEDS, ENABLEDS.
EMAILS=()
NAMES=()
STATUSES=()
CREATEDS=()
ENABLEDS=()

# Get the number of users in the merged array
if command -v jq &>/dev/null; then
  USER_COUNT=$(echo "${RAW_PAGES}" | jq 'length')
else
  USER_COUNT=$(node -e "
    try {
      const a = JSON.parse(process.argv[1]);
      process.stdout.write(String(a.length));
    } catch(e) { process.stdout.write('0'); }
  " "${RAW_PAGES}" 2>/dev/null || echo "0")
fi

idx=0
while [[ ${idx} -lt ${USER_COUNT} ]]; do
  # Extract one user JSON object
  if command -v jq &>/dev/null; then
    USER_JSON=$(echo "${RAW_PAGES}" | jq -c ".[${idx}]")
  else
    USER_JSON=$(node -e "
      try {
        const a = JSON.parse(process.argv[1]);
        process.stdout.write(JSON.stringify(a[parseInt(process.argv[2])]));
      } catch(e) { process.stdout.write('{}'); }
    " "${RAW_PAGES}" "${idx}" 2>/dev/null || echo "{}")
  fi

  email="$(extract_attr "${USER_JSON}" "email")"
  given="$(extract_attr "${USER_JSON}" "given_name")"
  family="$(extract_attr "${USER_JSON}" "family_name")"
  name="${given} ${family}"
  name="${name## }"
  name="${name%% }"
  status="$(extract_field "${USER_JSON}" "UserStatus")"
  created="$(extract_field "${USER_JSON}" "UserCreateDate")"
  # Trim to date portion only (first 10 chars of ISO timestamp)
  created="${created:0:10}"
  enabled_raw="$(extract_field "${USER_JSON}" "Enabled")"
  if [[ "${enabled_raw}" == "true" || "${enabled_raw}" == "True" ]]; then
    enabled="yes"
  else
    enabled="no"
  fi

  # Post-filter by status if needed
  if [[ -n "${POSTFILTER_STATUS}" && "${status}" != "${POSTFILTER_STATUS}" ]]; then
    idx=$((idx + 1))
    continue
  fi

  EMAILS+=("${email}")
  NAMES+=("${name}")
  STATUSES+=("${status}")
  CREATEDS+=("${created}")
  ENABLEDS+=("${enabled}")

  idx=$((idx + 1))
done

RESULT_COUNT=${#EMAILS[@]}

# Apply --limit
if [[ -n "${LIMIT}" && ${RESULT_COUNT} -gt ${LIMIT} ]]; then
  RESULT_COUNT=${LIMIT}
fi

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

if [[ "${COUNT_ONLY}" == true ]]; then
  echo "${RESULT_COUNT}"
  exit 0
fi

if [[ ${RESULT_COUNT} -eq 0 ]]; then
  echo "No users found." >&2
  exit 0
fi

case "${FORMAT}" in

  # -------------------------------------------------------------------------
  quiet)
    i=0
    while [[ ${i} -lt ${RESULT_COUNT} ]]; do
      echo "${EMAILS[${i}]}"
      i=$((i + 1))
    done
    ;;

  # -------------------------------------------------------------------------
  csv)
    printf '%s\n' "Email,Name,Status,Created,Enabled"
    i=0
    while [[ ${i} -lt ${RESULT_COUNT} ]]; do
      # Quote fields that may contain commas
      printf '"%s","%s","%s","%s","%s"\n' \
        "${EMAILS[${i}]}" \
        "${NAMES[${i}]}" \
        "${STATUSES[${i}]}" \
        "${CREATEDS[${i}]}" \
        "${ENABLEDS[${i}]}"
      i=$((i + 1))
    done
    ;;

  # -------------------------------------------------------------------------
  json)
    # Rebuild a filtered+limited JSON array from the parallel arrays so that
    # client-side post-filters (POSTFILTER_STATUS) and --limit are both
    # respected. Using RAW_PAGES directly would bypass status post-filtering.
    JSON_OUT="["
    i=0
    while [[ ${i} -lt ${RESULT_COUNT} ]]; do
      [[ ${i} -gt 0 ]] && JSON_OUT+=","
      if command -v jq &>/dev/null; then
        entry=$(printf '{"email":%s,"name":%s,"status":%s,"created":%s,"enabled":%s}' \
          "$(printf '%s' "${EMAILS[${i}]}"  | jq -Rs '.')" \
          "$(printf '%s' "${NAMES[${i}]}"   | jq -Rs '.')" \
          "$(printf '%s' "${STATUSES[${i}]}"| jq -Rs '.')" \
          "$(printf '%s' "${CREATEDS[${i}]}"| jq -Rs '.')" \
          "$(printf '%s' "${ENABLEDS[${i}]}"| jq -Rs '.')")
      else
        entry=$(node -e "
          const o = {
            email:   process.argv[1],
            name:    process.argv[2],
            status:  process.argv[3],
            created: process.argv[4],
            enabled: process.argv[5],
          };
          process.stdout.write(JSON.stringify(o));
        " "${EMAILS[${i}]}" "${NAMES[${i}]}" "${STATUSES[${i}]}" \
          "${CREATEDS[${i}]}" "${ENABLEDS[${i}]}" 2>/dev/null)
      fi
      JSON_OUT+="${entry}"
      i=$((i + 1))
    done
    JSON_OUT+="]"

    if command -v jq &>/dev/null; then
      echo "${JSON_OUT}" | jq '.'
    else
      node -e "
        const a = JSON.parse(process.argv[1]);
        process.stdout.write(JSON.stringify(a, null, 2));
      " "${JSON_OUT}" 2>/dev/null
    fi
    ;;

  # -------------------------------------------------------------------------
  table)
    # Build tab-separated lines and pipe through BSD column for alignment.
    # Header + divider + rows.
    {
      printf '%s\t%s\t%s\t%s\t%s\n' \
        "EMAIL" "NAME" "STATUS" "CREATED" "ENABLED"
      printf '%s\t%s\t%s\t%s\t%s\n' \
        "-----" "----" "------" "-------" "-------"
      i=0
      while [[ ${i} -lt ${RESULT_COUNT} ]]; do
        printf '%s\t%s\t%s\t%s\t%s\n' \
          "${EMAILS[${i}]}" \
          "${NAMES[${i}]}" \
          "${STATUSES[${i}]}" \
          "${CREATEDS[${i}]}" \
          "${ENABLEDS[${i}]}"
        i=$((i + 1))
      done
    } | column -t -s $'\t'
    ;;

esac

echo "" >&2
echo "${RESULT_COUNT} user(s) listed." >&2
