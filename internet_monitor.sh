#!/bin/sh

# Configuration
MAX_THRESHOLD_COUNT=${MAX_THRESHOLD_COUNT:-200}
FAILURE_DECREMENT_FACTOR=${FAILURE_DECREMENT_FACTOR:-10}
SUCCESS_INCREMENT_FACTOR=${SUCCESS_INCREMENT_FACTOR:-1}
THRESHOLD_TIME=${THRESHOLD_TIME:-60}  # Minutes
TIME_LIMIT=$((THRESHOLD_TIME * 60))

# Read interface names from environment variables
ETHERNET_IFACE=${ETHERNET_INTERFACE_NAME}
LTE_IFACE=${LTE_INTERFACE_NAME}
WWAN_CONTROL_DEVICE=${WAN_CONTROL_DEVICE:-cdc-wdm0}

# Persistent reboot state shared with nm-carrier-manager
STATE_DIR=${STATE_DIR:-/var/lib/va-state}
STATE_FILE=${STATE_FILE:-/var/lib/va-state/state.env}

# Initialize
THRESHOLD=$MAX_THRESHOLD_COUNT
INITIAL_FAIL_TIME=0
PACKET_LOSS=100 #Default global
PING_INTERVAL=${PING_INTERVAL:-60}
WATCHDOG_DEV="/dev/watchdog"

# set true/1/yes to enable watchdog
WATCHDOG_ENABLE=${WATCHDOG_ENABLE:-0}
LOG_LEVEL=$(echo "${LOG_LEVEL:-ERROR}" | tr '[:lower:]' '[:upper:]')

# Map log levels to numeric values for easy comparison
log_level_value() {
    case "$1" in
        DEBUG) echo 0 ;;
        INFO) echo 1 ;;
        WARNING) echo 2 ;;
        ERROR) echo 3 ;;
        ALERT) echo 4 ;;
        *) echo 1 ;;  # Default to INFO on unknown
    esac
}

# Log helper that respects configured LOG_LEVEL
log() {
    level=$(echo "$1" | tr '[:lower:]' '[:upper:]')
    shift
    message="$*"

    [ -z "$message" ] && return

    configured_value=$(log_level_value "$LOG_LEVEL")
    message_value=$(log_level_value "$level")

    if [ "$message_value" -lt "$configured_value" ]; then
        return
    fi

    echo "$(date '+%Y-%m-%d %H:%M:%S') - ${level} - $message"
}

get_active_nm_connection_from_device() {
    dev="$1"

    conn=$(nmcli -t -f GENERAL.CONNECTION device show "$dev" 2>/dev/null | cut -d: -f2)
    if [ -n "$conn" ]; then
        printf "%s" "$conn"
    fi
}

write_lte_reboot_state() {
    if [ ! -d "$STATE_DIR" ]; then
        log ERROR "State directory does not exist: $STATE_DIR"
        return 1
    fi

    count=0
    if [ -f "$STATE_FILE" ]; then
        . "$STATE_FILE" 2>/dev/null
        if [ "${CAUSE:-}" = "lte_no_internet_reboot" ]; then
            count=${COUNT:-0}
        fi
    fi

    count=$((count + 1))
    saved_connection="$(get_active_nm_connection_from_device "$WWAN_CONTROL_DEVICE")"

    {
        echo "CAUSE='lte_no_internet_reboot'"
        echo "COUNT='${count}'"
        echo "SAVED_CONNECTION='${saved_connection}'"
        echo "TIMESTAMP='$(date -u +%Y-%m-%dT%H:%M:%SZ)'"
    } > "$STATE_FILE"

    log ALERT "Saved LTE reboot state: COUNT=${count}, SAVED_CONNECTION=${saved_connection:-none}"
}

# Enable sysrq for reboot
echo 1 > /proc/sys/kernel/sysrq

log INFO "Internet Monitor Started"
log INFO "Interfaces: Ethernet=$ETHERNET_IFACE, LTE=$LTE_IFACE"

watchdog_thread() {

    if [ ! -w "$WATCHDOG_DEV" ]; then
        log ERROR "Watchdog device not found or not writable"
        return
    fi

    while true; do
        # Simple feed every 5 seconds
	if echo > "$WATCHDOG_DEV" 2>/dev/null; then
	    log DEBUG "Watchdog fed"
	else
	    log ERROR "Failed to feed watchdog"
	    break
	fi
	sleep 5
    done
}

# Start watchdog only when WATCHDOG_ENABLE=1
if [ "$WATCHDOG_ENABLE" -eq 1 ]; then
    watchdog_thread &
    log INFO "Watchdog enabled"
else
    log INFO "Watchdog disabled (set WATCHDOG_ENABLE=1 to enable)"
fi

# Function to get packet loss
get_packet_loss() {
    iface=$1

    if [ -z "$iface" ]; then
	return
    fi
    result=$(ping -I "$iface" -c 1 -W 5 8.8.8.8 2>/dev/null)

    loss_line=$(echo "$result" | grep -oE '[0-9]+% packet loss')
    if [ -n "$loss_line" ]; then
        loss_value=$(echo "$loss_line" | awk '{print $1}' | tr -d '%')
	if echo "$loss_value" | grep -qE '^[0-9]+$' && [ "$loss_value" -le 100 ]; then
            PACKET_LOSS=$loss_value
        fi
    else
	PACKET_LOSS=100
    fi
}

while true; do
    BOTH_FAIL=true
    ETH_FAIL=false
    LTE_FAIL=false

    for iface in "$ETHERNET_IFACE" "$LTE_IFACE"; do
        [ -z "$iface" ] && continue

        get_packet_loss "$iface"
        loss=$PACKET_LOSS

        log INFO "$iface Loss: ${loss}%"

        if [ "$loss" = "100" ]; then
            # Failed ping
            if [ "$iface" = "$ETHERNET_IFACE" ]; then
                ETH_FAIL=true
            fi
            if [ "$iface" = "$LTE_IFACE" ]; then
                LTE_FAIL=true
            fi
        else
            # Successful ping
            BOTH_FAIL=false
        fi
    done

    if $ETH_FAIL && $LTE_FAIL; then
        # Only reduce threshold if both failed
        if [ "$INITIAL_FAIL_TIME" -eq 0 ]; then
            INITIAL_FAIL_TIME=$(date +%s)
        fi
        THRESHOLD=$((THRESHOLD - FAILURE_DECREMENT_FACTOR))
    else
        # At least one is up → increase threshold
        THRESHOLD=$((THRESHOLD + SUCCESS_INCREMENT_FACTOR))
        INITIAL_FAIL_TIME=0
    fi

    # Clamp THRESHOLD between 0 and MAX

    if [ "$THRESHOLD" -gt "$MAX_THRESHOLD_COUNT" ]; then
        THRESHOLD=$MAX_THRESHOLD_COUNT
    fi

    log INFO "THRESHOLD=$THRESHOLD"
    
    current_time=$(date +%s)

    if [ "$THRESHOLD" -le 0 ]; then
	log ALERT "THRESHOLD is 0. Rebooting now..."
	write_lte_reboot_state
	sync
	echo b > /proc/sysrq-trigger
    elif [ "$INITIAL_FAIL_TIME" -ne 0 ] && [ $((current_time - INITIAL_FAIL_TIME)) -ge "$TIME_LIMIT" ]; then
            log ALERT "Internet down too long while THRESHOLD > 0. Rebooting..."
	    write_lte_reboot_state
            sync
            echo b > /proc/sysrq-trigger
    
    elif [ "$INITIAL_FAIL_TIME" -ne 0 ]; then
	    failure_duration=$((current_time - INITIAL_FAIL_TIME))
	    log WARNING "Internet down on both Interfaces. Failure duration: ${failure_duration} seconds ($((failure_duration / 60)) min)."
    fi

    sleep $PING_INTERVAL
done
