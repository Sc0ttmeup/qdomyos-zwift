#!/bin/bash

set -x

LOG_FILE="/tmp/qz-treadmill-monitor.log"
SCAN_FILE="/tmp/qz-treadmill-monitor-btmon.log"
TARGET_DEVICE="M3"
POLL_INTERVAL=1             # Time in seconds between checking status of scan and TIMEOUT_INTERVAL intervals
SCAN_INTERVAL=15            # Time in seconds between searching for TARGET_DEVICE
TIMEOUT_INTERVAL=90         # Time in seconds before stopping qz service if device not seen
SERVICE_NAME="qz"
DEBUG_LOG_DIR="/tmp"
ERROR_MESSAGE="BTLE stateChanged InvalidService"
LAST_SEEN=0
LAST_SCANNED=0
LAST_POLLED=$(date +%s)
CURRENT_TIME=$(date +%s)

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

is_service_running() {
    systemctl is-active --quiet "$SERVICE_NAME"
    return $?
}

scan_for_device() {
    log "Starting Bluetooth scan for $TARGET_DEVICE..."

    LAST_SCANNED=$(date +%s)

    bluetoothctl scan on &>/dev/null &
    SCAN_PID=$!

    btmon > "$SCAN_FILE" &
    MONITOR_PID=$!
    chmod +w "$SCAN_FILE"

    trap "kill $SCAN_PID" EXIT
    trap "kill $MONITOR_PID" EXIT

    sleep $POLL_INTERVAL

    grep -q "Name (complete): $TARGET_DEVICE" "$SCAN_FILE"
    DEVICE_FOUND=$?

    kill "$SCAN_PID"
    kill "$MONITOR_PID"

    if [ $DEVICE_FOUND -eq 0 ]; then
        log "Device '$TARGET_DEVICE' found."
        LAST_SEEN=$(date +%s)
        return 0
    else
        log "Device '$TARGET_DEVICE' not found."
        return 1
    fi
}

restart_qz_on_error() {
    CURRENT_DATE=$(date '+%a_%b_%d')
    LATEST_LOG=$(ls -t "$DEBUG_LOG_DIR"/debug-"$CURRENT_DATE"_*.log 2>/dev/null | head -n 1)
    log "LATEST_LOG = $LATEST_LOG"

    if [ -z "$LATEST_LOG" ]; then
        log "No QZ debug log found for today."
        return 0
    fi

    log "Checking latest log file: $LATEST_LOG for errors..."

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
    if [ $((CURRENT_TIME - LAST_SCANNED)) -ge $SCAN_INTERVAL ]; then
        if $device_found; then
            if ! is_service_running; then
                log "***** Starting QZ service... *****"
		rm "$DEBUG_LOG_DIR"/debug-*.log          # Clear previous debug logs
                systemctl start "$SERVICE_NAME"
            else
                log "QZ service is already running."
                restart_qz_on_error
            fi
        else
        log "Scan run, but device not detected."
        fi
    fi

    # Check if device has not been seen for too long
    if [ $((CURRENT_TIME - LAST_SEEN)) -ge $TIMEOUT_INTERVAL ]; then
        log "Device not seen for more than $TIMEOUT_INTERVAL seconds."
        if is_service_running; then
            log "***** Forcing QZ service restart due to TIMEOUT_INTERVAL *****"
            systemctl restart "$SERVICE_NAME"
        else
            log "QZ service is not running; no action taken."
        fi
    fi
}

while true; do
    CURRENT_TIME=$(date +%s)
	if [ $((CURRENT_TIME - LAST_POLLED)) -ge $POLL_INTERVAL ]; then
	    log "Checking for treadmill status..."
            LAST_POLLED=$(date +%s)
   	    if scan_for_device; then
    	        manage_service true
    	    else
       	        manage_service false
        fi
    fi
    log "Waiting for $POLL_INTERVAL seconds before next check..."
    sleep "$POLL_INTERVAL"
done
