# Automated rsync Backup Script

This script automates backups of local directories to a remote server (such as a Hetzner Storage Box) using `rsync` over SSH.

-----

## Features

- **Unified Configuration**: All settings are in a single `backup.conf` file with secure parsing
- **Portable Setup**: The backup system can be migrated by copying the script and configuration
- **Recycle Bin**: Automatically moves deleted files into a versioned recycle bin on the remote server, with a configurable retention period.
- **Notification Support**: Sends notifications to ntfy and/or Discord, configurable via toggles
- **Error Handling**: Uses strict shell options and traps to detect and report errors
- **Detailed Reports**: Notifications include transfer size and file operation summaries
- **System Friendly**: Uses `nice` and `ionice` to reduce resource impact during backups
- **Multiple Operation Modes**: Supports dry run, checksum verification, summary reports, verbose output, and file restoration
- **Concurrency Control**: Prevents simultaneous runs and handles log rotation automatically
- **Pre-run Validation**: Checks for necessary commands and SSH connectivity before execution

-----

## Usage

#### Download the script and configuration:
  - These are same files as at the bottom of this README.

    ```sh
    # 1. Get the script and make it executable
    wget https://github.com/buildplan/rsync-backup-script/raw/refs/heads/main/backup_script.sh && chmod +x backup_script.sh

    # 2. Get the config file and set secure permissions
    wget https://github.com/buildplan/rsync-backup-script/raw/refs/heads/main/backup.conf && chmod 600 backup.conf
    ```

#### Verify script integrity (optional):

  - To ensure the script is authentic, verify its SHA256 checksum.

    ```sh
    # Download the official checksum file
    wget https://github.com/buildplan/rsync-backup-script/raw/refs/heads/main/backup_script.sh.sha256

    # Run the check (it should output: backup_script.sh: OK)
    sha256sum -c backup_script.sh.sha256
    ```

#### Run modes:

  - `sudo ./backup_script.sh` - Run silently (suitable for cron)
  - `sudo ./backup_script.sh --verbose` - Run with live progress
  - `sudo ./backup_script.sh --dry-run` - Preview changes without applying them
  - `sudo ./backup_script.sh --checksum` - Verify backup integrity
  - `sudo ./backup_script.sh --summary` - Report file differences
  - `sudo ./backup_script.sh --test` - Checks to validate `backup.conf`, permissions and SSH connectivity
  - `sudo ./backup_script.sh --restore` - Interactive restore with dry-run preview and confirmation


> *Default log location: `/var/log/backup_rsync.log`*


#### Diagnostics & Error Codes

The script uses specific exit codes for different pre-flight failures, which can help with debugging automated runs.

  - **Exit Code `1`: Fatal Configuration Error.** A critical issue was found during startup. This can be caused by:
      - The script not being run as `root`.
      - The `backup.conf` file being missing or a required variable not being set.
      - An invalid `RECYCLE_BIN_DIR` setting (e.g., an absolute path).
      - The script being unable to access or create the recycle bin on the remote server.
  - **Exit Code `2`: `BACKUP_DIRS` Error.** An issue with a directory listed in `BACKUP_DIRS` (e.g., it doesn't exist, isn't readable, or is missing the `/./` syntax).
  - **Exit Code `5`: Lock Contention.** Another instance of the script is already running.
  - **Exit Code `6`: SSH Failure.** The pre-flight check failed to establish an SSH connection to the `BOX_ADDR`.
  - **Exit Code `7`: Disk Space Error.** Insufficient local disk space for logging.
  - **Exit Code `10`: Prerequisite Missing.** A required command (like `rsync` or `curl`) is not installed.

-----

## File Structure

All files should be placed in a single directory (e.g., `/home/user/scripts/backup`). The new structure is simpler with only two files to manage.

```
/home/user/scripts/backup/
├── backup_script.sh      (main script)
└── backup.conf           (settings, credentials, and excludes)
```

-----

## Setup Instructions

Follow these steps to get the backup system running.

### 1\. Prerequisites

Ensure the required tools are installed, run:

```sh
# On Debian/Ubuntu
sudo apt-get update && sudo apt-get install rsync curl coreutils util-linux

# On CentOS/RHEL/Fedora
sudo dnf install rsync curl coreutils util-linux
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

  - Add the public key to your Hetzner Storage Box via the control panel. Test the connection (replace `u123456` and `u123456-sub4`):

    ```sh
    sudo ssh -p 23 u123456-sub4@u123456.your-storagebox.de pwd

    # This should work without asking for a password, and show /home in terminal output.
    ```

  - Or use the `ssh-copy-id` command (replace `u123456` and `u123456-sub4`):

    ```sh
    sudo ssh-copy-id -p 23 -s u123456-sub4@u123456.your-storagebox.de

    # Hetzner Storage Box requires the `-s` flag.
    ```

### 3\. Place and Configure Files (If not downloading with `wget` above)

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
5.  Edit `backup.conf` to specify your local paths, remote server details, notification settings, and file exclusions.

### 4\. Set up a Cron Job

To run the backup automatically, edit the root crontab.

  - Open the crontab editor:

    ```sh
    sudo crontab -e
    ```

  - Add a line to schedule the script. This example runs the backup every day at 3:00 AM.

    ```crontab
    # Run the rsync backup every day at 3:00 AM
    0 3 * * * /home/user/scripts/backup/backup_script.sh > /dev/null 2>&1
    ```

    *(Redirecting output to `/dev/null` is fine since the script handles its own logging and notifications).*

    *(Note: `sudo` is not needed here because this command is placed in the root user's crontab via `sudo crontab -e`, so it already runs with root privileges.)*

-----

-----

## The Files

### **`backup.conf`**

```ini
# =================================================================
#         Configuration for rsync Backup Script v0.30
# =================================================================
# !! IMPORTANT !! Set file permissions to 600 (chmod 600 backup.conf)

# --- Source and Destination ---
# List all source directories to back up, separated by spaces.
#
# IMPORTANT: Follow these two rules for each path:
# 1. End the path with a trailing slash (e.g., "user/").
# 2. Use "/./" to mark the part of the path you want to create on the destination.
#    Example: "/home/./user/" will create a "user" directory in your BOX_DIR.
BACKUP_DIRS="/./home/user/ /./var/log/ /./etc/nginx/"

# The root folder on the remote server where backups will be placed.
# IMPORTANT: This path MUST end with a trailing slash (e.g., /backups/).
BOX_DIR="/home/myvps/"

# --- Connection Details ---
# The SSH address of your remote backup server (e.g., user@host).
BOX_ADDR="u444300-sub4@u444300.your-storagebox.de"

# Add each SSH option on a new line.
# For options taking a value, see the rules below.
BEGIN_SSH_OPTS
# Options with simple values (like a port) can be combined.
-p23

# Options that take a file path (like an identity key) MUST be on separate lines.
-i
/root/.ssh/id_ed25519
END_SSH_OPTS

# The timeout in seconds for rsync operations.
RSYNC_TIMEOUT=300

# --- Performance ---
# Optional: Limit rsync's bandwidth usage in KiB/s. Leave empty or set to 0 to disable.
# Example: BANDWIDTH_LIMIT_KBPS=5000  (for 5 MB/s)
BANDWIDTH_LIMIT_KBPS=""

# --- Integrity Check ---
# Set to true to enable slow but thorough checksum-based integrity checks.
# Default is false for fast checks (based on file size and modification time).
CHECKSUM_ENABLED=false

# --- Logging ---
LOG_FILE="/var/log/backup_rsync.log"
# Max log size in Megabytes (MB) before the script rotates it.
MAX_LOG_SIZE_MB=10
# Delete rotated logs older than this many days.
LOG_RETENTION_DAYS=90

# --- Recycle Bin ---
# If enabled, files deleted from the source will be moved to a remote
# recycle bin instead of being permanently removed. This provides a safety net.
RECYCLE_BIN_ENABLED=true
# The name of the directory on the remote server to use as the recycle bin.
RECYCLE_BIN_DIR="recycle_bin"
# The number of days to keep daily backup folders in the recycle bin before deleting them.
RECYCLE_BIN_RETENTION_DAYS=30

# --- Notification Toggles ---
# Set to 'true' to enable, 'false' to disable.
NTFY_ENABLED=true
DISCORD_ENABLED=false

# --- ntfy Credentials ---
NTFY_TOKEN="tk_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
NTFY_URL="https://ntfy.sh/your-private-topic-name"

# --- ntfy Notification Priorities ---
# 5=max/urgent, 4=high, 3=default, 2=low, 1=min
NTFY_PRIORITY_SUCCESS=3
NTFY_PRIORITY_WARNING=4
NTFY_PRIORITY_FAILURE=4

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

# Some common files which can be skipped
.bash_history
.bash_logout
.bashrc
.config/
.docker/
.local/
.profile
.ssh/
.sudo_as_admin_successful
.wget-hsts
END_EXCLUDES
```

-----

### **`backup_script.sh`**

```bash
#!/bin/bash
# ===================== v0.30 - 2025.08.13 ========================
#
# Example backup.conf:
# BACKUP_DIRS="/home/user/test/./ /var/www/./"
# BOX_DIR="/backup/"
# BOX_ADDR="user@storagebox.example.com"
# LOG_FILE="/var/log/backup.log"
# LOG_RETENTION_DAYS=7
# MAX_LOG_SIZE_MB=10
# BANDWIDTH_LIMIT_KBPS=1000
# RSYNC_TIMEOUT=300
# RECYCLE_BIN_ENABLED=true
# RECYCLE_BIN_DIR="recycle_bin"
# RECYCLE_BIN_RETENTION_DAYS=30
# CHECKSUM_ENABLED=false
# NTFY_ENABLED=true
# NTFY_TOKEN="your_token"
# NTFY_URL="https://ntfy.sh/your_topic"
# NTFY_PRIORITY_SUCCESS=3
# NTFY_PRIORITY_WARNING=4
# NTFY_PRIORITY_FAILURE=5
# BEGIN_SSH_OPTS
# -i
# /root/.ssh/id_rsa
# -p22
# END_SSH_OPTS
# BEGIN_EXCLUDES
# *.tmp
# /tmp/
# END_EXCLUDES
#
# =================================================================
#                 SCRIPT INITIALIZATION & SETUP
# =================================================================
set -Euo pipefail
umask 077

HOSTNAME=$(hostname -s)

# --- Color Palette ---
if [ -t 1 ]; then
    C_RESET='\e[0m'
    C_BOLD='\e[1m'
    C_DIM='\e[2m'
    C_RED='\e[0;31m'
    C_GREEN='\e[0;32m'
    C_YELLOW='\e[0;33m'
    C_CYAN='\e[0;36m'
else
    C_RESET=''
    C_BOLD=''
    C_DIM=''
    C_RED=''
    C_GREEN=''
    C_YELLOW=''
    C_CYAN=''
fi

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
SSH_OPTS_ARRAY=()

# --- Securely parse the unified configuration file ---
if [ -f "$CONFIG_FILE" ]; then
    in_exclude_block=false
    in_ssh_opts_block=false
    while IFS= read -r line; do
        # --- Handle block markers ---
        if [[ "$line" == "BEGIN_EXCLUDES" ]]; then in_exclude_block=true; continue; fi
        if [[ "$line" == "END_EXCLUDES" ]]; then in_exclude_block=false; continue; fi
        if [[ "$line" == "BEGIN_SSH_OPTS" ]]; then in_ssh_opts_block=true; continue; fi
        if [[ "$line" == "END_SSH_OPTS" ]]; then in_ssh_opts_block=false; continue; fi

        # --- Process lines within blocks ---
        if [[ "$in_exclude_block" == "true" ]]; then
            [[ ! "$line" =~ ^([[:space:]]*#|[[:space:]]*$) ]] && echo "$line" >> "$EXCLUDE_FILE_TMP"
            continue
        fi
        if [[ "$in_ssh_opts_block" == "true" ]]; then
            [[ ! "$line" =~ ^([[:space:]]*#|[[:space:]]*$) ]] && SSH_OPTS_ARRAY+=("$line")
            continue
        fi

        # --- Process key-value pairs ---
        if [[ "$line" =~ ^[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*=[[:space:]]*(.*) ]]; then
            key="${BASH_REMATCH[1]}"; value="${BASH_REMATCH[2]}"
            value="${value%\"}"; value="${value#\"}"

            case "$key" in
                BACKUP_DIRS|BOX_DIR|BOX_ADDR|LOG_FILE|LOG_RETENTION_DAYS|\
                MAX_LOG_SIZE_MB|BANDWIDTH_LIMIT_KBPS|RSYNC_TIMEOUT|\
                CHECKSUM_ENABLED|\
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
for var in BACKUP_DIRS BOX_DIR BOX_ADDR LOG_FILE \
           NTFY_PRIORITY_SUCCESS NTFY_PRIORITY_WARNING NTFY_PRIORITY_FAILURE \
           LOG_RETENTION_DAYS; do
    if [ -z "${!var:-}" ]; then
        echo "FATAL: Required config variable '$var' is missing or empty in $CONFIG_FILE." >&2
        exit 1
    fi
done
if [[ "$BOX_DIR" != */ ]]; then
    echo "❌ FATAL: BOX_DIR must end with a trailing slash (/). Please check backup.conf." >&2
    exit 2
fi
if [[ "${RECYCLE_BIN_ENABLED:-false}" == "true" ]]; then
    for var in RECYCLE_BIN_DIR RECYCLE_BIN_RETENTION_DAYS; do
        if [ -z "${!var:-}" ]; then
            echo "FATAL: When RECYCLE_BIN_ENABLED is true, '$var' must be set in $CONFIG_FILE." >&2
            exit 1
        fi
    done
    if [[ "${RECYCLE_BIN_DIR}" == /* ]]; then
        echo "❌ FATAL: RECYCLE_BIN_DIR must be a relative path, not absolute: '${RECYCLE_BIN_DIR}'" >&2
        exit 1
    fi
    if [[ "$RECYCLE_BIN_DIR" == *"../"* ]]; then
        echo "❌ FATAL: RECYCLE_BIN_DIR cannot contain '../'" >&2
        exit 1
    fi
fi

# =================================================================
#               SCRIPT CONFIGURATION (STATIC)
# =================================================================

REMOTE_TARGET="${BOX_ADDR}:${BOX_DIR}"
LOCK_FILE="/tmp/backup_rsync.lock"

SSH_CMD="ssh"
if (( ${#SSH_OPTS_ARRAY[@]} > 0 )); then
    SSH_CMD+=$(printf " %q" "${SSH_OPTS_ARRAY[@]}")
fi

RSYNC_BASE_OPTS=(
    -aR -z --delete --partial --timeout="${RSYNC_TIMEOUT:-300}" --mkpath --noatime
    --exclude-from="$EXCLUDE_FILE_TMP"
    -e "$SSH_CMD"
)

# Optional: Add bandwidth limit if configured
if [[ -n "${BANDWIDTH_LIMIT_KBPS:-}" && "${BANDWIDTH_LIMIT_KBPS}" -gt 0 ]]; then
    RSYNC_BASE_OPTS+=(--bwlimit="$BANDWIDTH_LIMIT_KBPS")
fi

# Shared options for direct, non-interactive SSH commands
SSH_DIRECT_OPTS=(
    -o StrictHostKeyChecking=no
    -o BatchMode=yes
    -o ConnectTimeout=30
    -n
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
    local escaped_title; escaped_title=$(echo "$title" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g')
    local escaped_message; escaped_message=$(echo "$message" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
    local json_payload; printf -v json_payload '{"embeds": [{"title": "%s", "description": "%s", "color": %d, "timestamp": "%s"}]}' \
        "$escaped_title" "$escaped_message" "$color" "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
    curl -s --max-time 15 -H "Content-Type: application/json" -d "$json_payload" "$DISCORD_WEBHOOK_URL" > /dev/null 2>> "${LOG_FILE:-/dev/null}"
}
send_notification() {
    local title="$1" tags="$2" ntfy_priority="$3" discord_status="$4" message="$5"
    send_ntfy "$title" "$tags" "$ntfy_priority" "$message"
    send_discord "$title" "$discord_status" "$message"
}
run_integrity_check() {
    local rsync_check_opts=(-aincR --delete --mkpath --exclude-from="$EXCLUDE_FILE_TMP" --out-format="%n" -e "$SSH_CMD")
    if [[ "${CHECKSUM_ENABLED:-false}" == "true" ]]; then
        rsync_check_opts+=(-c)
    fi
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
    if [[ -z "$bytes_transferred" && -z "$files_transferred" ]]; then
        log_message "WARNING: Unable to parse rsync stats. Output format may be incompatible."
        printf "Data Transferred: Unknown\nFiles Updated: Unknown\nFiles Created: Unknown\nFiles Deleted: Unknown\n"
        return 0
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
    if [[ "$test_mode" == "true" ]]; then printf "${C_BOLD}--- Checking required commands...${C_RESET}\n"; fi
    for cmd in "${REQUIRED_CMDS[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then echo "❌ FATAL: Required command '$cmd' not found." >&2; check_failed=true; fi
    done
    if [[ "$check_failed" == "true" ]]; then exit 10; fi
    if [[ "$test_mode" == "true" ]]; then printf "${C_GREEN}✅ All required commands are present.${C_RESET}\n"; fi
    if [[ "$test_mode" == "true" ]]; then printf "${C_BOLD}--- Checking SSH connectivity...${C_RESET}\n"; fi
    # Quick preflight connectivity "ping": short 10s timeout for fail-fast behaviour
    if ! ssh "${SSH_OPTS_ARRAY[@]}" -o BatchMode=yes -o ConnectTimeout=10 "$BOX_ADDR" 'exit' 2>/dev/null; then
        local err_msg="Unable to SSH into $BOX_ADDR. Check keys and connectivity."
        if [[ "$test_mode" == "true" ]]; then echo "❌ $err_msg"; else send_notification "❌ SSH FAILED: ${HOSTNAME}" "x" "${NTFY_PRIORITY_FAILURE}" "failure" "$err_msg"; fi; exit 6
    fi
    if [[ "$test_mode" == "true" ]]; then printf "${C_GREEN}✅ SSH connectivity OK.${C_RESET}\n"; fi
    if [[ "${RECYCLE_BIN_ENABLED:-false}" == "true" ]]; then
        local remote_recycle_path="${BOX_DIR}${RECYCLE_BIN_DIR}"
        if ! ssh "${SSH_OPTS_ARRAY[@]}" -o BatchMode=yes -o ConnectTimeout=10 "$BOX_ADDR" "ls -d \"$remote_recycle_path\"" >/dev/null 2>&1; then
            if ! ssh "${SSH_OPTS_ARRAY[@]}" -o BatchMode=yes -o ConnectTimeout=10 "$BOX_ADDR" "mkdir -p \"$remote_recycle_path\"" >/dev/null 2>&1; then
                echo "❌ FATAL: Cannot access or create recycle bin directory '$remote_recycle_path' on remote." >&2
                exit 1
            fi
        fi
    fi
    if [[ "$mode" != "restore" ]]; then
        if [[ "$test_mode" == "true" ]]; then printf "${C_BOLD}--- Checking backup directories...${C_RESET}\n"; fi
        local DIRS_ARRAY; read -ra DIRS_ARRAY <<< "$BACKUP_DIRS"
        for dir in "${DIRS_ARRAY[@]}"; do
            if [[ ! -d "$dir" ]] || [[ "$dir" != */ ]]; then
                local err_msg="A directory in BACKUP_DIRS ('$dir') must exist and end with a trailing slash ('/')."
                if [[ "$test_mode" == "true" ]]; then echo "❌ FATAL: $err_msg"; else send_notification "❌ Backup FAILED: ${HOSTNAME}" "x" "${NTFY_PRIORITY_FAILURE}" "failure" "FATAL: $err_msg"; fi; exit 2
            fi
            if [[ "$dir" != *"/./"* ]]; then
                local err_msg="Directory '$dir' in BACKUP_DIRS is missing the required '/./' syntax."
                if [[ "$test_mode" == "true" ]]; then 
                    echo "❌ FATAL: $err_msg"
                else
                    send_notification "❌ Backup FAILED: ${HOSTNAME}" "x" "${NTFY_PRIORITY_FAILURE}" "failure" "FATAL: $err_msg"
                fi
                exit 2
            fi
            if [[ ! -r "$dir" ]]; then
                local err_msg="A directory in BACKUP_DIRS ('$dir') is not readable."
                if [[ "$test_mode" == "true" ]]; then echo "❌ FATAL: $err_msg"; else send_notification "❌ Backup FAILED: ${HOSTNAME}" "x" "${NTFY_PRIORITY_FAILURE}" "failure" "FATAL: $err_msg"; fi; exit 2
            fi
        done
        if [[ "$test_mode" == "true" ]]; then printf "${C_GREEN}✅ All backup directories are valid.${C_RESET}\n"; fi
        if [[ "$test_mode" == "true" ]]; then printf "${C_BOLD}--- Checking local disk space...${C_RESET}\n"; fi
        local required_space_kb=102400
        local available_space_kb
        available_space_kb=$(df --output=avail "$(dirname "${LOG_FILE}")" | tail -n1)
        if [[ "$available_space_kb" -lt "$required_space_kb" ]]; then
            local err_msg="Insufficient disk space in $(dirname "${LOG_FILE}") to guarantee logging. ($((available_space_kb / 1024))MB available)"
            if [[ "$test_mode" == "true" ]]; then echo "❌ FATAL: $err_msg"; else send_notification "❌ Backup FAILED: ${HOSTNAME}" "x" "${NTFY_PRIORITY_FAILURE}" "failure" "FATAL: $err_msg"; fi
            exit 7
        fi
        if [[ "$test_mode" == "true" ]]; then printf "${C_GREEN}✅ Local disk space OK.${C_RESET}\n"; fi
    fi
}
run_restore_mode() {
    printf "${C_BOLD}${C_CYAN}--- RESTORE MODE ACTIVATED ---${C_RESET}\n"
    run_preflight_checks "restore"
    local DIRS_ARRAY; read -ra DIRS_ARRAY <<< "$BACKUP_DIRS"
    local RECYCLE_OPTION="[ Restore from Recycle Bin ]"
    local all_options=("${DIRS_ARRAY[@]}")
    if [[ "${RECYCLE_BIN_ENABLED:-false}" == "true" ]]; then
        all_options+=("$RECYCLE_OPTION")
    fi
    all_options+=("Cancel")
    printf "${C_YELLOW}Available backup sets to restore from:${C_RESET}\n"
    select dir_choice in "${all_options[@]}"; do
        if [[ -n "$dir_choice" ]]; then break;
        else echo "Invalid selection. Please try again."; fi
    done
    local full_remote_source=""
    local default_local_dest=""
    local item_for_display=""
    local restore_path=""
    local is_full_directory_restore=false
    if [[ "$dir_choice" == "$RECYCLE_OPTION" ]]; then
        printf "${C_BOLD}${C_CYAN}--- Browse Recycle Bin ---${C_RESET}\n"
        local remote_recycle_path="${BOX_DIR%/}/${RECYCLE_BIN_DIR%/}"
        local date_folders
        date_folders=$(ssh "${SSH_OPTS_ARRAY[@]}" "${SSH_DIRECT_OPTS[@]}" "$BOX_ADDR" "ls -1 \"$remote_recycle_path\"" 2>/dev/null) || true
        if [[ -z "$date_folders" ]]; then
            echo "❌ No dated folders found in the recycle bin. Nothing to restore." >&2
            return 1
        fi
        printf "${C_YELLOW}Select a backup run (date_time) to browse:${C_RESET}\n"
        select date_choice in $date_folders "Cancel"; do
            if [[ "$date_choice" == "Cancel" ]]; then echo "Restore cancelled."; return 0;
            elif [[ -n "$date_choice" ]]; then break;
            else echo "Invalid selection. Please try again."; fi
        done
        local remote_date_path="${remote_recycle_path}/${date_choice}"
        printf "${C_BOLD}--- Files available from ${date_choice} (showing first 20) ---${C_RESET}\n"
        local remote_listing_source="${BOX_ADDR}:${remote_date_path}/"
        rsync -r -n --out-format='%n' -e "$SSH_CMD" "$remote_listing_source" . 2>/dev/null | head -n 20 || echo "No files found for this date."
        printf "${C_BOLD}--------------------------------------------------------${C_RESET}\n"
        printf "${C_YELLOW}Enter the full original path of the item to restore (e.g., home/user/file.txt): ${C_RESET}"
        read -r specific_path
        specific_path=$(echo "$specific_path" | sed 's#^/##')
        if [[ -z "$specific_path" ]]; then echo "❌ Path cannot be empty. Aborting."; return 1; fi
        full_remote_source="${BOX_ADDR}:${remote_date_path}/${specific_path}"
        if ! rsync -r -n -e "$SSH_CMD" "$full_remote_source" . >/dev/null 2>&1; then
            echo "❌ ERROR: The path '${specific_path}' was not found in the recycle bin for ${date_choice}. Aborting." >&2
            return 1
        fi
        default_local_dest="/${specific_path}"
        item_for_display="(from Recycle Bin) '${specific_path}'"
    elif [[ "$dir_choice" == "Cancel" ]]; then
        echo "Restore cancelled."
        return 0
    else
        item_for_display="the entire directory '${dir_choice}'"
        while true; do
            printf "\n${C_YELLOW}Restore the entire directory or a specific file/subfolder? [entire/specific]: ${C_RESET}"
            read -r choice
            case "$choice" in
                entire)
                    is_full_directory_restore=true
                    break
                    ;;
                specific)
                    local specific_path_prompt
                    printf -v specific_path_prompt "Enter the path relative to '%s' to restore: " "$dir_choice"                    
                    printf "${C_YELLOW}%s${C_RESET}" "$specific_path_prompt"
                    read -er specific_path
                    specific_path=$(echo "$specific_path" | sed 's#^/##')
                    if [[ -n "$specific_path" ]]; then
                        restore_path="$specific_path"
                        item_for_display="'$restore_path' from '${dir_choice}'"
                        break
                    else
                        echo "Path cannot be empty. Please try again or choose 'entire'."
                    fi
                    ;;
                *) echo "Invalid choice. Please answer 'entire' or 'specific'." ;;
            esac
        done
        local relative_path="${dir_choice#*./}"
        full_remote_source="${REMOTE_TARGET}${relative_path}${restore_path}"
        if [[ -n "$restore_path" ]]; then
            default_local_dest=$(echo "${dir_choice}${restore_path}" | sed 's#/\./#/#')
        else
            default_local_dest=$(echo "$dir_choice" | sed 's#/\./#/#')
        fi
    fi
    local final_dest    
    printf "\n${C_YELLOW}Enter the destination path.\n${C_DIM}Press [Enter] to use the original location (%s):${C_RESET} " "$default_local_dest"
    read -r final_dest
    : "${final_dest:=$default_local_dest}"
    local extra_rsync_opts=()
    local dest_user=""
    if [[ "$final_dest" == /home/* ]]; then
        dest_user=$(echo "$final_dest" | cut -d/ -f3)
        if [[ -n "$dest_user" ]] && id -u "$dest_user" &>/dev/null; then
            printf "${C_CYAN}ℹ️  Home directory detected. Restored files will be owned by '${dest_user}'.${C_RESET}\n"
            extra_rsync_opts+=("--chown=${dest_user}:${dest_user}")
        else
            dest_user=""
        fi
    fi
    local dest_created=false
    if [[ ! -e "$final_dest" ]]; then
        dest_created=true
    fi
    local dest_parent
    dest_parent=$(dirname "$final_dest")
    if ! mkdir -p "$dest_parent"; then
        echo "❌ FATAL: Could not create parent destination directory '$dest_parent'. Aborting." >&2
        return 1
    fi
    if [[ -n "$dest_user" ]]; then
        chown "${dest_user}:${dest_user}" "$dest_parent"
    fi
    if [[ "$final_dest" != "$default_local_dest" && -d "$final_dest" && -z "$restore_path" ]]; then
        local warning_msg="⚠️ WARNING: The custom destination directory '$final_dest' already exists. Files may be overwritten."
        echo "$warning_msg"; log_message "$warning_msg"
    fi
    if [[ "$dest_created" == "true" && "${is_full_directory_restore:-false}" == "true" ]]; then
        chmod 700 "$final_dest"; log_message "Set permissions to 700 on newly created restore directory: $final_dest"
    fi
    printf "Restore destination is set to: ${C_BOLD}%s${C_RESET}\n" "$final_dest"
    printf "\n${C_BOLD}${C_YELLOW}--- PERFORMING DRY RUN. NO FILES WILL BE CHANGED. ---${C_RESET}\n"
    log_message "Starting restore dry-run of ${item_for_display} from ${full_remote_source} to ${final_dest}"
    local rsync_restore_opts=(-avhi --progress --exclude-from="$EXCLUDE_FILE_TMP" -e "$SSH_CMD")
    if ! rsync "${rsync_restore_opts[@]}" "${extra_rsync_opts[@]}" --dry-run "$full_remote_source" "$final_dest"; then
        echo "❌ DRY RUN FAILED. Rsync reported an error. Aborting." >&2; return 1
    fi
    printf "${C_BOLD}${C_GREEN}--- DRY RUN COMPLETE ---${C_RESET}\n"
    local confirmation
    while true; do
        printf "\n${C_YELLOW}Are you sure you want to proceed with restoring %s to '%s'? [yes/no]: ${C_RESET}" "$item_for_display" "$final_dest"
        read -r confirmation
        
        case "$confirmation" in
            yes) break ;;
            no) echo "Restore aborted by user." ; return 0 ;;
            *) echo "Please answer yes or no." ;;
        esac
    done
    printf "\n${C_BOLD}--- PROCEEDING WITH RESTORE... ---${C_RESET}\n"
    log_message "Starting REAL restore of ${item_for_display} from ${full_remote_source} to ${final_dest}"
    if rsync "${rsync_restore_opts[@]}" "${extra_rsync_opts[@]}" "$full_remote_source" "$final_dest"; then
        log_message "Restore completed successfully."
        printf "${C_GREEN}✅ Restore of %s to '%s' completed successfully.${C_RESET}\n" "$item_for_display" "$final_dest"
        send_notification "✅ Restore SUCCESS: ${HOSTNAME}" "white_check_mark" "${NTFY_PRIORITY_SUCCESS}" "success" "Successfully restored ${item_for_display} to ${final_dest}"
    else
        log_message "Restore FAILED with rsync exit code $?."
        printf "${C_RED}❌ Restore FAILED. Check the rsync output and log for details.${C_RESET}\n"
        send_notification "❌ Restore FAILED: ${HOSTNAME}" "x" "${NTFY_PRIORITY_FAILURE}" "failure" "Restore of ${item_for_display} to ${final_dest} failed."
        return 1
    fi
}
run_recycle_bin_cleanup() {
    if [[ "${RECYCLE_BIN_ENABLED:-false}" != "true" ]]; then return 0; fi
    log_message "Checking remote recycle bin..."
    local remote_cleanup_path="${BOX_DIR%/}/${RECYCLE_BIN_DIR%/}"
    local list_command="ls -1 \"$remote_cleanup_path\""
    local all_folders
    all_folders=$(ssh "${SSH_OPTS_ARRAY[@]}" "${SSH_DIRECT_OPTS[@]}" "$BOX_ADDR" "$list_command" 2>> "${LOG_FILE:-/dev/null}") || {
        log_message "Recycle bin not found or unable to list contents. Nothing to clean."
        return 0
    }
    if [[ -z "$all_folders" ]]; then
        log_message "No daily folders in recycle bin to check."
        return 0
    fi
    log_message "Checking for folders older than ${RECYCLE_BIN_RETENTION_DAYS} days..."
    local folders_to_delete=""
    local retention_days=${RECYCLE_BIN_RETENTION_DAYS}
    local threshold_timestamp
    threshold_timestamp=$(date -d "$retention_days days ago" +%s)
    while IFS= read -r folder; do
        local folder_date=${folder%%_*}
        if folder_timestamp=$(date -d "$folder_date" +%s 2>/dev/null) && [[ -n "$folder_timestamp" ]]; then
            if (( folder_timestamp < threshold_timestamp )); then
                folders_to_delete+="${folder}"$'\n'
            fi
        fi
    done <<< "$all_folders"
    if [[ -n "$folders_to_delete" ]]; then
        log_message "Removing old recycle bin folders:"
        local empty_dir
        empty_dir=$(mktemp -d)
        while IFS= read -r folder; do
            if [[ -n "$folder" ]]; then
                log_message "  Deleting: $folder"
                local remote_dir_to_delete="${remote_cleanup_path}/${folder}/"
                rsync -a --delete -e "$SSH_CMD" "$empty_dir/" "${BOX_ADDR}:${remote_dir_to_delete}" >/dev/null 2>> "${LOG_FILE:-/dev/null}"
                ssh "${SSH_OPTS_ARRAY[@]}" "${SSH_DIRECT_OPTS[@]}" "$BOX_ADDR" "rmdir \"$remote_dir_to_delete\"" 2>> "${LOG_FILE:-/dev/null}"
            fi
        done <<< "$folders_to_delete"

        rm -rf "$empty_dir"
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
                    backup_dir="${BOX_DIR%/}/${RECYCLE_BIN_DIR%/}/$(date +%F_%H%M%S)/"
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

# --- Log Rotation ---
# Use default of 10MB if not set in config
max_log_size_bytes=$(( ${MAX_LOG_SIZE_MB:-10} * 1024 * 1024 ))
if [ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE")" -gt "$max_log_size_bytes" ]; then
    mv "$LOG_FILE" "${LOG_FILE}.$(date +%Y%m%d_%H%M%S)"
    touch "$LOG_FILE"
    find "$(dirname "$LOG_FILE")" -name "$(basename "$LOG_FILE").*" -type f -mtime +"$LOG_RETENTION_DAYS" -delete
fi

log_message "Flushing filesystem buffers to disk..."
sync

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
        backup_dir="${BOX_DIR%/}/${RECYCLE_BIN_DIR%/}/$(date +%F_%H%M%S)/"
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
    if [[ $RSYNC_EXIT_CODE -eq 0 || $RSYNC_EXIT_CODE -eq 24 || $RSYNC_EXIT_CODE -eq 23 ]]; then
        success_dirs+=("$(basename "$dir")")
        if [[ $RSYNC_EXIT_CODE -eq 24 || $RSYNC_EXIT_CODE -eq 23 ]]; then
            log_message "WARNING for $dir: rsync completed with code $RSYNC_EXIT_CODE."; overall_exit_code=24
        fi
    else
        failed_dirs+=("$(basename "$dir")")
        log_message "FAILED for $dir: rsync exited with code: $RSYNC_EXIT_CODE."; overall_exit_code=1
    fi
done

run_recycle_bin_cleanup

END_TIME=$(date +%s); DURATION=$((END_TIME - START_TIME)); trap - ERR

BACKUP_STATS=$(format_backup_stats "$full_rsync_output")
FINAL_MESSAGE=$(printf "%s\n\nSuccessful: %s\nFailed: %s\n\nDuration: %dm %ds" \
    "$BACKUP_STATS" \
    "${success_dirs[*]:-None}" \
    "${failed_dirs[*]:-None}" \
    $((DURATION / 60)) $((DURATION % 60)))

if [[ ${#FINAL_MESSAGE} -gt 1800 ]]; then
    FINAL_MESSAGE=$(printf "%.1800s\n\n[Message truncated, see %s for full details]" "$FINAL_MESSAGE" "$LOG_FILE")
fi

if [[ ${#failed_dirs[@]} -eq 0 ]]; then
    log_message "SUCCESS: All backups completed."
    if [[ $overall_exit_code -eq 24 ]]; then
        send_notification "⚠️ Backup Warning: ${HOSTNAME}" "warning" "${NTFY_PRIORITY_WARNING}" "warning" "One or more directories completed with warnings.\n\n$FINAL_MESSAGE"
    else
        send_notification "✅ Backup SUCCESS: ${HOSTNAME}" "white_check_mark" "${NTFY_PRIORITY_SUCCESS}" "success" "$FINAL_MESSAGE"
    fi
else
    log_message "FAILURE: One or more backups failed."; send_notification "❌ Backup FAILED: ${HOSTNAME}" "x" "${NTFY_PRIORITY_FAILURE}" "failure" "$FINAL_MESSAGE"
fi

echo "======================= Run Finished =======================" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"
```
