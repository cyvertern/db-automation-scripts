#!/bin/bash

################################################################################
# PostgreSQL Automated Backup System with Cloud Integration
# Description: Automated backup script for PostgreSQL databases with Google 
#              Drive upload and email notifications
# Author: Database Administrator
# Version: 1.0
################################################################################

# Exit on any error and on pipe failures
set -e
set -o pipefail

################################################################################
# CONFIGURATION SECTION - Modify these variables as needed
################################################################################

# Directory Configuration
BACKUP_DIR="/home/${USER}/LaboratoryExercises/Lab8"
LOG_FILE="$HOME/LaboratoryExercises/Lab8/pg_backup.log"

# Database Configuration
DB_NAME="production_db"
DB_USER="postgres"
PGPASSWORD=""  # Leave empty to use peer authentication or set password

# Email Configuration
ALERT_EMAIL="mendozajerson655@gmail.com"
FROM_EMAIL="mendozajerson655@gmail.com"

# Google Drive Configuration
GDRIVE_REMOTE="gdrive_backups:PostgreSQL_Backups"

# Backup Retention (days)
RETENTION_DAYS=7

# Timestamp format
TIMESTAMP=$(date +"%Y-%m-%d-%H%M%S")
DATE_STAMP=$(date +"%Y-%m-%d")

# Backup filenames
LOGICAL_BACKUP_FILE="production_db_${TIMESTAMP}.dump"
PHYSICAL_BACKUP_FILE="pg_base_backup_${TIMESTAMP}.tar.gz"

# Status tracking
BACKUP_FAILED=0
LOGICAL_BACKUP_SUCCESS=0
PHYSICAL_BACKUP_SUCCESS=0

################################################################################
# LOGGING FUNCTION
################################################################################

log_message() {
    local message="$1"
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] $message" | tee -a "$LOG_FILE"
}

################################################################################
# EMAIL NOTIFICATION FUNCTIONS
################################################################################

send_failure_email() {
    local subject="$1"
    local body="$2"
    local log_tail=$(tail -n 15 "$LOG_FILE")
    
    local email_body="${body}\n\n=== Last 15 lines from backup log ===\n${log_tail}"
    
    echo -e "$email_body" | mail -s "$subject" -r "$FROM_EMAIL" "$ALERT_EMAIL"
    log_message "Failure notification sent to $ALERT_EMAIL"
}

send_success_email() {
    local subject="$1"
    local body="$2"
    
    echo -e "$body" | mail -s "$subject" -r "$FROM_EMAIL" "$ALERT_EMAIL"
    log_message "Success notification sent to $ALERT_EMAIL"
}

################################################################################
# BACKUP FUNCTIONS
################################################################################

perform_logical_backup() {
    log_message "=== Starting FULL LOGICAL BACKUP of $DB_NAME ==="
    
    local backup_path="$BACKUP_DIR/$LOGICAL_BACKUP_FILE"
    
    if sudo -u postgres pg_dump -Fc -f "$backup_path" "$DB_NAME" 2>&1 | tee -a "$LOG_FILE"; then
        log_message "Logical backup completed successfully: $LOGICAL_BACKUP_FILE"
        log_message "Backup size: $(du -h "$backup_path" | cut -f1)"
        LOGICAL_BACKUP_SUCCESS=1
        return 0
    else
        log_message "ERROR: Logical backup FAILED for $DB_NAME"
        BACKUP_FAILED=1
        return 1
    fi
}

perform_physical_backup() {
    log_message "=== Starting PHYSICAL BASE BACKUP ==="
    
    local backup_path="$BACKUP_DIR/$PHYSICAL_BACKUP_FILE"
    local data_dir=$(sudo -u postgres psql -t -c "SHOW data_directory;" | xargs)
    
    log_message "Data directory: $data_dir"
    
    # Create a tar.gz backup of the data directory
    if sudo tar -czf "$backup_path" -C "$(dirname "$data_dir")" "$(basename "$data_dir")" 2>&1 | tee -a "$LOG_FILE"; then
        log_message "Physical backup completed successfully: $PHYSICAL_BACKUP_FILE"
        log_message "Backup size: $(du -h "$backup_path" | cut -f1)"
        PHYSICAL_BACKUP_SUCCESS=1
        return 0
    else
        log_message "ERROR: Physical backup FAILED"
        BACKUP_FAILED=1
        return 1
    fi
}
################################################################################
# UPLOAD FUNCTION
################################################################################

upload_to_gdrive() {
    log_message "=== Starting upload to Google Drive ==="
    
    local files_to_upload=()
    
    if [ $LOGICAL_BACKUP_SUCCESS -eq 1 ]; then
        files_to_upload+=("$BACKUP_DIR/$LOGICAL_BACKUP_FILE")
    fi
    
    if [ $PHYSICAL_BACKUP_SUCCESS -eq 1 ]; then
        files_to_upload+=("$BACKUP_DIR/$PHYSICAL_BACKUP_FILE")
    fi
    
    if [ ${#files_to_upload[@]} -eq 0 ]; then
        log_message "ERROR: No backup files to upload"
        return 1
    fi
    
    local upload_failed=0
    local uploaded_files=()
    
    for file in "${files_to_upload[@]}"; do
        log_message "Uploading: $(basename "$file")"
        if rclone copy "$file" "$GDRIVE_REMOTE" --progress 2>&1 | tee -a "$LOG_FILE"; then
            log_message "Successfully uploaded: $(basename "$file")"
            uploaded_files+=("$(basename "$file")")
        else
            log_message "ERROR: Failed to upload $(basename "$file")"
            upload_failed=1
        fi
    done
    
    if [ $upload_failed -eq 1 ]; then
        send_failure_email "FAILURE: PostgreSQL Backup Upload" \
            "Backups were created locally but failed to upload to Google Drive. Check rclone logs."
        return 1
    else
        local success_body="Successfully created and uploaded the following backups:\n"
        for file in "${uploaded_files[@]}"; do
            success_body="${success_body}- ${file}\n"
        done
        success_body="${success_body}\nBackup Date: ${DATE_STAMP}\nBackup Time: ${TIMESTAMP}"
        
        send_success_email "SUCCESS: PostgreSQL Backup and Upload" "$success_body"
        return 0
    fi
}

################################################################################
# CLEANUP FUNCTION
################################################################################

cleanup_old_backups() {
    log_message "=== Cleaning up backups older than $RETENTION_DAYS days ==="
    
    local deleted_count=$(find "$BACKUP_DIR" -name "*.dump" -o -name "*.tar.gz" -type f -mtime +$RETENTION_DAYS | wc -l)
    
    if [ $deleted_count -gt 0 ]; then
        find "$BACKUP_DIR" -name "*.dump" -o -name "*.tar.gz" -type f -mtime +$RETENTION_DAYS -delete
        log_message "Deleted $deleted_count old backup file(s)"
    else
        log_message "No old backup files to delete"
    fi
}

################################################################################
# MAIN EXECUTION
################################################################################

main() {
    log_message "=========================================="
    log_message "PostgreSQL Backup Process Started"
    log_message "=========================================="
    log_message "Hostname: $HOSTNAME"
    log_message "Backup Directory: $BACKUP_DIR"
    log_message "Database: $DB_NAME"
    log_message "Timestamp: $TIMESTAMP"
    
    # Create backup directory if it doesn't exist
    mkdir -p "$BACKUP_DIR"
    
    # Perform backups
    perform_logical_backup
    perform_physical_backup
    
    # Check if backups failed
    if [ $BACKUP_FAILED -eq 1 ]; then
        log_message "=========================================="
        log_message "BACKUP PROCESS FAILED"
        log_message "=========================================="
        
        local failed_backups=""
        if [ $LOGICAL_BACKUP_SUCCESS -eq 0 ]; then
            failed_backups="- Logical backup of $DB_NAME\n"
        fi
        if [ $PHYSICAL_BACKUP_SUCCESS -eq 0 ]; then
            failed_backups="${failed_backups}- Physical base backup\n"
        fi
        
        send_failure_email "FAILURE: PostgreSQL Backup Task" \
            "The following backup(s) failed:\n${failed_backups}\nPlease check the logs immediately."
        
        exit 1
    fi
    
    # Upload to Google Drive (only if backups succeeded)
    log_message "All backups completed successfully, proceeding to upload..."
    
    if upload_to_gdrive; then
        log_message "Upload completed successfully"
        
        # Cleanup old backups (only after successful backup and upload)
        cleanup_old_backups
    else
        log_message "Upload failed, skipping cleanup"
        exit 1
    fi
    
    log_message "=========================================="
    log_message "PostgreSQL Backup Process Completed Successfully"
    log_message "=========================================="
    
    exit 0
}

################################################################################
# SCRIPT ENTRY POINT
################################################################################

# Execute main function
main "$@"
