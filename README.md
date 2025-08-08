# Automated rsync Backup Script

This is a robust script for automating backups of a local directory to a remote server (like a Hetzner Storage Box) using `rsync` over SSH.

---

## Features

-   **External & Secure Configuration**: Settings are external; credentials are parsed safely to prevent code injection.
-   **Portable**: The entire backup setup (script + configs) can be moved to a new server by copying one directory.
-   **Multi-Notification Support**: Sends notifications to **ntfy** and/or **Discord**, configurable with simple toggles.
-   **Robust Error Handling**: Uses `set -Euo pipefail` and a global `ERR` trap to catch and report any unexpected errors.
-   **Informative Reports**: Notifications include transfer size, files created, and files deleted.
-   **Production Ready**: Uses `nice` and `ionice` to limit CPU/IO impact on the server.
-   **User-Friendly Modes**: Includes `--dry-run`, `--checksum`, `--summary`, and a `--verbose` flag for live progress on manual runs.
-   **Robust Error Handling**: Uses `set -Euo pipefail`, a global `ERR` trap, and handles specific `rsync` exit codes (e.g., warnings vs. failures).
-   **Locking & Log Rotation**: Prevents concurrent runs and manages log file size automatically.
-   **Prerequisite Checks**: Verifies that all required commands and SSH connectivity are working before running.
-   **Log Rotation**: Automatically rotates the log file when it exceeds a defined size.
 

## Usage

-   **Run Silently (for cron)**: `./backup_script.sh`
-   **Run with Live Progress**: `./backup_script.sh --verbose`
-   **Dry Run**: `./backup_script.sh --dry-run`
-   **Check Integrity**: `./backup_script.sh --checksum` (Compares local and remote files using checksums; can be slow but is very thorough).
-   **Get Mismatch Count**: `./backup_script.sh --summary` (Quickly reports the number of files that differ between local and remote).

---

## File Structure

All files should be placed in a single directory (e.g., `/root/scripts/backup`).

```

/root/scripts/backup/
├── backup_script.sh         (The main script)
├── backup_rsync.conf        (Your main backup settings)
├── credentials.conf         (Your secret token and ntfy URL)
└── rsync_exclude.txt        (Files and patterns to exclude)

````

---

## Setup Instructions

Follow these steps to get the backup system running.

### 1. Prerequisites

First, ensure the required tools are installed. On Debian/Ubuntu, you can run:
```sh
sudo apt-get update && sudo apt-get install rsync curl coreutils util-linux
````

*(coreutils provides `numfmt`, `stat`, etc. and util-linux provides `flock`)*

### 2\. Passwordless SSH Login

The script needs to log into the Hetzner Storage Box without a password.

  - **Generate an SSH key** on your server if you don't have one:

    ```sh
    ssh-keygen -t rsa -b 4096
    ```

    (Just press Enter through all the prompts).

  - **Copy your public key** to the Hetzner Storage Box. First, view your public key:

    ```sh
    cat ~/.ssh/id_rsa.pub
    ```

  - Go to your Hetzner Robot panel, select your Storage Box, and paste the entire public key content into the "SSH Keys" section.

  - **Test the connection**. Replace `u444300` and the hostname with your own details.

    ```sh
    ssh -p 23 u444300-sub4@u444300.your-storagebox.de 'echo "Connection successful"'
    ```

    If this works without asking for a password, you are ready.

### 3\. Place and Configure Files

1.  Create your script directory: `mkdir -p /root/scripts/backup && cd /root/scripts/backup`
2.  Create the four files (`backup_script.sh`, `backup_rsync.conf`, `credentials.conf`, `rsync_exclude.txt`) in this directory using the content provided below.
3.  **Make the script executable**:
    ```sh
    chmod +x backup_script.sh
    ```
4.  **Set secure permissions** for your credentials:
    ```sh
    chmod 600 credentials.conf
    ```
5.  Edit `backup_rsync.conf` and `credentials.conf` to match your server paths, Hetzner details, and ntfy topic.
6.  Edit `rsync_exclude.txt` to list any files or directories you wish to skip.

### 4\. Set up a Cron Job

To run the backup automatically, edit the root crontab.

  - Open the crontab editor:
    ```sh
    crontab -e
    ```
  - Add a line to schedule the script. This example runs the backup every day at 3:00 AM.
    ```crontab
    # Run the rsync backup every day at 3:00 AM
    0 3 * * * /root/scripts/backup/backup_script.sh >/dev/null 2>&1
    ```
    *(Redirecting output to `/dev/null` is fine since the script handles its own logging and notifications).*

-----

## Usage

  - **Run Manually**: `cd /root/scripts/backup && ./backup_script.sh`
  - **Dry Run** (see what would change without doing anything): `./backup_script.sh --dry-run`
  - **Check Integrity** (compare local and remote files): `./backup_script.sh --checksum`
  - **Get Mismatch Count**: `./backup_script.sh --summary`

The log file is located at `/var/log/backup_rsync.log` by default.

-----

### **`backup_script.sh`**

```bash
#!/bin/bash

# =================================================================
#               SCRIPT INITIALIZATION & SETUP
# =================================================================
set -Euo pipefail
umask 077

# --- Determine script's location to load local config files ---
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)

# --- Source Configuration Files ---
if [ -f "${SCRIPT_DIR}/backup_rsync.conf" ]; then
    source "${SCRIPT_DIR}/backup_rsync.conf"
else
    echo "FATAL: Main configuration file backup_rsync.conf not found." >&2; exit 1
fi

# Securely load credentials by parsing the file to prevent code injection
if [ -f "${SCRIPT_DIR}/credentials.conf" ]; then
    while IFS='=' read -r key value; do
        [[ "$key" =~ ^\s*#|^\s*$ ]] && continue
        value="${value%\"}"; value="${value#\"}"
        key=$(echo "$key" | tr -d '[:space:]')
        declare "$key=$value"
    done < "${SCRIPT_DIR}/credentials.conf"
else
    echo "FATAL: Credentials file credentials.conf not found." >&2; exit 1
fi

# =================================================================
#               SCRIPT CONFIGURATION (STATIC)
# =================================================================
REMOTE_TARGET="${HETZNER_BOX}:${BOX_DIR}"
LOCK_FILE="/tmp/backup_rsync.lock"
MAX_LOG_SIZE=10485760 # 10 MB in bytes

RSYNC_BASE_OPTS=(
    -a -z --delete --partial --timeout=60
    --exclude-from="$EXCLUDE_FROM"
    -e "$(printf "%s " "${SSH_OPTS[@]}")"
)

# =================================================================
#                       HELPER FUNCTIONS
# =================================================================

log_message() {
    local message="$1"
    echo "[$HOSTNAME] [$(date '+%Y-%m-%d %H:%M:%S')] $message" >> "$LOG_FILE"
    if [[ "${VERBOSE_MODE:-false}" == "true" ]]; then
        echo "$message"
    fi
}

send_ntfy() {
    local title="$1" tags="$2" priority="$3" message="$4"
    if [[ "${NTFY_ENABLED:-false}" != "true" ]] || [ -z "${NTFY_TOKEN:-}" ] || [ -z "${NTFY_URL:-}" ]; then return; fi
    curl -s --max-time 15 -u ":$NTFY_TOKEN" -H "Title: $title" -H "Tags: $tags" -H "Priority: $priority" -d "$message" "$NTFY_URL" > /dev/null 2>> "$LOG_FILE"
}

send_discord() {
    local title="$1" status="$2" message="$3"
    if [[ "${DISCORD_ENABLED:-false}" != "true" ]] || [ -z "${DISCORD_WEBHOOK_URL:-}" ]; then return; fi
    local color; case "$status" in
        success) color=3066993 ;;  # Green
        warning) color=16776960 ;; # Yellow
        failure) color=15158332 ;; # Red
        *)       color=9807270 ;;   # Grey
    esac
    local escaped_message; escaped_message=$(echo "$message" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
    local json_payload; printf -v json_payload '{"embeds": [{"title": "%s", "description": "%s", "color": %d, "timestamp": "%s"}]}' \
        "$title" "$escaped_message" "$color" "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
    curl -s --max-time 15 -H "Content-Type: application/json" -d "$json_payload" "$DISCORD_WEBHOOK_URL" > /dev/null 2>> "$LOG_FILE"
}

send_notification() {
    local title="$1" tags="$2" priority="$3" status="$4" message="$5"
    send_ntfy "$title" "$tags" "$priority" "$message"
    send_discord "$title" "$status" "$message"
}

run_integrity_check() {
    local rsync_check_opts=(-ainc -c --delete --exclude-from="$EXCLUDE_FROM" --out-format="%n" -e "$(printf "%s " "${SSH_OPTS[@]}")")
    LC_ALL=C rsync "${rsync_check_opts[@]}" "$LOCAL_DIR" "$REMOTE_TARGET" 2>> "$LOG_FILE"
}

format_backup_stats() {
    local rsync_output="$1" stats_summary bytes_transferred files_created files_deleted
    bytes_transferred=$(echo "$rsync_output" | grep 'Total_transferred_size:' | awk '{print $2}') || true
    files_created=$(echo "$rsync_output" | grep 'Number_of_created_files:' | awk '{print $2}') || true
    files_deleted=$(echo "$rsync_output" | grep 'Number_of_deleted_files:' | awk '{print $2}') || true
    if [[ "${bytes_transferred:-0}" -gt 0 ]]; then
        stats_summary=$(printf "Data Transferred: %s" "$(numfmt --to=iec-i --suffix=B --format="%.2f" "$bytes_transferred")")
    else
        stats_summary="Data Transferred: 0 B (No changes)"
    fi
    stats_summary+=$(printf "\nFiles Created: %s\nFiles Deleted: %s" "${files_created:-0}" "${files_deleted:-0}")
    echo -e "$stats_summary"
}

cleanup() {
    rm -f "${RSYNC_LOG_TMP:-}"
}

# =================================================================
#               PRE-FLIGHT CHECKS & SETUP
# =================================================================

trap cleanup EXIT
trap 'send_notification "❌ Backup Crashed: ${HOSTNAME}" "x" "high" "failure" "Backup script terminated unexpectedly. Check log: ${LOG_FILE}"' ERR

REQUIRED_CMDS=(rsync curl flock hostname date stat mv touch awk numfmt grep printf nice ionice sed)
for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "FATAL: Required command '$cmd' not found. Please install it." >&2; trap - ERR; exit 10
    fi
done

if ! "${SSH_OPTS[@]}" -o BatchMode=yes -o ConnectTimeout=10 "$HETZNER_BOX" 'exit' 2>/dev/null; then
    send_notification "❌ SSH FAILED: ${HOSTNAME}" "x" "high" "failure" "Unable to SSH into $HETZNER_BOX. Check keys and connectivity."
    trap - ERR; exit 6
fi

if ! [ -f "$EXCLUDE_FROM" ]; then send_notification "❌ Backup FAILED: ${HOSTNAME}" "x" "high" "failure" "FATAL: Exclude file not found at $EXCLUDE_FROM"; trap - ERR; exit 3; fi
if [[ "$LOCAL_DIR" != */ ]]; then send_notification "❌ Backup FAILED: ${HOSTNAME}" "x" "high" "failure" "FATAL: LOCAL_DIR must end with a trailing slash ('/')"; trap - ERR; exit 2; fi

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
            # Disable the global "crash" trap for this specific mode
            trap - ERR
            echo "--- DRY RUN MODE ACTIVATED ---"
            if ! rsync "${RSYNC_BASE_OPTS[@]}" --dry-run --info=progress2 "$LOCAL_DIR" "$REMOTE_TARGET"; then
                echo "" # Add a newline for spacing
                echo "❌ Dry run FAILED. See the rsync error message above for details."
                exit 1
            fi
            echo "--- DRY RUN COMPLETED ---"
            exit 0
            ;;
        --checksum)
            echo "--- INTEGRITY CHECK MODE ACTIVATED ---"
            echo "Comparing checksums... this may take a while."
            FILE_DISCREPANCIES=$(run_integrity_check)
            if [ -z "$FILE_DISCREPANCIES" ]; then
                log_message "✅ Checksum validation passed. No discrepancies found."
                send_notification "✅ Backup Integrity OK: ${HOSTNAME}" "white_check_mark" "default" "success" "Checksum validation passed. No discrepancies found."
            else
                ISSUE_LIST=$(echo "${FILE_DISCREPANCIES}" | head -n 10)
                printf "❌ Backup integrity check FAILED. First 10 differing files:\n%s\n" "${ISSUE_LIST}"
                printf -v FAILURE_MSG "Backup integrity check FAILED.\n\nFirst 10 differing files:\n%s\n\nCheck log for full details." "${ISSUE_LIST}"
                send_notification "❌ Backup Integrity FAILED: ${HOSTNAME}" "x" "high" "failure" "${FAILURE_MSG}"
            fi
            exit 0 ;;

        --summary)
            echo "--- INTEGRITY SUMMARY MODE ---"
            echo "Calculating differences..."
            MISMATCH_COUNT=$(run_integrity_check | wc -l)
            printf "🚨 Total files with checksum mismatches: %d\n" "$MISMATCH_COUNT"
            log_message "Summary mode check found $MISMATCH_COUNT mismatched files."
            send_notification "📊 Backup Summary: ${HOSTNAME}" "bar_chart" "default" "success" "Mismatched files found: $MISMATCH_COUNT"
            exit 0 ;;
    esac
fi

exec 200>"$LOCK_FILE"
flock -n 200 || { echo "Another instance is running, exiting."; exit 5; }

if [ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE")" -gt "$MAX_LOG_SIZE" ]; then
    mv "$LOG_FILE" "${LOG_FILE}.$(date +%Y%m%d_%H%M%S)"
    touch "$LOG_FILE"
fi

echo "============================================================" >> "$LOG_FILE"
log_message "Starting rsync backup..."

START_TIME=$(date +%s)

RSYNC_LOG_TMP=$(mktemp)
RSYNC_EXIT_CODE=0
RSYNC_OPTS=("${RSYNC_BASE_OPTS[@]}")

if [[ "$VERBOSE_MODE" == "true" ]]; then
    RSYNC_OPTS+=(--info=stats2,progress2)
    nice -n 19 ionice -c 3 rsync "${RSYNC_OPTS[@]}" "$LOCAL_DIR" "$REMOTE_TARGET" 2>&1 | tee "$RSYNC_LOG_TMP"
    RSYNC_EXIT_CODE=${PIPESTATUS[0]}
else
    RSYNC_OPTS+=(--info=stats2)
    nice -n 19 ionice -c 3 rsync "${RSYNC_OPTS[@]}" "$LOCAL_DIR" "$REMOTE_TARGET" > "$RSYNC_LOG_TMP" 2>&1 || RSYNC_EXIT_CODE=$?
fi

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

cat "$RSYNC_LOG_TMP" >> "$LOG_FILE"
RSYNC_OUTPUT=$(<"$RSYNC_LOG_TMP")

trap - ERR 

case $RSYNC_EXIT_CODE in
    0)
        BACKUP_STATS=$(format_backup_stats "$RSYNC_OUTPUT")
        SUCCESS_MSG=$(printf "%s\n\nDuration: %dm %ds" "$BACKUP_STATS" $((DURATION / 60)) $((DURATION % 60)))
        log_message "SUCCESS: rsync completed."
        send_notification "✅ Backup SUCCESS: ${HOSTNAME}" "white_check_mark" "default" "success" "$SUCCESS_MSG" ;;
    24)
        BACKUP_STATS=$(format_backup_stats "$RSYNC_OUTPUT")
        WARN_MSG=$(printf "rsync completed with a warning (code 24).\nSome source files vanished during transfer.\n\n%s\n\nDuration: %dm %ds" "$BACKUP_STATS" $((DURATION / 60)) $((DURATION % 60)))
        log_message "WARNING: rsync completed with code 24 (some source files vanished)."
        send_notification "⚠️ Backup Warning: ${HOSTNAME}" "warning" "high" "warning" "$WARN_MSG" ;;
    *)
        FAIL_MSG=$(printf "rsync failed on ${HOSTNAME} with exit code ${RSYNC_EXIT_CODE}. Check log for details.\n\nDuration: %dm %ds" $((DURATION / 60)) $((DURATION % 60)))
        log_message "FAILED: rsync exited with code: $RSYNC_EXIT_CODE."
        send_notification "❌ Backup FAILED: ${HOSTNAME}" "x" "high" "failure" "$FAIL_MSG" ;;
esac

echo "======================= Run Finished =======================" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"
```

-----

### **`backup_rsync.conf`**

```bash
# Configuration for the rsync backup script

# --- Source and Destination ---
# IMPORTANT: LOCAL_DIR must end with a trailing slash!
LOCAL_DIR="/home/user/"

# Directory on the remote storage box
BOX_DIR="/home/myvps/"

# --- Connection Details ---
# Hetzner Storage Box details (username and hostname)
HETZNER_BOX="u444300-sub4@u444300.your-storagebox.de"

# Flexible SSH options array. Add more options if needed (e.g., -i /path/to/key).
SSH_OPTS=(
    ssh
    -p 23
)

# --- Logging ---
LOG_FILE="/var/log/backup_rsync.log"

# --- Exclude File ---
EXCLUDE_FROM="${SCRIPT_DIR}/rsync_exclude.txt"

# --- NOTIFICATION SETTINGS ---
# Set to 'true' to enable a service, 'false' to disable.
NTFY_ENABLED=true
DISCORD_ENABLED=false

```

-----

### **`credentials.conf`**

```ini
# Sensitive information for the backup script
# !! IMPORTANT !! Set permissions to 600 for this file and backup_rsync.conf

# --- ntfy Credentials ---
NTFY_TOKEN="tk_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
NTFY_URL="https://ntfy.sh/your-private-topic-name"

# --- Discord Credentials (optional) ---
DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/your/webhook_url_here"

```

-----

### **`rsync_exclude.txt`**

```
# List of files/directories to exclude from backup, one per line.
# See 'man rsync' for pattern matching rules.

# Common cache and temporary files
.cache/
/tmp/
*.tmp
*.bak
*.swp

# Specific application caches/dependencies
/node_modules/
/vendor/
__pycache__/

# System files that shouldn't be backed up
/lost+found/
.DS_Store
Thumbs.db
```
