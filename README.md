# Cloudflare R2 Backup Script

A simple yet powerful Bash script for creating compressed backups of specified directories and uploading them to a Cloudflare R2 bucket. It includes automatic backup rotation.

## Features

-   Backup to any S3-compatible storage (pre-configured for Cloudflare R2).
-   High-speed and efficient compression using `zstd`.
-   Automatic rotation of old backups based on a retention period.
-   Configuration via a simple `.env` file.
-   Detailed logging of all operations.
-   Dependency checks to ensure the environment is ready.

## Prerequisites

Before you begin, ensure you have the following tools installed on your system:

-   `aws-cli` (v2 is recommended)
-   `zstd`
-   `tar`
-   `jq`

You can install them on a Debian-based system (like Ubuntu) using:

```bash
sudo apt-get update && sudo apt-get install awscli zstd tar jq -y
```

## Setup

1.  **Clone the Repository**
    Clone this repository to your server.
    ```bash
    git clone https://github.com/0FL01/r2-backup.git
    cd r2_backup
    ```

2.  **Make the Script Executable**
    ```bash
    chmod +x r2-backup.sh
    ```

3.  **Create Configuration File**
    Create a `.env` file in the root of the project directory. You can copy the provided example if one exists.
    ```bash
    cp .env.example .env
    ```
    Now, open the `.env` file and add your configuration.

## Configuration

Edit the `.env` file with your specific parameters.

### Required Parameters

-   `R2_ENDPOINT`: Your full Cloudflare R2 endpoint URL.
-   `R2_ACCESS_KEY_ID`: Your R2 Access Key ID.
-   `R2_SECRET_ACCESS_KEY`: Your R2 Secret Access Key.
-   `R2_BUCKET_NAME`: The name of the R2 bucket where backups will be stored.
-   `BACKUP_PATHS`: A comma-separated list of absolute paths to the directories you want to back up.
    -   **Example**: `BACKUP_PATHS="/var/www/my-site,/etc/nginx,/home/user/data"`

### Optional Parameters

-   `ZSTD_LEVEL`: The `zstd` compression level. Ranges from 1 (fastest) to 22 (highest compression). (Default: `3`).
-   `BACKUP_RETENTION_DAYS`: The number of days to keep backups. Older backups will be automatically deleted. (Default: `7`).
-   `LOG_FILE`: The absolute path to the log file. (Default: `/var/log/r2-backup.log`).
-   `TEMP_DIR`: A temporary directory for creating archives before upload. (Default: `/tmp/r2-backup`).
-   `R2_REGION`: The region for your bucket. (Default: `auto`).

## Usage

### Manual Backup

To run a full backup process (create, upload, rotate) manually, simply execute the script:

```bash
./r2-backup.sh
```

### Test Configuration

To check if dependencies are installed and the configuration is readable without performing a backup, use the `--test` flag:

```bash
./r2-backup.sh --test
```

### Rotate Backups Only

To run only the rotation part of the script to clean up old backups, use the `--rotate-only` flag:

```bash
./r2-backup.sh --rotate-only
```

### Scheduling with Cron (Automated Backups)

To automate the backup process, you can add a new job to your crontab.

1. Copy exucutable files
   ```
   sudo mkdir -p /opt/r2_backup && sudo cp -a r2-backup.sh .env /opt/r2_backup/
   ```


2.  Open the crontab editor:
    ```bash
    crontab -e
    ```

3.  Add the following line to schedule the script to run daily at 04:20 AM. **Remember to use the absolute path to your `backup.sh` script.**

    ```crontab
    # Run the R2 backup script daily at 4:20 AM
    20 4 * * * /opt/r2_backup/r2-backup.sh > /dev/null 2>&1
    ```

    -   `/opt/r2_backup/r2-backup.sh` is the absolute path to the script.
    -   `> /dev/null 2>&1` prevents cron from sending emails with the script's output, as all output is already being logged to the file specified in `LOG_FILE`.

## Logging

All script operations are logged to the file specified by the `LOG_FILE` variable in your `.env` file (default is `/var/log/r2-backup.log`). Check this file for detailed information and for troubleshooting any issues.

```bash
tail -f /var/log/r2-backup.log
```
