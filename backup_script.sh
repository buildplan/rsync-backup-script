#!/bin/bash
# ===================== v0.24 - 2025.08.11 ========================
#
# =================================================================
#                 SCRIPT INITIALIZATION & SETUP
# =================================================================
set -Euo pipefail
umask 077

HOSTNAME=$(hostname -s)

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
            [[ ! "$line" =~ ^([[:space:]]*#|[[:space:]]*$) ]] && echo "$line" >> "$EXCLUDE_FILE_TMP"
            continue
        fi
        
        if [[ "$line" =~ ^[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*=[[:space:]]*(.*) ]]; then
            key="${BASH_REMATCH[1]}"; value="${BASH_REMATCH[2]}"
            value="${value%\"}"; value="${value#\"}"

            case "$key" in
                BACKUP_DIRS|BOX_DIR|HETZNER_BOX|SSH_OPTS_STR|LOG_FILE|LOG_RETENTION_DAYS|\
                NTFY_ENABLED|DISCORD_ENABLED|NTFY_TOKEN|NTFY_URL|DISCORD_WEBHOOK_URL|\
                NTFY_PRIORITY_SUCCESS|NTFY_PRIORITY_WARNING|NTFY_PRIORITY_FAILURE|\
                RECYCLE_BIN_ENABLED|RECYCLE_BIN_DIR|RECYCLE_BIN_RETENTION_DAYS)
                    declare "$key"="$value"
                    ;;
                *)
                    echo "WARNING: Unknown config variable '$key' ignored in $CONFIG_FILE" >&2
                    ;;
            esac
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
if [[ "${RECYCLE_BIN_ENABLED:-false}" == "true" ]]; then
    for var in RECYCLE_BIN_DIR RECYCLE_BIN_RETENTION_DAYS; do
        if [ -z "${!var:-}" ]; then
            echo "FATAL: When RECYCLE_BIN_ENABLED is true, '$var' must be set in $CONFIG_FILE." >&2
            exit 1
        fi
    done
fi
# =================================================================
#               SCRIPT CONFIGURATION (STATIC)
# =================================================================
REMOTE_TARGET="${HETZNER_BOX}:${BOX_DIR}"
LOCK_FILE="/tmp/backup_rsync.lock"
MAX_LOG_SIZE=10485760 # 10 MB in bytes

RSYNC_BASE_OPTS=(
    -aR -z --delete --partial --timeout=60 --mkpath
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
        success) color=3066993 ;; warning) color=16776960 ;; failure) color=15158332 ;; *) color=9807270 ;;
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
    local rsync_check_opts=(-aincR -c --delete --mkpath --exclude-from="$EXCLUDE_FILE_TMP" --out-format="%n" -e "ssh ${SSH_OPTS_STR:-}")
    local DIRS_ARRAY; read -ra DIRS_ARRAY <<< "$BACKUP_DIRS"
    for dir in "${DIRS_ARRAY[@]}"; do
        echo "--- Integrity Check: $dir ---" >&2
        LC_ALL=C rsync "${rsync_check_opts[@]}" "$dir" "$REMOTE_TARGET" 2>> "${LOG_FILE:-/dev/null}"
    done
}
parse_stat() {
    local output="$1" pattern="$2" awk_command="$3"
    ( set +o pipefail; echo "$output" | grep "$pattern" | awk "$awk_command" )
}
format_backup_stats() {
    local rsync_output="$1"
    local files_transferred=$(parse_stat "$rsync_output" 'Number of regular files transferred:' '{s+=$2} END {print s}')
    local bytes_transferred=$(parse_stat "$rsync_output" 'Total_transferred_size:' '{s+=$2} END {print s}')
    local files_created=$(parse_stat "$rsync_output" 'Number_of_created_files:' '{s+=$2} END {print s}')
    local files_deleted=$(parse_stat "$rsync_output" 'Number_of_deleted_files:' '{s+=$2} END {print s}')
    if [[ -z "$bytes_transferred" && -z "$files_created" && -z "$files_deleted" ]]; then
        files_transferred=$(parse_stat "$rsync_output" 'Number of files transferred:' '{gsub(/,/, ""); s+=$4} END {print s}')
        bytes_transferred=$(parse_stat "$rsync_output" 'Total transferred file size:' '{gsub(/,/, ""); s+=$5} END {print s}')
        files_created=$(parse_stat "$rsync_output" 'Number of created files:' '{s+=$5} END {print s}')
        files_deleted=$(parse_stat "$rsync_output" 'Number of deleted files:' '{s+=$5} END {print s}')
    fi
    local files_updated=$(( ${files_transferred:-0} - ${files_created:-0} ))
    if (( files_updated < 0 )); then files_updated=0; fi
    local stats_summary=""
    if [[ "${bytes_transferred:-0}" -gt 0 ]]; then
        stats_summary=$(printf "Data Transferred: %s" "$(numfmt --to=iec-i --suffix=B --format="%.2f" "$bytes_transferred")")
    else
        stats_summary="Data Transferred: 0 B (No changes)"
    fi
    stats_summary+=$(printf "\nFiles Updated: %s\nFiles Created: %s\nFiles Deleted: %s" "${files_updated:-0}" "${files_created:-0}" "${files_deleted:-0}")
    printf "%s\n" "$stats_summary"
}
cleanup() {
    rm -f "${EXCLUDE_FILE_TMP:-}" "${RSYNC_LOG_TMP:-}"
}
run_preflight_checks() {
    local mode=${1:-backup}; local test_mode=false
    if [[ "$mode" == "test" ]]; then test_mode=true; fi
    local check_failed=false
    if [[ "$test_mode" == "true" ]]; then echo "--- Checking required commands..."; fi
    for cmd in "${REQUIRED_CMDS[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then echo "❌ FATAL: Required command '$cmd' not found." >&2; check_failed=true; fi
    done
    if [[ "$check_failed" == "true" ]]; then exit 10; fi
    if [[ "$test_mode" == "true" ]]; then echo "✅ All required commands are present."; fi
    if [[ "$test_mode" == "true" ]]; then echo "--- Checking SSH connectivity..."; fi
    if ! ssh ${SSH_OPTS_STR:-} -o BatchMode=yes -o ConnectTimeout=10 "$HETZNER_BOX" 'exit' 2>/dev/null; then
        local err_msg="Unable to SSH into $HETZNER_BOX. Check keys and connectivity."
        if [[ "$test_mode" == "true" ]]; then echo "❌ $err_msg"; else send_notification "❌ SSH FAILED: ${HOSTNAME}" "x" "${NTFY_PRIORITY_FAILURE}" "failure" "$err_msg"; fi; exit 6
    fi
    if [[ "$test_mode" == "true" ]]; then echo "✅ SSH connectivity OK."; fi
    if [[ "$mode" != "restore" ]]; then
        if [[ "$test_mode" == "true" ]]; then echo "--- Checking backup directories..."; fi
        local DIRS_ARRAY; read -ra DIRS_ARRAY <<< "$BACKUP_DIRS"
        for dir in "${DIRS_ARRAY[@]}"; do
            if [[ ! -d "$dir" ]] || [[ "$dir" != */ ]]; then
                local err_msg="A directory in BACKUP_DIRS ('$dir') must exist and end with a trailing slash ('/')."
                if [[ "$test_mode" == "true" ]]; then echo "❌ FATAL: $err_msg"; else send_notification "❌ Backup FAILED: ${HOSTNAME}" "x" "${NTFY_PRIORITY_FAILURE}" "failure" "FATAL: $err_msg"; fi; exit 2
            fi
            if [[ ! -r "$dir" ]]; then
                local err_msg="A directory in BACKUP_DIRS ('$dir') is not readable."
                if [[ "$test_mode" == "true" ]]; then echo "❌ FATAL: $err_msg"; else send_notification "❌ Backup FAILED: ${HOSTNAME}" "x" "${NTFY_PRIORITY_FAILURE}" "failure" "FATAL: $err_msg"; fi; exit 2
            fi
        done
        if [[ "$test_mode" == "true" ]]; then echo "✅ All backup directories are valid."; fi
        if [[ "$test_mode" == "true" ]]; then echo "--- Checking local disk space..."; fi
        local required_space_kb=102400 # 100MB in KB
        local available_space_kb
        available_space_kb=$(df --output=avail "$(dirname "${LOG_FILE}")" | tail -n1)
        if [[ "$available_space_kb" -lt "$required_space_kb" ]]; then
            local err_msg="Insufficient disk space in $(dirname "${LOG_FILE}") to guarantee logging. ($((available_space_kb / 1024))MB available)"
            if [[ "$test_mode" == "true" ]]; then echo "❌ FATAL: $err_msg"; else send_notification "❌ Backup FAILED: ${HOSTNAME}" "x" "${NTFY_PRIORITY_FAILURE}" "failure" "FATAL: $err_msg"; fi
            exit 7
        fi
        if [[ "$test_mode" == "true" ]]; then echo "✅ Local disk space OK."; fi
    fi
}
run_restore_mode() {
    echo "--- RESTORE MODE ACTIVATED ---"
    run_preflight_checks "restore"
    local DIRS_ARRAY; read -ra DIRS_ARRAY <<< "$BACKUP_DIRS"
    echo "Available backups to restore:"
    select dir_choice in "${DIRS_ARRAY[@]}" "Cancel"; do
        if [[ "$dir_choice" == "Cancel" ]]; then echo "Restore cancelled."; return 0;
        elif [[ -n "$dir_choice" ]]; then break;
        else echo "Invalid selection. Please try again."; fi
    done
    local relative_path="${dir_choice#*./}"
    local full_remote_source="${REMOTE_TARGET}${relative_path}"
    local default_local_dest; default_local_dest=$(echo "$dir_choice" | sed 's#/\./#/#')
    local final_dest; read -p $'\nEnter the destination path.\nPress [Enter] to use the original location ('"$default_local_dest"$'): ' final_dest
    : "${final_dest:=$default_local_dest}"
    local dest_created=false
    if [[ ! -d "$final_dest" ]]; then dest_created=true; fi
    if [[ "$final_dest" != "$default_local_dest" && -d "$final_dest" ]]; then
        local warning_msg="⚠️ WARNING: The custom destination directory '$final_dest' already exists. Files may be overwritten."
        echo "$warning_msg"; log_message "$warning_msg"
    fi
    if ! mkdir -p "$final_dest"; then echo "❌ FATAL: Could not create destination directory '$final_dest'. Aborting." >&2; return 1; fi
    if [[ "$dest_created" == "true" ]]; then
        chmod 700 "$final_dest"; log_message "Set permissions to 700 on newly created restore directory: $final_dest"
    fi
    echo "Restore destination is set to: $final_dest"
    echo ""; echo "--- PERFORMING DRY RUN. NO FILES WILL BE CHANGED. ---"
    log_message "Starting restore dry-run from ${full_remote_source} to ${final_dest}"
    local rsync_restore_opts=(-avhi --progress --exclude-from="$EXCLUDE_FILE_TMP" -e "ssh ${SSH_OPTS_STR:-}")
    if ! rsync "${rsync_restore_opts[@]}" --dry-run "$full_remote_source" "$final_dest"; then
        echo "❌ DRY RUN FAILED. Rsync reported an error. Aborting." >&2; return 1
    fi
    echo "--- DRY RUN COMPLETE ---"
    local confirmation; while true; do
        read -p $'\nAre you sure you want to proceed with restoring files to '"$final_dest"'? [yes/no]: ' confirmation
        case "$confirmation" in
            yes) break ;; no) echo "Restore aborted by user." ; return 0 ;; *) echo "Please answer yes or no." ;;
        esac
    done
    echo -e "\n--- PROCEEDING WITH RESTORE... ---"
    log_message "Starting REAL restore from ${full_remote_source} to ${final_dest}"
    if rsync "${rsync_restore_opts[@]}" "$full_remote_source" "$final_dest"; then
        log_message "Restore completed successfully."
        echo "✅ Restore of '$relative_path' to '$final_dest' completed successfully."
        send_notification "✅ Restore SUCCESS: ${HOSTNAME}" "white_check_mark" "${NTFY_PRIORITY_SUCCESS}" "success" "Successfully restored ${relative_path} to ${final_dest}"
    else
        log_message "Restore FAILED with rsync exit code $?."
        echo "❌ Restore FAILED. Check the rsync output and log for details."
        send_notification "❌ Restore FAILED: ${HOSTNAME}" "x" "${NTFY_PRIORITY_FAILURE}" "failure" "Restore of ${relative_path} to ${final_dest} failed."
        return 1
    fi
}
run_recycle_bin_cleanup() {
    if [[ "${RECYCLE_BIN_ENABLED:-false}" != "true" ]]; then return 0; fi
    log_message "Checking for remote recycle bin folders older than ${RECYCLE_BIN_RETENTION_DAYS} days..."
    local remote_cleanup_path="${BOX_DIR%/}/${RECYCLE_BIN_DIR%/}"
    local remote_command='
        if [ ! -d "'"${remote_cleanup_path}"'" ]; then exit 0; fi        
        find -- "'"${remote_cleanup_path}"'" -mindepth 1 -maxdepth 1 -type d -mtime +'${RECYCLE_BIN_RETENTION_DAYS}' -print -exec rm -rf {} +
    '
    local deleted
    deleted=$(ssh ${SSH_OPTS_STR:-} "$HETZNER_BOX" "$remote_command" 2>> "${LOG_FILE:-/dev/null}") || {
        local exit_code=$?
        log_message "WARNING: Remote recycle bin cleanup failed with exit code ${exit_code}."
        return 0
    }
    if [[ -n "$deleted" ]]; then
        log_message "Removed old recycle bin folders:"
        while IFS= read -r folder; do
            log_message "  $folder"
        done <<< "$deleted"
    else
        log_message "No old recycle bin folders to remove."
    fi
}

trap cleanup EXIT
trap 'send_notification "❌ Backup Crashed: ${HOSTNAME}" "x" "${NTFY_PRIORITY_FAILURE}" "failure" "Backup script terminated unexpectedly. Check log: ${LOG_FILE:-/dev/null}"' ERR

REQUIRED_CMDS=(rsync ssh curl flock hostname date stat mv touch awk numfmt grep printf nice ionice sed mktemp basename read)

# =================================================================
#                       SCRIPT EXECUTION
# =================================================================

VERBOSE_MODE=false
if [[ "${1:-}" == "--verbose" ]]; then
    VERBOSE_MODE=true; shift
fi

if [[ "${1:-}" ]]; then
    case "${1}" in
        --dry-run)
            trap - ERR
            echo "--- DRY RUN MODE ACTIVATED ---"; DRY_RUN_FAILED=false; full_dry_run_output=""
            read -ra DIRS_ARRAY <<< "$BACKUP_DIRS"
            for dir in "${DIRS_ARRAY[@]}"; do
                echo -e "\n--- Checking dry run for: $dir ---"
                rsync_dry_opts=( "${RSYNC_BASE_OPTS[@]}" --dry-run --itemize-changes --out-format="%i %n%L" --info=stats2,name,flist2 )
                if [[ "${RECYCLE_BIN_ENABLED:-false}" == "true" ]]; then
                    backup_dir="${BOX_DIR%/}/${RECYCLE_BIN_DIR%/}/$(date +%F)/"
                    rsync_dry_opts+=(--backup --backup-dir="$backup_dir")
                fi
                DRY_RUN_LOG_TMP=$(mktemp)
                if ! rsync "${rsync_dry_opts[@]}" "$dir" "$REMOTE_TARGET" > "$DRY_RUN_LOG_TMP" 2>&1; then DRY_RUN_FAILED=true; fi
                echo "---- Preview of changes (first 20) ----"
                grep -E '^\*deleting|^[<>ch\.]f|^cd|^\.d' "$DRY_RUN_LOG_TMP" | head -n 20 || true
                echo "-------------------------------------"
                full_dry_run_output+=$'\n'"$(<"$DRY_RUN_LOG_TMP")"; rm -f "$DRY_RUN_LOG_TMP"
            done
            echo -e "\n--- Overall Dry Run Summary ---"
            BACKUP_STATS=$(format_backup_stats "$full_dry_run_output")
            echo -e "$BACKUP_STATS"; echo "-------------------------------"
            if [[ "$DRY_RUN_FAILED" == "true" ]]; then
                 echo -e "\n❌ Dry run FAILED for one or more directories. See rsync errors above."; exit 1
            fi
            echo "--- DRY RUN COMPLETED ---"; exit 0 ;;
        --checksum | --summary)
            trap - ERR
            echo "--- INTEGRITY CHECK MODE ACTIVATED ---"; echo "Calculating differences..."
            START_TIME_INTEGRITY=$(date +%s); FILE_DISCREPANCIES=$(run_integrity_check); END_TIME_INTEGRITY=$(date +%s)
            DURATION_INTEGRITY=$((END_TIME_INTEGRITY - START_TIME_INTEGRITY))
            CLEAN_DISCREPANCIES=$(echo "$FILE_DISCREPANCIES" | grep -v '^\*')
            if [[ "$1" == "--summary" ]]; then
                MISMATCH_COUNT=$(echo "$CLEAN_DISCREPANCIES" | wc -l)
                printf "🚨 Total files with checksum mismatches: %d\n" "$MISMATCH_COUNT"
                log_message "Summary mode check found $MISMATCH_COUNT mismatched files."
                send_notification "📊 Backup Summary: ${HOSTNAME}" "bar_chart" "${NTFY_PRIORITY_SUCCESS}" "success" "Mismatched files found: $MISMATCH_COUNT"
            else # --checksum
                if [ -z "$CLEAN_DISCREPANCIES" ]; then
                    echo "✅ Checksum validation passed. No discrepancies found."
                    log_message "Checksum validation passed. No discrepancies found."
                    send_notification "✅ Backup Integrity OK: ${HOSTNAME}" "white_check_mark" "${NTFY_PRIORITY_SUCCESS}" "success" "Checksum validation passed."
                else
                    log_message "Backup integrity check FAILED. Found discrepancies."
                    ISSUE_LIST=$(echo "$CLEAN_DISCREPANCIES" | head -n 10)
                    printf -v FAILURE_MSG "Backup integrity check FAILED.\n\nFirst 10 differing files:\n%s\n\nCheck duration: %dm %ds" "${ISSUE_LIST}" $((DURATION_INTEGRITY / 60)) $((DURATION_INTEGRITY % 60))
                    printf "❌ %s\n" "$FAILURE_MSG"
                    send_notification "❌ Backup Integrity FAILED: ${HOSTNAME}" "x" "${NTFY_PRIORITY_FAILURE}" "failure" "${FAILURE_MSG}"
                fi
            fi
            exit 0 ;;
        --test)
            trap - ERR
            echo "--- TEST MODE ACTIVATED ---"; run_preflight_checks "test"
            echo "---------------------------"; echo "✅ All configuration checks passed."; exit 0 ;;
        --restore)
            trap - ERR; run_restore_mode; exit 0 ;;
    esac
fi

run_preflight_checks

exec 200>"$LOCK_FILE"
flock -n 200 || { echo "Another instance is running, exiting."; exit 5; }

if [ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE")" -gt "$MAX_LOG_SIZE" ]; then
    mv "$LOG_FILE" "${LOG_FILE}.$(date +%Y%m%d_%H%M%S)"
    touch "$LOG_FILE"
    find "$(dirname "$LOG_FILE")" -name "$(basename "$LOG_FILE").*" -type f -mtime +"$LOG_RETENTION_DAYS" -delete
fi

echo "============================================================" >> "$LOG_FILE"
log_message "Starting rsync backup..."

START_TIME=$(date +%s)
success_dirs=(); failed_dirs=(); overall_exit_code=0; full_rsync_output=""
read -ra DIRS_ARRAY <<< "$BACKUP_DIRS"
for dir in "${DIRS_ARRAY[@]}"; do
    log_message "Backing up directory: $dir"
    RSYNC_LOG_TMP=$(mktemp)
    RSYNC_EXIT_CODE=0; RSYNC_OPTS=("${RSYNC_BASE_OPTS[@]}")
    if [[ "${RECYCLE_BIN_ENABLED:-false}" == "true" ]]; then
        backup_dir="${BOX_DIR%/}/${RECYCLE_BIN_DIR%/}/$(date +%F)/"
        RSYNC_OPTS+=(--backup --backup-dir="$backup_dir")
    fi
    if [[ "$VERBOSE_MODE" == "true" ]]; then
        RSYNC_OPTS+=(--info=stats2,progress2)
        nice -n 19 ionice -c 3 rsync "${RSYNC_OPTS[@]}" "$dir" "$REMOTE_TARGET" 2>&1 | tee "$RSYNC_LOG_TMP"
        RSYNC_EXIT_CODE=${PIPESTATUS[0]}
    else
        RSYNC_OPTS+=(--info=stats2)
        nice -n 19 ionice -c 3 rsync "${RSYNC_OPTS[@]}" "$dir" "$REMOTE_TARGET" > "$RSYNC_LOG_TMP" 2>&1 || RSYNC_EXIT_CODE=$?
    fi
    cat "$RSYNC_LOG_TMP" >> "$LOG_FILE"; full_rsync_output+=$'\n'"$(<"$RSYNC_LOG_TMP")"
    rm -f "$RSYNC_LOG_TMP"
    if [[ $RSYNC_EXIT_CODE -eq 0 || $RSYNC_EXIT_CODE -eq 24 ]]; then
        success_dirs+=("$(basename "$dir")")
        if [[ $RSYNC_EXIT_CODE -eq 24 ]]; then
            log_message "WARNING for $dir: rsync completed with code 24."; overall_exit_code=24
        fi
    else
        failed_dirs+=("$(basename "$dir")")
        log_message "FAILED for $dir: rsync exited with code: $RSYNC_EXIT_CODE."; overall_exit_code=1
    fi
done

run_recycle_bin_cleanup

END_TIME=$(date +%s); DURATION=$((END_TIME - START_TIME)); trap - ERR

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
    log_message "FAILURE: One or more backups failed."; send_notification "❌ Backup FAILED: ${HOSTNAME}" "x" "${NTFY_PRIORITY_FAILURE}" "failure" "$FAIL_MSG"
fi

echo "======================= Run Finished =======================" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"
