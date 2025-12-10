#!/bin/bash

# R2 Backup Script with zstd compression and rotation

set -euo pipefail

# Install dep

sudo apt update -y && sudo apt install zstd tar jq awscli -y

# Load environment variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "Error: .env file not found at $ENV_FILE"
    exit 1
fi

source "$ENV_FILE"

# Configuration variables (can be overridden in .env)
ZSTD_LEVEL="${ZSTD_LEVEL:-3}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"
BACKUP_HOUR="${BACKUP_HOUR:-4}"
BACKUP_MINUTE="${BACKUP_MINUTE:-20}"
LOG_FILE="${LOG_FILE:-/var/log/r2-backup.log}"
TEMP_DIR="${TEMP_DIR:-/tmp/r2-backup}"
R2_REGION="${R2_REGION:-auto}"
USE_ZSTD="${USE_ZSTD:-true}"
BACKUP_NAME_RAW="${BACKUP_NAME:-}"
if [[ -z "$BACKUP_NAME_RAW" ]]; then
    BACKUP_NAME_RAW="$(hostname)"
fi
BACKUP_NAME=$(echo "$BACKUP_NAME_RAW" | xargs)
if [[ -z "$BACKUP_NAME" ]]; then
    BACKUP_NAME="$(hostname)"
fi
BACKUP_NAME="${BACKUP_NAME// /_}"

# Normalize compression toggle to boolean
USE_ZSTD_NORMALIZED=$(echo "$USE_ZSTD" | tr '[:upper:]' '[:lower:]')
USE_ZSTD_ENABLED=true
case "$USE_ZSTD_NORMALIZED" in
    false|0|no|off)
        USE_ZSTD_ENABLED=false
        ;;
    *)
        USE_ZSTD_ENABLED=true
        ;;
esac

# Required R2 variables
required_vars=("R2_ENDPOINT" "R2_ACCESS_KEY_ID" "R2_SECRET_ACCESS_KEY" "R2_BUCKET_NAME")
for var in "${required_vars[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        echo "Error: Variable $var is not set in the .env file"
        exit 1
    fi
done

# Check for the backup paths variable
if [[ -z "${BACKUP_PATHS:-}" ]]; then
    echo "Error: Variable BACKUP_PATHS is not set in the .env file"
    echo "Example: BACKUP_PATHS='/home/user/documents,/var/www,/etc/nginx'"
    exit 1
fi

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE" >&2
}

# Function to check dependencies
check_dependencies() {
    local deps=("aws" "tar" "jq")
    if [[ "$USE_ZSTD_ENABLED" == "true" ]]; then
        deps=("zstd" "${deps[@]}")
    fi
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            log "Error: $dep is not installed"
            exit 1
        fi
    done
}

# Function to create temporary directory
create_temp_dir() {
    if [[ -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
    mkdir -p "$TEMP_DIR"
}

# Cleanup function
cleanup() {
    if [[ -d "$TEMP_DIR" ]]; then
        log "Cleaning up temporary directory: $TEMP_DIR"
        rm -rf "$TEMP_DIR"
    fi
}

# Function to create an archive (tar or tar.zst based on USE_ZSTD)
create_backup_archive() {
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local archive_ext="tar"
    if [[ "$USE_ZSTD_ENABLED" == "true" ]]; then
        archive_ext="tar.zst"
    fi
    local archive_name="${BACKUP_NAME}_${timestamp}.${archive_ext}"
    local archive_path="${TEMP_DIR}/${archive_name}"
    local compression_label="without compression (plain tar)"
    if [[ "$USE_ZSTD_ENABLED" == "true" ]]; then
        compression_label="with zstd compression level $ZSTD_LEVEL"
    fi
    
    log "Creating archive: $archive_name (${compression_label})"
    
    # Convert the paths string to an array
    IFS=',' read -ra PATHS <<< "$BACKUP_PATHS"
    
    # Check if paths exist
    local valid_paths=()
    for path in "${PATHS[@]}"; do
        path=$(echo "$path" | xargs) # Trim whitespace
        if [[ -e "$path" ]]; then
            valid_paths+=("$path")
            log "Adding to backup: $path"
        else
            log "Warning: Path does not exist: $path"
        fi
    done
    
    if [[ ${#valid_paths[@]} -eq 0 ]]; then
        log "Error: No valid paths to back up"
        return 1
    fi
    
    # Create an archive (optionally compressed with zstd)
    if [[ "$USE_ZSTD_ENABLED" == "true" ]]; then
        log "Executing command: tar + zstd with compression level $ZSTD_LEVEL and multithreading"
        tar -cf - "${valid_paths[@]}" 2>/dev/null | zstd -$ZSTD_LEVEL -T0 -o "$archive_path"
    else
        log "Executing command: tar without compression"
        tar -cf "$archive_path" "${valid_paths[@]}" 2>/dev/null
    fi
    
    # Check if archive was created successfully by verifying file existence and size
    if [[ -f "$archive_path" ]]; then
        local size=$(du -h "$archive_path" | cut -f1)
        local size_bytes=$(stat -f%z "$archive_path" 2>/dev/null || stat -c%s "$archive_path" 2>/dev/null)
        
        # Check if the archive has a reasonable size (at least 1KB)
        if [[ "$size_bytes" -gt 1024 ]]; then
            log "Archive created successfully: $archive_name (size: $size)"
            echo "$archive_path"
            return 0
        else
            log "Error: Archive file is too small (${size_bytes} bytes), indicating creation failure"
            return 1
        fi
    else
        log "Error: Archive file was not created"
        return 1
    fi
}

# Function to upload to R2
upload_to_r2() {
    local archive_path="$1"
    local archive_name=$(basename "$archive_path")
    
    # Check if the archive file exists before uploading
    if [[ ! -f "$archive_path" ]]; then
        log "Error: Archive file not found: $archive_path"
        return 1
    fi
    
    local file_size=$(du -h "$archive_path" | cut -f1)
    log "Starting upload to R2: $archive_name (size: $file_size)"
    log "Endpoint: $R2_ENDPOINT"
    log "Bucket: $R2_BUCKET_NAME"
    log "Region: $R2_REGION"
    
    # Configure AWS CLI for R2
    export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
    export AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
    export AWS_DEFAULT_REGION="$R2_REGION"
    
    # Testing connection to R2
    log "Checking bucket availability..."
    if aws s3 ls "s3://${R2_BUCKET_NAME}/" --endpoint-url="$R2_ENDPOINT" >/dev/null 2>&1; then
        log "Bucket is available, starting upload..."
    else
        log "Error: Bucket is unavailable or credentials are incorrect"
        log "Check your R2_ENDPOINT, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_BUCKET_NAME, R2_REGION settings"
        return 1
    fi
    
    # Uploading the file with detailed logging
    log "Executing command: aws s3 cp \"$archive_path\" \"s3://${R2_BUCKET_NAME}/\" --endpoint-url=\"$R2_ENDPOINT\""
    
    local upload_start=$(date '+%s')
    if aws s3 cp "$archive_path" "s3://${R2_BUCKET_NAME}/" --endpoint-url="$R2_ENDPOINT" 2>&1 | while IFS= read -r line; do
        log "AWS CLI: $line"
    done; then
        local upload_end=$(date '+%s')
        local upload_duration=$((upload_end - upload_start))
        log "Upload completed successfully: $archive_name in ${upload_duration} seconds"
        
        # Verifying that the file was actually uploaded
        log "Verifying uploaded file..."
        if aws s3 ls "s3://${R2_BUCKET_NAME}/$archive_name" --endpoint-url="$R2_ENDPOINT" >/dev/null 2>&1; then
            log "File successfully found in bucket: $archive_name"
            return 0
        else
            log "Warning: File not found in bucket after upload"
            return 1
        fi
    else
        log "Error during upload to R2"
        log "Possible reasons:"
        log "1. Incorrect R2 credentials"
        log "2. Insufficient permissions to write to the bucket"
        log "3. Network connection issues"
        log "4. File size limit exceeded"
        return 1
    fi
}

# Function to rotate old backups
rotate_backups() {
    log "Starting backup rotation (keeping last $BACKUP_RETENTION_DAYS days)"
    log "Endpoint: $R2_ENDPOINT"
    log "Bucket: $R2_BUCKET_NAME"
    log "Region: $R2_REGION"
    log "Prefix: ${BACKUP_NAME}_"
    
    export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
    export AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
    export AWS_DEFAULT_REGION="$R2_REGION"
    
    # Calculate the cutoff date in Unix epoch seconds
    local cutoff_timestamp=$(date -d "$BACKUP_RETENTION_DAYS days ago" +%s)
    local cutoff_date=$(date -d "$BACKUP_RETENTION_DAYS days ago" '+%Y-%m-%d %H:%M:%S')
    log "Cutoff date for deletion: $cutoff_date (timestamp: $cutoff_timestamp)"
    
    # Get a list of all backup files in JSON format
    log "Getting list of all backup files..."
    
    local files_json
    files_json=$(aws s3api list-objects-v2 \
        --bucket "$R2_BUCKET_NAME" \
        --prefix "${BACKUP_NAME}_" \
        --endpoint-url="$R2_ENDPOINT" \
        --output json 2>&1)
    
    local list_result=$?
    if [[ $list_result -ne 0 ]]; then
        log "Error while getting file list: $files_json"
        log "Possible reasons:"
        log "1. Incorrect R2 credentials"
        log "2. Insufficient permissions to read the bucket"
        log "3. Network connection issues"
        return 1
    fi
    
    # Check if there are any files
    local file_count=$(echo "$files_json" | jq -r '.Contents // [] | length' 2>/dev/null || echo "0")
    log "Found $file_count backup files"
    
    if [[ "$file_count" -eq 0 ]]; then
        log "No backup files found in the bucket"
        return 0
    fi
    
    # Process each file
    local deleted_count=0
    local total_files=0
    
    echo "$files_json" | jq -r '.Contents[]? | "\(.Key)|\(.LastModified)"' 2>/dev/null | while IFS='|' read -r key last_modified; do
        if [[ -n "$key" ]]; then
            total_files=$((total_files + 1))
            
            # Convert last modified date to timestamp
            local file_timestamp
            if file_timestamp=$(date -d "$last_modified" +%s 2>/dev/null); then
                local file_date=$(date -d "$last_modified" '+%Y-%m-%d %H:%M:%S')
                log "File: $key, date: $file_date (timestamp: $file_timestamp)"
                
                # Compare timestamps
                if [[ $file_timestamp -le $cutoff_timestamp ]]; then
                    log "Deleting old backup: $key (created: $file_date)"
                    
                    if aws s3 rm "s3://${R2_BUCKET_NAME}/${key}" --endpoint-url="$R2_ENDPOINT" 2>&1 | while IFS= read -r line; do
                        log "AWS CLI (delete): $line"
                    done; then
                        log "File deleted successfully: $key"
                        deleted_count=$((deleted_count + 1))
                    else
                        log "Error deleting file: $key"
                    fi
                else
                    log "Keeping file: $key (created: $file_date, newer than $cutoff_date)"
                fi
            else
                log "Error parsing date for file: $key ($last_modified)"
            fi
        fi
    done
    
    # Get final stats from variables (since the loop runs in a subshell)
    deleted_count=0
    kept_count=0
    
    echo "$files_json" | jq -r '.Contents[]? | "\(.Key)|\(.LastModified)"' 2>/dev/null | while IFS='|' read -r key last_modified; do
        if [[ -n "$key" ]]; then
            local file_timestamp
            if file_timestamp=$(date -d "$last_modified" +%s 2>/dev/null); then
                if [[ $file_timestamp -le $cutoff_timestamp ]]; then
                    if aws s3 rm "s3://${R2_BUCKET_NAME}/${key}" --endpoint-url="$R2_ENDPOINT" >/dev/null 2>&1; then
                        deleted_count=$((deleted_count + 1))
                    fi
                else
                    kept_count=$((kept_count + 1))
                fi
            fi
        fi
    done
    
    log "Rotation complete: processed files: $file_count, deleted: $deleted_count, kept: $kept_count"
    return 0
}

# Main function
main() {
    log "=== Starting backup process ==="
    
    # Check dependencies
    check_dependencies
    
    # Create temporary directory
    create_temp_dir
    
    # Set a trap to run cleanup on script exit
    trap 'cleanup' EXIT
    
    local start_time=$(date '+%s')
    local archive_path=""
    local success=true
    
    # Create archive
    log "=== STEP 1: Creating archive ==="
    if archive_path=$(create_backup_archive); then
        log "Archive created: $archive_path"
    else
        log "Error during archive creation"
        success=false
    fi
    
    # Upload to R2 (only if archive was created successfully)
    if [[ "$success" == "true" ]] && [[ -n "$archive_path" ]]; then
        log "=== STEP 2: Uploading to R2 ==="
        if upload_to_r2 "$archive_path"; then
            log "Upload to R2 completed successfully"
        else
            log "Error during upload to R2"
            success=false
        fi
    fi
    
    # Rotate backups (regardless of upload result)
    log "=== STEP 3: Rotating backups ==="
    if ! rotate_backups; then
        log "Warning: Error during backup rotation"
    fi
    
    # Final summary
    local end_time=$(date '+%s')
    local duration=$((end_time - start_time))
    
    if [[ "$success" == "true" ]]; then
        local success_msg="Backup completed successfully in ${duration} seconds"
        log "$success_msg"
    else
        local error_msg="Error during backup execution"
        log "$error_msg"
        exit 1
    fi
    
    log "=== Backup process finished ==="
}

# Check command-line arguments
case "${1:-}" in
    --test)
        log "Test mode - checking configuration"
        check_dependencies
        log "All dependencies are installed"
        log "Configuration is correct"
        exit 0
        ;;
    --rotate-only)
        log "Running backup rotation only"
        rotate_backups
        exit 0
        ;;
    *)
        main
        ;;
esac
