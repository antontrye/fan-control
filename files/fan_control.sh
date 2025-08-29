#!/usr/bin/env bash
# /usr/local/bin/fan_control.sh
#
# Adaptive fan control with separate CPU & DRIVE targets.
# - New floor supported: clamps to [12, 87] at all times.
# - Seeds initial PWM from the *initial temp delta* (no guessing).
# - Drive temps via smartctl (-n standby to avoid spinning idle disks).
# - Logs to /var/log/fan_control.log, with rotation.

set -euo pipefail

# ---------- IPMI credentials ----------
source /etc/ipmi.conf

# ---------- Configuration ----------
# Targets (override via env if desired)
TARGET_CPU_TEMP="${TARGET_CPU_TEMP:-68}"     # °C
TARGET_DRIVE_TEMP="${TARGET_DRIVE_TEMP:-45}" # °C

# Control behavior
CHECK_INTERVAL="${CHECK_INTERVAL:-8}"        # seconds
MIN_FAN_SPEED="${MIN_FAN_SPEED:-12}"         # new floor
MAX_FAN_SPEED="${MAX_FAN_SPEED:-87}"
DEADBAND="${DEADBAND:-1}"                    # ±°C considered "stable"
SETTLE_TIME="${SETTLE_TIME:-3}"              # cycles to wait for ±1 changes
MAX_STEP_CHANGE="${MAX_STEP_CHANGE:-15}"     # absolute max per-cycle step

# Initial PWM fallback if we can't read temps (can override via env)
INITIAL_FAN_SPEED="${INITIAL_FAN_SPEED:-24}"

# Drives list (empty = auto-discover "disk" nodes via lsblk)
DRIVES=()

# Logging
LOG_FILE="${LOG_FILE:-/var/log/fan_control.log}"
LOG_MAX_SIZE="${LOG_MAX_SIZE:-52428800}"     # 50 MB
LOG_LEVEL="${LOG_LEVEL:-INFO}"               # DEBUG, INFO, WARN, ERROR

# ---------- State ----------
current_fan_speed="$INITIAL_FAN_SPEED"
last_fan_speed="$INITIAL_FAN_SPEED"
cycles_at_speed=0
last_direction=0
oscillation_count=0

# ---------- Logging ----------
init_logging() {
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"
  log_info "============================================"
  log_info "Fan Control Starting (PID $$)"
  log_info "Targets: CPU ${TARGET_CPU_TEMP}°C, DRV ${TARGET_DRIVE_TEMP}°C (±${DEADBAND}°C)"
  log_info "Range: ${MIN_FAN_SPEED}–${MAX_FAN_SPEED}% | StepMax: ${MAX_STEP_CHANGE} | Settle: ${SETTLE_TIME} | Interval: ${CHECK_INTERVAL}s"
  log_info "============================================"
}

check_log_rotation() {
  if [ -f "$LOG_FILE" ]; then
    local size
    size=$(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "$size" -gt "$LOG_MAX_SIZE" ]; then
      local ts; ts=$(date '+%Y%m%d_%H%M%S')
      mv "$LOG_FILE" "${LOG_FILE}.${ts}"
      touch "$LOG_FILE"
      ls -t "${LOG_FILE}".* 2>/dev/null | tail -n +4 | xargs rm -f 2>/dev/null || true
      log_info "Log rotated (size was $((size/1048576)) MB)"
    fi
  fi
}

log_write(){ local lvl="$1"; shift; local msg="$*"; local ts; ts=$(date '+%Y-%m-%d %H:%M:%S'); echo "[$ts] [$lvl] $msg" >> "$LOG_FILE"; { [ "$lvl" = "ERROR" ] || [ "$lvl" = "WARN" ]; } && echo "[$ts] [$lvl] $msg"; [ $((RANDOM%100)) -eq 0 ] && check_log_rotation; }
log_debug(){ [ "$LOG_LEVEL" = "DEBUG" ] && log_write "DEBUG" "$*"; }
log_info(){  log_write "INFO"  "$*"; }
log_warn(){  log_write "WARN"  "$*"; }
log_error(){ log_write "ERROR" "$*"; }

# ---------- Prereqs ----------
require_cmds() {
  local missing=0
  for c in sensors smartctl lsblk awk sed grep cut ipmitool timeout; do
    command -v "$c" >/dev/null 2>&1 || { log_error "Missing command: $c"; missing=1; }
  done
  [ $missing -eq 0 ] || { log_error "Install missing dependencies."; exit 1; }
}

# ---------- Helpers ----------
abs() { local v=$1; [ "$v" -lt 0 ] && echo $((-v)) || echo "$v"; }

# ---------- Temperature Readers ----------
get_cpu_max_temp() {
  local max_temp=0 max_name="none"
  while IFS= read -r line; do
    echo "$line" | grep -Ei '(^|\s)(package id|tctl|tdie|core [0-9]+|cpu[^a-z]|cpu temp|pch|soc)' >/dev/null || continue
    local t
    t=$(echo "$line" | sed -n 's/.*+\([0-9]\{1,3\}\)\(\.[0-9]\)\?°C.*/\1/p')
    if [ -n "$t" ]; then
      local name; name=$(echo "$line" | cut -d':' -f1 | sed 's/^[[:space:]]*//')
      log_debug "CPU sensor: $name=${t}°C"
      if [ "$t" -gt "$max_temp" ]; then max_temp=$t; max_name=$name; fi
    fi
  done < <(sensors 2>/dev/null)
  [ "$max_temp" -gt 0 ] && echo "${max_temp}:${max_name}" || echo "0:none"
}

discover_drives() {
  if [ "${#DRIVES[@]}" -eq 0 ]; then
    mapfile -t DRIVES < <(lsblk -ndo NAME,TYPE | awk '$2=="disk"{print "/dev/"$1}')
  fi
}

get_drive_max_temp() {
  discover_drives
  local max_temp=0 max_name="none"
  for dev in "${DRIVES[@]}"; do
    [ -b "$dev" ] || continue
    local out rc
    out=$(timeout 5 smartctl -A -n standby "$dev" 2>/dev/null); rc=$?
    if [ $rc -eq 2 ]; then log_debug "Drive standby (skipped): $dev"; continue
    elif [ $rc -ne 0 ]; then log_debug "smartctl failed ($rc) for $dev"; continue; fi
    local t
    t=$(echo "$out" | awk 'BEGIN{IGNORECASE=1}
      /(Temperature_Celsius|Airflow_Temperature_Cel|Composite Temperature|Device Temperature|Current Temperature|Temperature:)/ {
        for(i=NF;i>=1;i--) if ($i ~ /^[0-9]+$/) {print $i; exit}
      }' | head -n1)
    if [ -n "$t" ] && [[ "$t" =~ ^[0-9]+$ ]]; then
      log_debug "Drive temp: $dev=${t}°C"
      if [ "$t" -gt "$max_temp" ]; then max_temp=$t; max_name=$(basename "$dev"); fi
    fi
  done
  [ "$max_temp" -gt 0 ] && echo "${max_temp}:${max_name}" || echo "0:none"
}

# ---------- Initial Speed from Initial Delta ----------
# Map the hottest delta (above/below target) to a starting PWM.
map_delta_to_initial_pwm() {
  local d="$1"  # can be negative/positive
  # Tune bins to taste; values are conservative for noise vs. cooling
  if   [ "$d" -ge 15 ]; then echo 87
  elif [ "$d" -ge 10 ]; then echo 72
  elif [ "$d" -ge 7  ]; then echo 60
  elif [ "$d" -ge 5  ]; then echo 48
  elif [ "$d" -ge 3  ]; then echo 38
  elif [ "$d" -ge 1  ]; then echo 28
  elif [ "$d" -ge -2 ]; then echo 22
  elif [ "$d" -ge -5 ]; then echo 16
  else                      echo 12
  fi
}

choose_initial_speed_from_temps() {
  local cpu_line drv_line cpu_t drv_t
  cpu_line=$(get_cpu_max_temp); cpu_t=${cpu_line%%:*}
  drv_line=$(get_drive_max_temp); drv_t=${drv_line%%:*}
  [ -z "${cpu_t:-}" ] && cpu_t=0
  [ -z "${drv_t:-}" ] && drv_t=0

  local d_cpu=$((cpu_t - TARGET_CPU_TEMP))
  local d_drv=$((drv_t - TARGET_DRIVE_TEMP))

  # choose controlling source by larger positive delta; if both negative, pick the less-negative (closest to 0)
  local chosen_delta chosen_src
  if [ "$d_cpu" -ge "$d_drv" ]; then chosen_delta="$d_cpu"; chosen_src="CPU"; else chosen_delta="$d_drv"; chosen_src="DRIVE"; fi

  local seed; seed=$(map_delta_to_initial_pwm "$chosen_delta")
  # clamp to bounds
  [ "$seed" -lt "$MIN_FAN_SPEED" ] && seed="$MIN_FAN_SPEED"
  [ "$seed" -gt "$MAX_FAN_SPEED" ] && seed="$MAX_FAN_SPEED"

  log_info "Initial temps => CPU=${cpu_t}°C (Δ$((cpu_t - TARGET_CPU_TEMP))), DRV=${drv_t}°C (Δ$((drv_t - TARGET_DRIVE_TEMP)))"
  log_info "Initial delta: $chosen_src Δ=${chosen_delta}°C → seed PWM ${seed}%"
  echo "$seed"
}

# ---------- Control Logic ----------
calculate_fan_adjustment() {
  local temp=$1 target=$2 delta=$((temp - target)) adjustment=0
  # deadband
  if [ "$delta" -ge "-$DEADBAND" ] && [ "$delta" -le "$DEADBAND" ]; then echo 0; return; fi

  if [ "$delta" -gt 0 ]; then
    if   [ "$delta" -le 2 ]; then adjustment=1
    elif [ "$delta" -le 4 ]; then adjustment=2
    elif [ "$delta" -le 6 ]; then adjustment=4
    elif [ "$delta" -le 10 ]; then adjustment=8
    else adjustment=$MAX_STEP_CHANGE; fi
  else
    delta=$(( -delta ))
    if   [ "$delta" -le 2 ]; then adjustment=-1
    elif [ "$delta" -le 4 ]; then adjustment=-2
    elif [ "$delta" -le 8 ]; then adjustment=-3
    else adjustment=-5; fi
  fi

  if [ "$oscillation_count" -gt 2 ]; then
    if [ "$adjustment" -gt 1 ] || [ "$adjustment" -lt -1 ]; then
      local old=$adjustment; adjustment=$((adjustment/2)); [ "$adjustment" -eq 0 ] && adjustment=1
      log_info "Oscillation dampening: $old -> $adjustment"
    fi
  fi
  echo "$adjustment"
}

detect_oscillation() {
  local new_dir=$1
  if [ "$new_dir" -ne 0 ] && [ "$last_direction" -ne 0 ]; then
    if [ "$new_dir" -ne "$last_direction" ]; then
      oscillation_count=$((oscillation_count + 1))
      [ "$oscillation_count" -gt 3 ] && log_warn "Oscillation detected: $oscillation_count"
    else
      [ "$oscillation_count" -gt 0 ] && oscillation_count=$((oscillation_count - 1))
    fi
  fi
  last_direction=$new_dir
}

set_fan_speed() {
  local speed=$1 s=$speed
  [ "$s" -lt "$MIN_FAN_SPEED" ] && { log_debug "Clamp $s -> $MIN_FAN_SPEED"; s=$MIN_FAN_SPEED; }
  [ "$s" -gt "$MAX_FAN_SPEED" ] && { log_debug "Clamp $s -> $MAX_FAN_SPEED"; s=$MAX_FAN_SPEED; }
  log_info "Setting fan: ${current_fan_speed}% → ${s}%"
  if /usr/local/bin/fan "$s" >/dev/null 2>&1; then
    last_fan_speed=$current_fan_speed
    current_fan_speed=$s
    cycles_at_speed=0
    return 0
  else
    log_error "Failed to set fan to ${s}%"
    return 1
  fi
}

cleanup() {
  log_info "Shutdown signal received"
  log_info "Final: Fan=${current_fan_speed}%, Osc=${oscillation_count}"
  log_info "Fan Control Stopped"
  log_info "============================================"
  exit 0
}
trap cleanup INT TERM

# ---------- Boot ----------
require_cmds
init_logging

# Choose a sensible seed from *initial delta*
seed=$(choose_initial_speed_from_temps || echo "$INITIAL_FAN_SPEED")
current_fan_speed="$seed"
last_fan_speed="$seed"

# Apply initial fan speed (your /usr/local/bin/fan also sets manual mode)
log_info "Applying initial fan speed ${current_fan_speed}%"
if ! set_fan_speed "$current_fan_speed"; then
  log_error "Failed to set initial speed; check IPMI connectivity (host: $IPMI_HOST)"
  exit 1
fi

log_info "Entering control loop"
loop_iteration=0

while true; do
  loop_iteration=$((loop_iteration + 1))

  # Read temps
  cpu_data=$(get_cpu_max_temp); cpu_temp=${cpu_data%%:*}
  drv_data=$(get_drive_max_temp); drv_temp=${drv_data%%:*}
  [ -z "${cpu_temp:-}" ] && cpu_temp=0
  [ -z "${drv_temp:-}" ] && drv_temp=0

  # Compute adjustments
  adj_cpu=0; adj_drv=0
  [ "$cpu_temp" -gt 0 ] && adj_cpu=$(calculate_fan_adjustment "$cpu_temp" "$TARGET_CPU_TEMP")
  [ "$drv_temp" -gt 0 ] && adj_drv=$(calculate_fan_adjustment "$drv_temp" "$TARGET_DRIVE_TEMP")

  # Choose stronger by magnitude
  if [ "$(abs "$adj_cpu")" -ge "$(abs "$adj_drv")" ]; then
    chosen_adj="$adj_cpu"; chosen_src="CPU"; chosen_delta=$((cpu_temp - TARGET_CPU_TEMP))
  else
    chosen_adj="$adj_drv"; chosen_src="DRIVE"; chosen_delta=$((drv_temp - TARGET_DRIVE_TEMP))
  fi

  if [ "$chosen_adj" -ne 0 ]; then
    # settle small ±1 moves
    if [ "$chosen_adj" -eq 1 ] || [ "$chosen_adj" -eq -1 ]; then
      if [ "$cycles_at_speed" -lt "$SETTLE_TIME" ]; then
        log_info "CPU=${cpu_temp}°C DRV=${drv_temp}°C | Fan=${current_fan_speed}% | Settling (${cycles_at_speed}/${SETTLE_TIME}) [${chosen_src}]"
        sleep "$CHECK_INTERVAL"
        cycles_at_speed=$((cycles_at_speed + 1))
        continue
      fi
    fi

    # direction for oscillation detection
    if [ "$chosen_adj" -gt 0 ]; then detect_oscillation 1; else detect_oscillation -1; fi

    new_speed=$((current_fan_speed + chosen_adj))
    if set_fan_speed "$new_speed"; then
      log_info "CPU=${cpu_temp}°C (T${TARGET_CPU_TEMP}) DRV=${drv_temp}°C (T${TARGET_DRIVE_TEMP}) | Fan ${last_fan_speed}%→${current_fan_speed}% | Δ=${chosen_delta}°C [${chosen_src}]"
    else
      log_error "Failed to change fan ${current_fan_speed}%→${new_speed}%"
    fi
  else
    cycles_at_speed=$((cycles_at_speed + 1))
    if   [ "$cycles_at_speed" -eq 10 ]; then
      log_info "Steady: CPU=${cpu_temp}°C DRV=${drv_temp}°C | Fan=${current_fan_speed}%"
    elif [ "$cycles_at_speed" -lt 10 ]; then
      log_info "Stable: CPU=${cpu_temp}°C DRV=${drv_temp}°C | Fan=${current_fan_speed}%"
    elif [ "$cycles_at_speed" -eq 50 ] || [ "$cycles_at_speed" -eq 100 ] || [ "$cycles_at_speed" -eq 200 ]; then
      log_info "Status: CPU=${cpu_temp}°C DRV=${drv_temp}°C | Fan=${current_fan_speed}% | Stable for $cycles_at_speed cycles"
    fi
    [ "$oscillation_count" -gt 0 ] && oscillation_count=$((oscillation_count - 1))
  fi

  sleep "$CHECK_INTERVAL"
done

