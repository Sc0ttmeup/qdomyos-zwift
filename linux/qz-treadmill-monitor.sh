#!/bin/bash

LOG_FILE="/tmp/qz-treadmill-monitor.log"
SCAN_FILE="/tmp/qz-treadmill-monitor-btmon.log"
TARGET_DEVICE="M3"
SCAN_INTERVAL=15  # Time in seconds between checks
SERVICE_NAME="qz"
DEBUG_LOG_DIR="/var/log"  # Directory where QZ debug logs are stored
ERROR_MESSAGE="BTLE stateChanged InvalidService"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

is_service_running() {
    systemctl is-active --quiet "$SERVICE_NAME"
    return $?
}

scan_for_device() {
    log "Starting Bluetooth scan for $TARGET_DEVICE..."

    # Run bluetoothctl scan in the background and capture output
    bluetoothctl scan on &>/dev/null &
    SCAN_PID=$!

    # Run btmon in the background and capture output
    btmon > "$SCAN_FILE" &
    MONITOR_PID=$!

    # Ensure scan stops when this script exits
    trap "kill $SCAN_PID" EXIT
    trap "kill $MONITOR_PID" EXIT

    # Allow some time for devices to appear
    sleep 5

    grep -q "Name (complete): $TARGET_DEVICE" "$SCAN_FILE"
    DEVICE_FOUND=$?

    # Stop scanning
    kill "$SCAN_PID"
    kill "$MONITOR_PID"


    if [ $DEVICE_FOUND -eq 0 ]; then
        log "Device '$TARGET_DEVICE' found."
        return 0
    else
        log "Device '$TARGET_DEVICE' not found."
        return 1
    fi
}

restart_qz_on_error() {
    # Get the current date
    CURRENT_DATE=$(date '+%a_%b_%d')
    
    # Find the latest QZ debug log file for today
    LATEST_LOG=$(ls -t "$DEBUG_LOG_DIR"/debug-"$CURRENT_DATE"_*.log 2>/dev/null | head -n 1)
    log "LATEST_LOG = $LATEST_LOG"
    
    if [ -z "$LATEST_LOG" ]; then
        log "No QZ debug log found for today."
        return 0
    fi

    log "Checking latest log file: $LATEST_LOG for errors..."

    # Search the latest log for the error message
    if grep -q "$ERROR_MESSAGE" "$LATEST_LOG"; then
        log "***** Error detected in QZ log: $ERROR_MESSAGE *****"
        log "Restarting QZ service..."
        systemctl restart "$SERVICE_NAME"
    else
        log "No errors detected in $LATEST_LOG."
    fi
}

manage_service() {
    local device_found=$1
    if $device_found; then
        if ! is_service_running; then
            log "***** Starting QZ service... *****"
            systemctl start "$SERVICE_NAME"
        else
            log "QZ service is already running."
            restart_qz_on_error  # Check the log for errors when QZ is already running
        fi
    else
        if is_service_running; then
            log "***** Stopping QZ service... *****"
            systemctl stop "$SERVICE_NAME"
        else
            log "QZ service is already stopped."
        fi
    fi
}

while true; do
    log "Checking for treadmill status..."
    if scan_for_device; then
        manage_service true
    else
        manage_service false
    fi
    log "Waiting for $SCAN_INTERVAL seconds before next check..."
    sleep "$SCAN_INTERVAL"
done
