# Automated rsync Backup Script

This script is for automating backups of a local directory to a remote server (like a Hetzner Storage Box) using `rsync` over SSH.

---

## Features

- **External Configuration**: All settings (paths, hosts) and credentials (API tokens) are stored in separate files, not in the script.
- **Portable**: The entire backup setup (script + configs) can be moved to a new server by copying one directory.
- **ntfy Notifications**: Sends detailed success or failure notifications to a specified ntfy topic.
- **Robust Error Handling**: Uses `set -Euo pipefail` and a global `ERR` trap to catch and report any unexpected errors.
- **Locking**: Prevents multiple instances from running simultaneously using `flock`. Essential for cron jobs.
- **Log Rotation**: Automatically rotates the log file when it exceeds a defined size.
- **Special Modes**: Includes modes for `--dry-run`, integrity checking (`--checksum`), and getting a quick summary (`--summary`).
- **Prerequisite Checks**: Verifies that all required commands and SSH connectivity are working before running.

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
#                 SCRIPT INITIALIZATION & SETUP
# =================================================================
set -Euo pipefail
umask 077

# --- Determine script's location to load local config files ---
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)

# --- Source Configuration Files ---
# Non-sensitive settings from the script's directory
if [ -f "${SCRIPT_DIR}/backup_rsync.conf" ]; then
    source "${SCRIPT_DIR}/backup_rsync.conf"
else
    echo "FATAL: Main configuration file backup_rsync.conf not found in ${SCRIPT_DIR}." >&2
    exit 1
fi
# Sensitive credentials from the script's directory
if [ -f "${SCRIPT_DIR}/credentials.conf" ]; then
    source "${SCRIPT_DIR}/credentials.conf"
else
    echo "FATAL: Credentials file credentials.conf not found in ${SCRIPT_DIR}." >&2
    exit 1
fi


# =================================================================
#               SCRIPT CONFIGURATION (STATIC)
# =================================================================
# These values are less likely to change or are derived from config
REMOTE_TARGET="${HETZNER_BOX}:${BOX_DIR}"
LOCK_FILE="/tmp/backup_rsync.lock"
MAX_LOG_SIZE=10485760 # 10 MB in bytes

RSYNC_OPTS=(
    -avz
    --stats
    --delete
    --partial
    --timeout=60
    --exclude-from="$EXCLUDE_FROM"
    -e "ssh -p $SSH_PORT"
)

# =================================================================
#                       HELPER FUNCTIONS
# =================================================================

send_ntfy() {
    local title="$1"
    local tags="$2"
    local priority="${3:-default}"
    local message="$4"
    # Check for token and URL to prevent curl errors
    if [ -z "${NTFY_TOKEN:-}" ] || [ -z "${NTFY_URL:-}" ]; then return; fi
    curl -s -u ":$NTFY_TOKEN" \
        -H "Title: ${title}" \
        -H "Tags: ${tags}" \
        -H "Priority: ${priority}" \
        -d "$message" \
        "$NTFY_URL" > /dev/null 2>> "$LOG_FILE"
}

run_integrity_check() {
    local rsync_check_opts=(
        -ainc
        --delete
        --exclude-from="$EXCLUDE_FROM"
        --out-format="%n"
        -e "ssh -p $SSH_PORT"
    )
    LC_ALL=C rsync "${rsync_check_opts[@]}" "$LOCAL_DIR" "$REMOTE_TARGET" 2>> "$LOG_FILE"
}

format_backup_stats() {
    local rsync_output="$1"
    local bytes
    bytes=$(echo "$rsync_output" | grep 'Total transferred file size' | awk '{gsub(/,/, ""); print $5}')

    if [[ "$bytes" =~ ^[0-9]+$ && "$bytes" -gt 0 ]]; then
        printf "Data Transferred: %s" "$(numfmt --to=iec-i --suffix=B --format="%.2f" "$bytes")"
    else
        printf "Data Transferred: 0 B (No changes)"
    fi
}

# =================================================================
#                    PRE-FLIGHT CHECKS & SETUP
# =================================================================

trap 'send_ntfy "❌ Backup Crashed: ${HOSTNAME}" "x" "high" "Backup script terminated unexpectedly. Check log: ${LOG_FILE}"' ERR

REQUIRED_CMDS=(rsync curl flock hostname date stat mv touch awk numfmt grep)
for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "FATAL: Required command '$cmd' not found. Please install it." >&2
        trap - ERR
        exit 10
    fi
done

if ! ssh -p "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout=10 "$HETZNER_BOX" 'exit' 2>/dev/null; then
    send_ntfy "❌ SSH FAILED: ${HOSTNAME}" "x" "high" "Unable to SSH into $HETZNER_BOX. Check keys and connectivity."
    trap - ERR
    exit 6
fi

if ! [ -f "$EXCLUDE_FROM" ]; then
    send_ntfy "❌ Backup FAILED: ${HOSTNAME}" "x" "high" "FATAL: Exclude file not found at $EXCLUDE_FROM"
    trap - ERR
    exit 3
fi
if [[ "$LOCAL_DIR" != */ ]]; then
    send_ntfy "❌ Backup FAILED: ${HOSTNAME}" "x" "high" "FATAL: LOCAL_DIR must end with a trailing slash ('/')"
    trap - ERR
    exit 2
fi

# =================================================================
#                       SCRIPT EXECUTION
# =================================================================

HOSTNAME=$(hostname -s)

if [[ "${1:-}" ]]; then
    trap - ERR
    case "${1}" in
        --dry-run)
            echo "--- DRY RUN MODE ACTIVATED ---"
            rsync "${RSYNC_OPTS[@]}" --dry-run "$LOCAL_DIR" "$REMOTE_TARGET"
            echo "--- DRY RUN COMPLETED ---"
            exit 0
            ;;
        --checksum)
            echo "--- INTEGRITY CHECK MODE ACTIVATED ---"
            FILE_DISCREPANCIES=$(run_integrity_check)
            if [ -z "$FILE_DISCREPANCIES" ]; then
                send_ntfy "✅ Backup Integrity OK: ${HOSTNAME}" "white_check_mark" "default" "Checksum validation passed. No discrepancies found."
            else
                ISSUE_LIST=$(echo "${FILE_DISCREPANCIES}" | head -n 10)
                printf -v FAILURE_MSG "Backup integrity check FAILED.\n\nFirst 10 differing files:\n%s\n\nCheck log for full details." "${ISSUE_LIST}"
                send_ntfy "❌ Backup Integrity FAILED: ${HOSTNAME}" "x" "high" "${FAILURE_MSG}"
            fi
            exit 0
            ;;
        --summary)
            echo "--- INTEGRITY SUMMARY MODE ---"
            MISMATCH_COUNT=$(run_integrity_check | wc -l)
            printf "🚨 Total files with checksum mismatches: %d\n" "$MISMATCH_COUNT"
            exit 0
            ;;
    esac
fi

exec 200>"$LOCK_FILE"
flock -n 200 || { echo "Another instance is running, exiting."; exit 5; }

if [ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE")" -gt "$MAX_LOG_SIZE" ]; then
    mv "$LOG_FILE" "${LOG_FILE}.$(date +%Y%m%d_%H%M%S)"
    touch "$LOG_FILE"
fi

echo "============================================================" >> "$LOG_FILE"
echo "[$HOSTNAME] [$(date '+%Y-%m-%d %H:%M:%S')] Starting rsync backup" >> "$LOG_FILE"

# --- Execute Backup & Capture Output ---
RSYNC_OUTPUT=$(rsync "${RSYNC_OPTS[@]}" "$LOCAL_DIR" "$REMOTE_TARGET" 2>&1)
RSYNC_EXIT_CODE=$?

# Log the full output from the command
echo "$RSYNC_OUTPUT" >> "$LOG_FILE"

if [ $RSYNC_EXIT_CODE -eq 0 ]; then
    trap - ERR
    echo "[$HOSTNAME] [$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS: rsync completed." >> "$LOG_FILE"
    BACKUP_STATS=$(format_backup_stats "$RSYNC_OUTPUT")
    printf -v SUCCESS_MSG "rsync backup completed successfully.\n\n%s" "${BACKUP_STATS}"
    send_ntfy "✅ Backup SUCCESS: ${HOSTNAME}" "white_check_mark" "default" "${SUCCESS_MSG}"
else
    EXIT_CODE=$RSYNC_EXIT_CODE
    trap - ERR
    echo "[$HOSTNAME] [$(date '+%Y-%m-%d %H:%M:%S')] FAILED: rsync exited with code: $EXIT_CODE." >> "$LOG_FILE"
    send_ntfy "❌ Backup FAILED: ${HOSTNAME}" "x" "high" "rsync failed on ${HOSTNAME} with exit code ${EXIT_CODE}. Check log for details."
fi

echo "======================= Run Finished =======================" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"

````

-----

### **`backup_rsync.conf`**

```bash
# Configuration for the rsync backup script

# --- Source and Destination ---
# IMPORTANT: LOCAL_DIR must end with a trailing slash!
LOCAL_DIR="/home/user/"

# Directory on the remote storage box
BOX_DIR="/home/myvps/"

# Hetzner Storage Box details (username and hostname)
HETZNER_BOX="u444300-sub4@u444300.your-storagebox.de"
SSH_PORT="23"

# --- Logging ---
LOG_FILE="/var/log/backup_rsync.log"

# --- Exclude File ---
# This line uses the SCRIPT_DIR variable from the main script
# to locate rsync_exclude.txt in the same directory.
EXCLUDE_FROM="${SCRIPT_DIR}/rsync_exclude.txt"

```

-----

### **`credentials.conf`**

```ini
# Sensitive information for the backup script
# !! IMPORTANT !! Set permissions to 600: chmod 600 credentials.conf

NTFY_TOKEN="tk_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
NTFY_URL="https://ntfy.sh/your-private-topic-name"

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
