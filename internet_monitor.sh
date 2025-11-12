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

# Initialize
THRESHOLD=$MAX_THRESHOLD_COUNT
INITIAL_FAIL_TIME=0
PACKET_LOSS=100 #Default global
PING_INTERVAL=${PING_INTERVAL:-60}
WATCHDOG_DEV="/dev/watchdog"

# set true/1/yes to enable watchdog
WATCHDOG_ENABLE=${WATCHDOG_ENABLE:-false}

# Enable sysrq for reboot
echo 1 > /proc/sys/kernel/sysrq

echo "$(date '+%Y-%m-%d %H:%M:%S') - Internet Monitor Started"
echo "$(date '+%Y-%m-%d %H:%M:%S') - Interfaces: Ethernet=$ETHERNET_IFACE, LTE=$LTE_IFACE"

watchdog_thread() {

    if [ ! -w "$WATCHDOG_DEV" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - ERROR: Watchdog device not found or not writable"
        return
    fi

    while true; do
        # Simple feed every 5 seconds
	if echo > "$WATCHDOG_DEV" 2>/dev/null; then
	    echo "$(date '+%Y-%m-%d %H:%M:%S') - Watchdog fed"
	else
	    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Failed to feed watchdog"
	    break
	fi
	sleep 5
    done
}

# Start watchdog thread in background
case "$(printf '%s' "$WATCHDOG_ENABLE" | tr '[:upper:]' '[:lower:]')" in
  1|true|yes|on) watchdog_thread & WATCHDOG_PID=$! ;;
  *) echo "$(date '+%Y-%m-%d %H:%M:%S') - Watchdog disabled (set WATCHDOG_ENABLE=true to enable)";;
esac

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

        echo "$(date '+%Y-%m-%d %H:%M:%S') - $iface Loss: ${loss}%"

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

    echo "$(date '+%Y-%m-%d %H:%M:%S') - THRESHOLD=$THRESHOLD"
    
    current_time=$(date +%s)

    if [ "$THRESHOLD" -le 0 ]; then
	echo "$(date '+%Y-%m-%d %H:%M:%S') - THRESHOLD is 0. Rebooting now..."
	sync
	echo b > /proc/sysrq-trigger
    elif [ "$INITIAL_FAIL_TIME" -ne 0 ] && [ $((current_time - INITIAL_FAIL_TIME)) -ge "$TIME_LIMIT" ]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') - Internet down too long while THRESHOLD > 0. Rebooting..."
            sync
            echo b > /proc/sysrq-trigger
    
    elif [ "$INITIAL_FAIL_TIME" -ne 0 ]; then
	    failure_duration=$((current_time - INITIAL_FAIL_TIME))
	    echo "$(date '+%Y-%m-%d %H:%M:%S') - Internet down on both Interfaces. Failure duration: ${failure_duration} seconds ($((failure_duration / 60)) min)."
    fi

    sleep $PING_INTERVAL
done
