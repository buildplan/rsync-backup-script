#!/bin/bash

# =================================================================
#                 SCRIPT INITIALIZATION & SETUP
#                      v0.11 - 2025.08.09
# =================================================================
set -Euo pipefail
umask 077

# Check if the script is being run as root
if (( EUID != 0 )); then
    echo "❌ This script must be run as root or with sudo." >&2
    exit 1
fi

# --- Determine script's location to load the config file ---
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
CONFIG_FILE="${SCRIPT_DIR}/backup.conf"

# --- Create a temporary file for rsync exclusions ---
EXCLUDE_FILE_TMP=$(mktemp)

# --- Securely parse the unified configuration file ---
if [ -f "$CONFIG_FILE" ]; then
    in_exclude_block=false
    while IFS= read -r line; do
        if [[ "$line" == "BEGIN_EXCLUDES" ]]; then
            in_exclude_block=true; continue
        elif [[ "$line" == "END_EXCLUDES" ]]; then
            in_exclude_block=false; continue
        fi

        if $in_exclude_block; then
            [[ ! "$line" =~ ^\s*#|^\s*$ ]] && echo "$line" >> "$EXCLUDE_FILE_TMP"
            continue
        fi

        if [[ "$line" =~ ^\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*=\s*(.*) ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            value="${value%\"}"; value="${value#\"}"
            declare "$key"="$value"
        fi
    done < "$CONFIG_FILE"
else
    echo "FATAL: Unified configuration file backup.conf not found." >&2; exit 1
fi

# --- Validate that all required configuration variables are set ---
for var in BACKUP_DIRS BOX_DIR HETZNER_BOX SSH_OPTS_STR LOG_FILE \
           NTFY_PRIORITY_SUCCESS NTFY_PRIORITY_WARNING NTFY_PRIORITY_FAILURE \
           LOG_RETENTION_DAYS; do
    if [ -z "${!var:-}" ]; then
        echo "FATAL: Required config variable '$var' is missing or empty in $CONFIG_FILE." >&2
        exit 1
    fi
done

# =================================================================
#               SCRIPT CONFIGURATION (STATIC)
# =================================================================
REMOTE_TARGET="${HETZNER_BOX}:${BOX_DIR}"
LOCK_FILE="/tmp/backup_rsync.lock"
MAX_LOG_SIZE=10485760 # 10 MB in bytes

RSYNC_BASE_OPTS=(
    -a -z --delete --partial --timeout=60
    --exclude-from="$EXCLUDE_FILE_TMP"
    -e "ssh ${SSH_OPTS_STR:-}"
)

# =================================================================
#                       HELPER FUNCTIONS
# =================================================================

log_message() {
    local message="$1"
    echo "[$HOSTNAME] [$(date '+%Y-%m-%d %H:%M:%S')] $message" >> "${LOG_FILE:-/dev/null}"
    if [[ "${VERBOSE_MODE:-false}" == "true" ]]; then
        echo "$message"
    fi
}

send_ntfy() {
    local title="$1" tags="$2" priority="$3" message="$4"
    if [[ "${NTFY_ENABLED:-false}" != "true" ]] || [ -z "${NTFY_TOKEN:-}" ] || [ -z "${NTFY_URL:-}" ]; then return; fi
    curl -s --max-time 15 -u ":$NTFY_TOKEN" -H "Title: $title" -H "Tags: $tags" -H "Priority: $priority" -d "$message" "$NTFY_URL" > /dev/null 2>> "${LOG_FILE:-/dev/null}"
}

send_discord() {
    local title="$1" status="$2" message="$3"
    if [[ "${DISCORD_ENABLED:-false}" != "true" ]] || [ -z "${DISCORD_WEBHOOK_URL:-}" ]; then return; fi
    local color; case "$status" in
        success) color=3066993 ;;
        warning) color=16776960 ;;
        failure) color=15158332 ;;
        *)       color=9807270 ;;
    esac
    local escaped_message; escaped_message=$(echo "$message" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
    local json_payload; printf -v json_payload '{"embeds": [{"title": "%s", "description": "%s", "color": %d, "timestamp": "%s"}]}' \
        "$title" "$escaped_message" "$color" "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
    curl -s --max-time 15 -H "Content-Type: application/json" -d "$json_payload" "$DISCORD_WEBHOOK_URL" > /dev/null 2>> "${LOG_FILE:-/dev/null}"
}

send_notification() {
    local title="$1" tags="$2" ntfy_priority="$3" discord_status="$4" message="$5"
    send_ntfy "$title" "$tags" "$ntfy_priority" "$message"
    send_discord "$title" "$discord_status" "$message"
}

run_integrity_check() {
    local rsync_check_opts=(-ainc -c --delete --exclude-from="$EXCLUDE_FILE_TMP" --out-format="%n" -e "ssh ${SSH_OPTS_STR:-}")

    for dir in $BACKUP_DIRS; do
        local remote_subdir="${REMOTE_TARGET}/$(basename "$dir")/"
        # shellcheck disable=SC2086
        LC_ALL=C rsync "${rsync_check_opts[@]}" "$dir" "$remote_subdir" 2>> "${LOG_FILE:-/dev/null}"
    done
}

parse_stat() {
    local output="$1"
    local pattern="$2"
    local awk_command="$3"
    (
        set +o pipefail
        echo "$output" | grep "$pattern" | awk "$awk_command"
    )
}

format_backup_stats() {
    local rsync_output="$1"

    local bytes_transferred=$(parse_stat "$rsync_output" 'Total_transferred_size:' '{s+=$2} END {print s}')
    local files_created=$(parse_stat "$rsync_output" 'Number_of_created_files:' '{s+=$2} END {print s}')
    local files_deleted=$(parse_stat "$rsync_output" 'Number_of_deleted_files:' '{s+=$2} END {print s}')

    # Fallback for older rsync versions
    if [[ -z "$bytes_transferred" && -z "$files_created" && -z "$files_deleted" ]]; then
        bytes_transferred=$(parse_stat "$rsync_output" 'Total transferred file size:' '{gsub(/,/, ""); s+=$5} END {print s}')
        files_created=$(parse_stat "$rsync_output" 'Number of created files:' '{s+=$5} END {print s}')
        files_deleted=$(parse_stat "$rsync_output" 'Number of deleted files:' '{s+=$5} END {print s}')
    fi

    local stats_summary=""
    if [[ "${bytes_transferred:-0}" -gt 0 ]]; then
        stats_summary=$(printf "Data Transferred: %s" "$(numfmt --to=iec-i --suffix=B --format="%.2f" "$bytes_transferred")")
    else
        stats_summary="Data Transferred: 0 B (No changes)"
    fi
    stats_summary+=$(printf "\nFiles Created: %s\nFiles Deleted: %s" "${files_created:-0}" "${files_deleted:-0}")

    printf "%s\n" "$stats_summary"
}

cleanup() {
    rm -f "${EXCLUDE_FILE_TMP:-}"
}

# =================================================================
#               PRE-FLIGHT CHECKS & SETUP
# =================================================================

trap cleanup EXIT
trap 'send_notification "❌ Backup Crashed: ${HOSTNAME}" "x" "${NTFY_PRIORITY_FAILURE}" "failure" "Backup script terminated unexpectedly. Check log: ${LOG_FILE:-/dev/null}"' ERR

REQUIRED_CMDS=(rsync curl flock hostname date stat mv touch awk numfmt grep printf nice ionice sed mktemp basename)
for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "FATAL: Required command '$cmd' not found. Please install it." >&2; trap - ERR; exit 10
    fi
done

if ! ssh ${SSH_OPTS_STR:-} -o BatchMode=yes -o ConnectTimeout=10 "$HETZNER_BOX" 'exit' 2>/dev/null; then
    send_notification "❌ SSH FAILED: ${HOSTNAME}" "x" "${NTFY_PRIORITY_FAILURE}" "failure" "Unable to SSH into $HETZNER_BOX. Check keys and connectivity."
    trap - ERR; exit 6
fi

for dir in $BACKUP_DIRS; do
    if [[ ! -d "$dir" ]] || [[ "$dir" != */ ]]; then
        send_notification "❌ Backup FAILED: ${HOSTNAME}" "x" "${NTFY_PRIORITY_FAILURE}" "failure" "FATAL: A directory in BACKUP_DIRS ('$dir') must exist and end with a trailing slash ('/')."
        trap - ERR; exit 2
    fi
done


# =================================================================
#                       SCRIPT EXECUTION
# =================================================================

HOSTNAME=$(hostname -s)
VERBOSE_MODE=false
if [[ "${1:-}" == "--verbose" ]]; then
    VERBOSE_MODE=true; shift
fi

if [[ "${1:-}" ]]; then
    trap - ERR
    case "${1}" in
        --dry-run)
            trap - ERR
            echo "--- DRY RUN MODE ACTIVATED ---"
            DRY_RUN_FAILED=false
            for dir in $BACKUP_DIRS; do
                remote_subdir="${REMOTE_TARGET}/$(basename "$dir")/"
                echo "--- Checking dry run for: $dir -> $remote_subdir"
                # shellcheck disable=SC2086
                if ! rsync "${RSYNC_BASE_OPTS[@]}" --dry-run --info=progress2 "$dir" "$remote_subdir"; then
                    DRY_RUN_FAILED=true
                fi
            done

            if [[ "$DRY_RUN_FAILED" == "true" ]]; then
                 echo ""
                 echo "❌ Dry run FAILED for one or more directories. See the rsync error messages above for details."
                 exit 1
            fi
            echo "--- DRY RUN COMPLETED ---"; exit 0 ;;

        --checksum | --summary)
            echo "--- INTEGRITY CHECK MODE ACTIVATED ---"
            echo "Calculating differences..."
            FILE_DISCREPANCIES=$(run_integrity_check)

            if [[ "$1" == "--summary" ]]; then
                MISMATCH_COUNT=$(echo "$FILE_DISCREPANCIES" | wc -l)
                printf "🚨 Total files with checksum mismatches: %d\n" "$MISMATCH_COUNT"
                log_message "Summary mode check found $MISMATCH_COUNT mismatched files."
                send_notification "📊 Backup Summary: ${HOSTNAME}" "bar_chart" "${NTFY_PRIORITY_SUCCESS}" "success" "Mismatched files found: $MISMATCH_COUNT"
            else # --checksum
                if [ -z "$FILE_DISCREPANCIES" ]; then
                    echo "✅ Checksum validation passed. No discrepancies found."
                    log_message "Checksum validation passed. No discrepancies found."
                    send_notification "✅ Backup Integrity OK: ${HOSTNAME}" "white_check_mark" "${NTFY_PRIORITY_SUCCESS}" "success" "Checksum validation passed. No discrepancies found."
                else
                    log_message "Backup integrity check FAILED. Found discrepancies."
                    ISSUE_LIST=$(echo "${FILE_DISCREPANCIES}" | head -n 10)
                    printf "❌ Backup integrity check FAILED. First 10 differing files:\n%s\n" "${ISSUE_LIST}"
                    printf -v FAILURE_MSG "Backup integrity check FAILED.\n\nFirst 10 differing files:\n%s\n\nCheck log for full details." "${ISSUE_LIST}"
                    send_notification "❌ Backup Integrity FAILED: ${HOSTNAME}" "x" "${NTFY_PRIORITY_FAILURE}" "failure" "${FAILURE_MSG}"
                fi
            fi
            exit 0 ;;
    esac
fi

exec 200>"$LOCK_FILE"
flock -n 200 || { echo "Another instance is running, exiting."; exit 5; }

if [ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE")" -gt "$MAX_LOG_SIZE" ]; then
    mv "$LOG_FILE" "${LOG_FILE}.$(date +%Y%m%d_%H%M%S)"
    touch "$LOG_FILE"
    find "$(dirname "$LOG_FILE")" -name "$(basename "$LOG_FILE").*" -type f -mtime +"$LOG_RETENTION_DAYS" -delete
fi

echo "============================================================" >> "$LOG_FILE"
log_message "Starting rsync backup..."

# --- Execute Backup for Each Directory ---
START_TIME=$(date +%s)
success_dirs=()
failed_dirs=()
overall_exit_code=0
full_rsync_output=""

for dir in $BACKUP_DIRS; do
    log_message "Backing up directory: $dir"

    remote_subdir="${REMOTE_TARGET}/$(basename "$dir")/"

    RSYNC_LOG_TMP=$(mktemp)
    RSYNC_EXIT_CODE=0
    RSYNC_OPTS=("${RSYNC_BASE_OPTS[@]}")

    if [[ "$VERBOSE_MODE" == "true" ]]; then
        RSYNC_OPTS+=(--info=stats2,progress2)
        # shellcheck disable=SC2086
        nice -n 19 ionice -c 3 rsync "${RSYNC_OPTS[@]}" "$dir" "$remote_subdir" 2>&1 | tee "$RSYNC_LOG_TMP"
        RSYNC_EXIT_CODE=${PIPESTATUS[0]}
    else
        RSYNC_OPTS+=(--info=stats2)
        # shellcheck disable=SC2086
        nice -n 19 ionice -c 3 rsync "${RSYNC_OPTS[@]}" "$dir" "$remote_subdir" > "$RSYNC_LOG_TMP" 2>&1 || RSYNC_EXIT_CODE=$?
    fi

    cat "$RSYNC_LOG_TMP" >> "$LOG_FILE"
    full_rsync_output+=$'\n'"$(<"$RSYNC_LOG_TMP")"
    rm -f "$RSYNC_LOG_TMP"

    if [[ $RSYNC_EXIT_CODE -eq 0 || $RSYNC_EXIT_CODE -eq 24 ]]; then
        success_dirs+=("$(basename "$dir")")
        if [[ $RSYNC_EXIT_CODE -eq 24 ]]; then
            log_message "WARNING for $dir: rsync completed with code 24 (some source files vanished)."
            overall_exit_code=24
        fi
    else
        failed_dirs+=("$(basename "$dir")")
        log_message "FAILED for $dir: rsync exited with code: $RSYNC_EXIT_CODE."
        overall_exit_code=1
    fi
done

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
trap - ERR

# --- Final Notification Logic ---
BACKUP_STATS=$(format_backup_stats "$full_rsync_output")
FINAL_MESSAGE=$(printf "%s\n\nDuration: %dm %ds" "$BACKUP_STATS" $((DURATION / 60)) $((DURATION % 60)))

if [[ ${#failed_dirs[@]} -eq 0 ]]; then
    log_message "SUCCESS: All backups completed."
    if [[ $overall_exit_code -eq 24 ]]; then
        send_notification "⚠️ Backup Warning: ${HOSTNAME}" "warning" "${NTFY_PRIORITY_WARNING}" "warning" "$FINAL_MESSAGE"
    else
        send_notification "✅ Backup SUCCESS: ${HOSTNAME}" "white_check_mark" "${NTFY_PRIORITY_SUCCESS}" "success" "$FINAL_MESSAGE"
    fi
else
    printf -v FAIL_MSG "One or more backups failed.\n\nSuccessful: %s\nFailed: %s\n\n%s" \
        "${success_dirs[*]:-None}" "${failed_dirs[*]}" "$FINAL_MESSAGE"
    log_message "FAILURE: One or more backups failed."
    send_notification "❌ Backup FAILED: ${HOSTNAME}" "x" "${NTFY_PRIORITY_FAILURE}" "failure" "$FAIL_MSG"
fi

echo "======================= Run Finished =======================" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"
