# Automated rsync Backup Script

This script is for automating backups of a local directory to a remote server (like a Hetzner Storage Box) using `rsync` over SSH.

-----

## Features

  - **Unified & Secure Configuration**: All settings are in a single `backup.conf` file, parsed safely to prevent code injection.
  - **Portable**: The entire backup setup (script + config) can be moved to a new server by copying one directory.
  - **Multi-Notification Support**: Sends notifications to **ntfy** and/or **Discord**, configurable with simple toggles.
  - **Robust Error Handling**: Uses `set -Euo pipefail` and a global `ERR` trap to catch and report any unexpected errors.
  - **Informative Reports**: Notifications include transfer size, files created, and files deleted.
  - **Production Ready**: Uses `nice` and `ionice` to limit CPU/IO impact on the server.
  - **User-Friendly Modes**: Includes `--dry-run`, `--checksum`, `--summary`, and a `--verbose` flag for live progress on manual runs.
  - **Locking & Log Rotation**: Prevents concurrent runs and manages log file size automatically.
  - **Prerequisite Checks**: Verifies that all required commands and SSH connectivity are working before running.

-----

## Usage

  - **Download script and configuration file**:
    You'll need two files: the script itself and the configuration file.

    ```sh
    # 1. Get the script and make it executable
    wget https://github.com/buildplan/rsync-backup-script/raw/refs/heads/improve/backup_script.sh && chmod +x backup_script.sh

    # 2. Get the new unified config file and set secure permissions
    wget https://github.com/buildplan/rsync-backup-script/raw/refs/heads/improve/backup.conf && chmod 600 backup.conf
    ```

  - **Run Silently**: `sudo ./backup_script.sh` (for cron)
  - **Run with Live Progress**: `sudo ./backup_script.sh --verbose`
  - **Dry Run**: `sudo ./backup_script.sh --dry-run` (see what would change without doing anything)
  - **Check Integrity**: `sudo ./backup_script.sh --checksum` (Compares local and remote files using checksums; can be slow but is very thorough).
  - **Get Mismatch Count**: `sudo ./backup_script.sh --summary` (Quickly reports the number of files that differ between local and remote).

*The log file is located at `/var/log/backup_rsync.log` by default.*

-----

## File Structure

All files should be placed in a single directory (e.g., `/home/user/scripts/backup`). The new structure is simpler with only two files to manage.

```
/home/user/scripts/backup/
├── backup_script.sh      (The main script)
└── backup.conf           (Your unified settings, credentials, and excludes)
```

-----

## Setup Instructions

Follow these steps to get the backup system running.

### 1\. Prerequisites

First, ensure the required tools are installed. On Debian/Ubuntu, you can run:

```sh
sudo apt-get update && sudo apt-get install rsync curl coreutils util-linux
```

*(coreutils provides `numfmt`, `stat`, etc. and util-linux provides `flock` and `mktemp`)*

### 2\. Passwordless SSH Login

The script needs to log into the Hetzner Storage Box without a password.

  - **Generate a root user SSH key** on your server if you don't have one (using root will avoid permissions issues):

    ```sh
    sudo ssh-keygen -t ed25519
    ```

    (Just press Enter through all the prompts).

  - **Copy your public key** to the Hetzner Storage Box. First, view your public key:

    ```sh
    sudo cat /root/.ssh/id_ed25519.pub
    ```

    *If you encounter permission issues use `sudo su` to access root directly.*

  - Go to your Hetzner Robot panel, select your Storage Box, and paste the entire public key content into the "SSH Keys" section.

  - Or use the `ssh-copy-id` command (replace `u444300` and the hostname with your own details):

    ```sh
    sudo ssh-copy-id -p 23 -s u444300-sub4@u444300.your-storagebox.de
    ```

    *Hetzner Storage Box requires the `-s` flag.*

  - **Test the connection**. You can find the correct port and user in your `backup.conf` file.

    ```sh
    sudo ssh -p 23 u444300-sub4@u444300.your-storagebox.de 'echo "Connection successful"'
    ```

    If this works without asking for a password, you are ready.

### 3\. Place and Configure Files

1.  Create your script directory: `mkdir -p /home/user/scripts/backup && cd /home/user/scripts/backup`
2.  Create the two files (`backup_script.sh` and `backup.conf`) in this directory using the content provided below.
3.  **Make the script executable**:
    ```sh
    chmod +x backup_script.sh
    ```
4.  **Set secure permissions** for your configuration file:
    ```sh
    chmod 600 backup.conf
    ```
5.  Edit **`backup.conf`** to match your server paths, Hetzner details, notification credentials, and to customize your exclusion list.

### 4\. Set up a Cron Job

To run the backup automatically, edit the root crontab.

  - Open the crontab editor:

    ```sh
    sudo crontab -e
    ```

  - Add a line to schedule the script. This example runs the backup every day at 3:00 AM.

    ```crontab
    # Run the rsync backup every day at 3:00 AM
    0 3 * * * /home/user/scripts/backup/backup_script.sh >/dev/null 2>&1
    ```

    *(Redirecting output to `/dev/null` is fine since the script handles its own logging and notifications).*

    *(Note: `sudo` is not needed here because this command is placed in the root user's crontab via `sudo crontab -e`, so it already runs with root privileges.)*

-----

-----

## The Files

### **`backup.conf`**

```ini
# =================================================================
#      Configuration for rsync Backup Script
# =================================================================
# !! IMPORTANT !! Set file permissions to 600 (chmod 600 backup.conf)

# --- Source and Destination ---
# IMPORTANT: LOCAL_DIR must end with a trailing slash!
LOCAL_DIR="/home/user/"
BOX_DIR="/home/myvps/"

# --- Connection Details ---
HETZNER_BOX="u444300-sub4@u444300.your-storagebox.de"

# Add any other SSH options here. They will be split by spaces.
# Example: -p 23 -i /root/.ssh/hetzner_key
SSH_OPTS_STR="-p 23"

# --- Logging ---
LOG_FILE="/var/log/backup_rsync.log"

# --- Notification Toggles ---
# Set to 'true' to enable, 'false' to disable.
NTFY_ENABLED=true
DISCORD_ENABLED=false

# --- ntfy Credentials ---
NTFY_TOKEN="tk_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
NTFY_URL="https://ntfy.sh/your-private-topic-name"

# --- Discord Credentials ---
DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/your/webhook_url_here"

# --- rsync Exclusions ---
# List all file/directory patterns to exclude below.
# The script will read everything between the BEGIN and END markers.
BEGIN_EXCLUDES
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
END_EXCLUDES
```

-----

### **`backup_script.sh`**

```bash
#!/bin/bash

# =================================================================
#                 SCRIPT INITIALIZATION & SETUP
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
# This file will be populated from the config and cleaned up automatically on exit.
EXCLUDE_FILE_TMP=$(mktemp)

# --- Securely parse the unified configuration file ---
if [ -f "$CONFIG_FILE" ]; then
    # Initialize an empty array for SSH options for robustness
    SSH_OPTS_ARR=()
    in_exclude_block=false
    while IFS= read -r line; do
        # Handle the rsync exclusion block
        if [[ "$line" == "BEGIN_EXCLUDES" ]]; then
            in_exclude_block=true
            continue
        elif [[ "$line" == "END_EXCLUDES" ]]; then
            in_exclude_block=false
            continue
        fi

        if $in_exclude_block; then
            # Append non-empty, non-comment lines to the temp exclude file
            [[ ! "$line" =~ ^\s*#|^\s*$ ]] && echo "$line" >> "$EXCLUDE_FILE_TMP"
            continue
        fi

        # Handle key-value pairs
        if [[ "$line" =~ ^\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*=\s*(.*) ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            # Remove surrounding quotes from value
            value="${value%\"}"; value="${value#\"}"
            
            # CRITICAL: Assign value as a literal string to prevent code injection
            declare "$key"="$value"

            # Robustly handle SSH options by converting the string to an array
            if [[ "$key" == "SSH_OPTS_STR" ]]; then
                read -r -a SSH_OPTS_ARR <<< "$value"
            fi
        fi
    done < "$CONFIG_FILE"
else
    echo "FATAL: Unified configuration file backup.conf not found." >&2; exit 1
fi

# =================================================================
#               SCRIPT CONFIGURATION (STATIC)
# =================================================================
REMOTE_TARGET="${HETZNER_BOX}:${BOX_DIR}"
LOCK_FILE="/tmp/backup_rsync.lock"
MAX_LOG_SIZE=10485760 # 10 MB in bytes

RSYNC_BASE_OPTS=(
    -a -z --delete --partial --timeout=60
    --exclude-from="$EXCLUDE_FILE_TMP"
    -e "ssh ${SSH_OPTS_ARR[@]}"
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
        success) color=3066993 ;;  # Green
        warning) color=16776960 ;; # Yellow
        failure) color=15158332 ;; # Red
        *)       color=9807270 ;;   # Grey
    esac
    local escaped_message; escaped_message=$(echo "$message" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
    local json_payload; printf -v json_payload '{"embeds": [{"title": "%s", "description": "%s", "color": %d, "timestamp": "%s"}]}' \
        "$title" "$escaped_message" "$color" "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
    curl -s --max-time 15 -H "Content-Type: application/json" -d "$json_payload" "$DISCORD_WEBHOOK_URL" > /dev/null 2>> "${LOG_FILE:-/dev/null}"
}

send_notification() {
    local title="$1" tags="$2" priority="$3" status="$4" message="$5"
    send_ntfy "$title" "$tags" "$priority" "$message"
    send_discord "$title" "$status" "$message"
}

run_integrity_check() {
    local rsync_check_opts=(-ainc -c --delete --exclude-from="$EXCLUDE_FILE_TMP" --out-format="%n" -e "ssh ${SSH_OPTS_ARR[@]}")
    LC_ALL=C rsync "${rsync_check_opts[@]}" "$LOCAL_DIR" "$REMOTE_TARGET" 2>> "${LOG_FILE:-/dev/null}"
}

format_backup_stats() {
    local rsync_output="$1"
    local stats_summary=""
    local bytes_transferred=""
    local files_created=""
    local files_deleted=""

    # First, try parsing the machine-readable format from --info=stats2
    bytes_transferred=$(echo "$rsync_output" | grep 'Total_transferred_size:' | awk '{print $2}')
    files_created=$(echo "$rsync_output" | grep 'Number_of_created_files:' | awk '{print $2}')
    files_deleted=$(echo "$rsync_output" | grep 'Number_of_deleted_files:' | awk '{print $2}')

    # If parsing failed, fall back to the human-readable --stats format
    if [[ -z "$bytes_transferred" && -z "$files_created" && -z "$files_deleted" ]]; then
        bytes_transferred=$(echo "$rsync_output" | grep 'Total transferred file size:' | awk '{gsub(/,/, ""); print $5}')
        files_created=$(echo "$rsync_output" | grep 'Number of created files:' | awk '{print $5}')
        files_deleted=$(echo "$rsync_output" | grep 'Number of deleted files:' | awk '{print $5}')
    fi

    if [[ "${bytes_transferred:-0}" -gt 0 ]]; then
        stats_summary=$(printf "Data Transferred: %s" "$(numfmt --to=iec-i --suffix=B --format="%.2f" "$bytes_transferred")")
    else
        stats_summary="Data Transferred: 0 B (No changes)"
    fi
    stats_summary+=$(printf "\nFiles Created: %s\nFiles Deleted: %s" "${files_created:-0}" "${files_deleted:-0}")
    
    echo -e "$stats_summary"
}

cleanup() {
    rm -f "${EXCLUDE_FILE_TMP:-}" "${RSYNC_LOG_TMP:-}"
}

# =================================================================
#               PRE-FLIGHT CHECKS & SETUP
# =================================================================

trap cleanup EXIT
trap 'send_notification "❌ Backup Crashed: ${HOSTNAME}" "x" "high" "failure" "Backup script terminated unexpectedly. Check log: ${LOG_FILE:-/dev/null}"' ERR

REQUIRED_CMDS=(rsync curl flock hostname date stat mv touch awk numfmt grep printf nice ionice sed mktemp)
for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "FATAL: Required command '$cmd' not found. Please install it." >&2; trap - ERR; exit 10
    fi
done

if ! ssh "${SSH_OPTS_ARR[@]}" -o BatchMode=yes -o ConnectTimeout=10 "$HETZNER_BOX" 'exit' 2>/dev/null; then
    send_notification "❌ SSH FAILED: ${HOSTNAME}" "x" "high" "failure" "Unable to SSH into $HETZNER_BOX. Check keys and connectivity."
    trap - ERR; exit 6
fi

if [[ ! -d "$LOCAL_DIR" ]] || [[ "$LOCAL_DIR" != */ ]]; then 
    send_notification "❌ Backup FAILED: ${HOSTNAME}" "x" "high" "failure" "FATAL: LOCAL_DIR must exist and end with a trailing slash ('/')."
    trap - ERR; exit 2
fi


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
            if ! rsync "${RSYNC_BASE_OPTS[@]}" --dry-run --info=progress2 "$LOCAL_DIR" "$REMOTE_TARGET"; then
                echo ""
                echo "❌ Dry run FAILED. See the rsync error message above for details."
                exit 1
            fi
            echo "--- DRY RUN COMPLETED ---"; exit 0 ;;
        --checksum)
            echo "--- INTEGRITY CHECK MODE ACTIVATED ---"
            echo "Comparing checksums... this may take a while."
            FILE_DISCREPANCIES=$(run_integrity_check)
            if [ -z "$FILE_DISCREPANCIES" ]; then
                echo "✅ Checksum validation passed. No discrepancies found."
                log_message "Checksum validation passed. No discrepancies found."
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
