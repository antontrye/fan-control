#!/bin/bash

source /etc/ipmi.conf

# Configuration
TARGET_TEMP=75
CHECK_INTERVAL=8
MIN_FAN_SPEED=22
MAX_FAN_SPEED=87
DEADBAND=1
SETTLE_TIME=3
MAX_STEP_CHANGE=15

# Logging Configuration
LOG_FILE="/var/log/fan_control.log"
LOG_MAX_SIZE=52428800  # 50MB in bytes
LOG_LEVEL="INFO"  # DEBUG, INFO, WARN, ERROR

# State
current_fan_speed=50
last_fan_speed=50
cycles_at_speed=0
last_direction=0
oscillation_count=0

# Initialize logging
init_logging() {
    # Create log directory if needed
    mkdir -p $(dirname "$LOG_FILE")
    
    # Create initial log file if it doesn't exist
    touch "$LOG_FILE"
    
    log_info "============================================"
    log_info "Fan Control Service Starting"
    log_info "PID: $$"
    log_info "Configuration:"
    log_info "  Target Temperature: ${TARGET_TEMP}°C ± ${DEADBAND}°C"
    log_info "  Check Interval: ${CHECK_INTERVAL}s"
    log_info "  Fan Speed Range: ${MIN_FAN_SPEED}-${MAX_FAN_SPEED}"
    log_info "  Max Step Change: ${MAX_STEP_CHANGE}"
    log_info "  Settle Time: ${SETTLE_TIME} cycles"
    log_info "============================================"
}

# Check and rotate log if needed
check_log_rotation() {
    if [ -f "$LOG_FILE" ]; then
        local size=$(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
        if [ "$size" -gt "$LOG_MAX_SIZE" ]; then
            local timestamp=$(date '+%Y%m%d_%H%M%S')
            mv "$LOG_FILE" "${LOG_FILE}.${timestamp}"
            touch "$LOG_FILE"
            
            # Keep only the 3 most recent rotated logs
            ls -t "${LOG_FILE}".* 2>/dev/null | tail -n +4 | xargs rm -f 2>/dev/null || true
            
            log_info "Log rotated (size was $((size / 1048576))MB)"
        fi
    fi
}

# Logging functions
log_debug() {
    [ "$LOG_LEVEL" == "DEBUG" ] && log_write "DEBUG" "$1"
}

log_info() {
    log_write "INFO" "$1"
}

log_warn() {
    log_write "WARN" "$1"
}

log_error() {
    log_write "ERROR" "$1"
}

log_write() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Write to log file
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    
    # Also write important messages to stdout for service logs
    if [ "$level" == "ERROR" ] || [ "$level" == "WARN" ]; then
        echo "[$timestamp] [$level] $message"
    fi
    
    # Check rotation every 100 writes (performance optimization)
    if [ $((RANDOM % 100)) -eq 0 ]; then
        check_log_rotation
    fi
}

log_message() {
    # Backwards compatibility wrapper
    log_info "$1"
}

get_max_temp() {
    local max_temp=0
    local max_name=""
    local sensor_count=0

    log_debug "Reading temperature sensors..."
    
    while IFS= read -r line; do
        if echo "$line" | grep -q '+.*°C'; then
            temp=$(echo "$line" | sed -n 's/.*+\([0-9]*\)\.[0-9]*°C.*/\1/p')
            if [ -n "$temp" ]; then
                sensor_count=$((sensor_count + 1))
                sensor_name=$(echo "$line" | cut -d':' -f1 | sed 's/^[[:space:]]*//')
                log_debug "Sensor: $sensor_name = ${temp}°C"
                
                if [ "$temp" -gt "$max_temp" ]; then
                    max_temp=$temp
                    max_name=$sensor_name
                fi
            fi
        fi
    done < <(sensors 2>/dev/null)

    log_debug "Found $sensor_count temperature sensors"
    
    if [ "$max_temp" -gt 0 ]; then
        echo "$max_temp:$max_name"
    else
        log_warn "No temperature sensors found"
        echo "0:none"
    fi
}

calculate_fan_adjustment() {
    local temp=$1
    local delta=$((temp - TARGET_TEMP))
    local adjustment=0

    log_debug "Calculating adjustment: temp=${temp}°C, target=${TARGET_TEMP}°C, delta=${delta}°C"

    if [ "$delta" -ge "-$DEADBAND" ] && [ "$delta" -le "$DEADBAND" ]; then
        log_debug "Temperature within deadband (±${DEADBAND}°C), no adjustment needed"
        echo "0"
        return
    fi

    if [ "$delta" -gt 0 ]; then
        # Temperature above target
        if [ "$delta" -le 2 ]; then
            adjustment=1
        elif [ "$delta" -le 4 ]; then
            adjustment=2
        elif [ "$delta" -le 6 ]; then
            adjustment=4
        elif [ "$delta" -le 10 ]; then
            adjustment=8
        else
            adjustment=$MAX_STEP_CHANGE
        fi
        log_debug "Temperature above target: delta=+${delta}°C, base adjustment=+${adjustment}"
    else
        # Temperature below target
        delta=$((0 - delta))
        if [ "$delta" -le 2 ]; then
            adjustment=-1
        elif [ "$delta" -le 4 ]; then
            adjustment=-2
        elif [ "$delta" -le 8 ]; then
            adjustment=-3
        else
            adjustment=-5
        fi
        log_debug "Temperature below target: delta=-${delta}°C, base adjustment=${adjustment}"
    fi

    if [ "$oscillation_count" -gt 2 ]; then
        if [ "$adjustment" -gt 1 ] || [ "$adjustment" -lt -1 ]; then
            local old_adjustment=$adjustment
            adjustment=$((adjustment / 2))
            [ "$adjustment" -eq 0 ] && adjustment=1
            log_info "Oscillation dampening: adjustment reduced from $old_adjustment to $adjustment"
        fi
    fi

    echo "$adjustment"
}

detect_oscillation() {
    local new_direction=$1

    if [ "$new_direction" -ne 0 ] && [ "$last_direction" -ne 0 ]; then
        if [ "$new_direction" -ne "$last_direction" ]; then
            oscillation_count=$((oscillation_count + 1))
            log_debug "Direction change detected: $last_direction -> $new_direction (oscillation count: $oscillation_count)"
            if [ "$oscillation_count" -gt 3 ]; then
                log_warn "Oscillation detected (count: $oscillation_count) - dampening enabled"
            fi
        else
            if [ "$oscillation_count" -gt 0 ]; then
                oscillation_count=$((oscillation_count - 1))
                log_debug "Same direction maintained, reducing oscillation count to $oscillation_count"
            fi
        fi
    fi

    last_direction=$new_direction
}

set_fan_speed() {
    local speed=$1
    local original_speed=$speed

    if [ "$speed" -lt "$MIN_FAN_SPEED" ]; then
        log_debug "Clamping speed from $speed to minimum $MIN_FAN_SPEED"
        speed=$MIN_FAN_SPEED
    fi
    
    if [ "$speed" -gt "$MAX_FAN_SPEED" ]; then
        log_debug "Clamping speed from $speed to maximum $MAX_FAN_SPEED"
        speed=$MAX_FAN_SPEED
    fi

    log_info "Setting fan speed: $current_fan_speed → $speed"
    
    if /usr/local/bin/fan "$speed" >/dev/null 2>&1; then
        last_fan_speed=$current_fan_speed
        current_fan_speed=$speed
        cycles_at_speed=0
        log_debug "Fan speed successfully set to $speed"
        return 0
    else
        log_error "Failed to set fan speed to $speed"
        return 1
    fi
}

cleanup() {
    log_info "Received shutdown signal"
    log_info "Final state: Fan speed=$current_fan_speed, Oscillation count=$oscillation_count"
    log_info "Fan Control Service Stopped"
    log_info "============================================"
    exit 0
}

trap cleanup INT TERM

# Initialize logging system
init_logging

# Set initial fan speed
log_info "Setting initial fan speed to $current_fan_speed"
if ! set_fan_speed $current_fan_speed; then
    log_error "Failed to set initial fan speed - check IPMI connectivity"
    log_error "IPMI Host: $IPMI_HOST"
    exit 1
fi

# Main control loop
log_info "Entering main control loop"
loop_iteration=0

while true; do
    loop_iteration=$((loop_iteration + 1))
    log_debug "=== Loop iteration $loop_iteration ==="
    
    temp_data=$(get_max_temp)
    max_temp=$(echo "$temp_data" | cut -d':' -f1)
    max_name=$(echo "$temp_data" | cut -d':' -f2)

    if [ "$max_temp" -gt 0 ]; then
        adjustment=$(calculate_fan_adjustment "$max_temp" "$current_fan_speed")
        cycles_at_speed=$((cycles_at_speed + 1))
        
        log_debug "Current state: temp=${max_temp}°C, fan=${current_fan_speed}, cycles=${cycles_at_speed}, adjustment=${adjustment}"

        if [ "$adjustment" -ne 0 ]; then
            # Check if we need to wait for settling
            if [ "$adjustment" -eq 1 ] || [ "$adjustment" -eq -1 ]; then
                if [ "$cycles_at_speed" -lt "$SETTLE_TIME" ]; then
                    log_info "Temp: ${max_name}=${max_temp}°C | Fan: ${current_fan_speed} | Status: Settling (${cycles_at_speed}/${SETTLE_TIME})"
                    sleep $CHECK_INTERVAL
                    continue
                fi
            fi

            new_fan_speed=$((current_fan_speed + adjustment))
            log_debug "Proposing fan speed change: $current_fan_speed → $new_fan_speed (adjustment: $adjustment)"

            # Update oscillation detection
            if [ "$adjustment" -gt 0 ]; then
                detect_oscillation 1
            else
                detect_oscillation -1
            fi

            # Apply the speed change
            if set_fan_speed "$new_fan_speed"; then
                delta=$((max_temp - TARGET_TEMP))
                log_info "Temp: ${max_name}=${max_temp}°C (Δ${delta}) | Fan: ${last_fan_speed} → ${current_fan_speed} | Adjustment: ${adjustment}"
            else
                log_error "Failed to adjust fan speed from $current_fan_speed to $new_fan_speed"
            fi
        else
            # Temperature is stable
            if [ "$cycles_at_speed" -eq 10 ]; then
                log_info "Reached steady state: ${max_name}=${max_temp}°C | Fan: ${current_fan_speed}"
            elif [ "$cycles_at_speed" -lt 10 ]; then
                log_info "Temp: ${max_name}=${max_temp}°C | Fan: ${current_fan_speed} | Status: Stable"
            elif [ "$cycles_at_speed" -eq 50 ] || [ "$cycles_at_speed" -eq 100 ] || [ "$cycles_at_speed" -eq 200 ]; then
                # Periodic status update when stable for long periods
                log_info "Status update: ${max_name}=${max_temp}°C | Fan: ${current_fan_speed} | Stable for $cycles_at_speed cycles"
            fi
            
            # Reduce oscillation count when stable
            if [ "$oscillation_count" -gt 0 ]; then
                oscillation_count=$((oscillation_count - 1))
                log_debug "Reducing oscillation count to $oscillation_count"
            fi
        fi
    else
        log_warn "No temperature reading available"
    fi

    sleep $CHECK_INTERVAL
done