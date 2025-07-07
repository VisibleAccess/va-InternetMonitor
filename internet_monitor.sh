#!/bin/sh

# Configuration
MAX_THRESHOLD_COUNT=${MAX_THRESHOLD_COUNT:-200}
FAILURE_DECREMENT_FACTOR=${FAILURE_DECREMENT_FACTOR:-10}
SUCCESS_INCREMENT_FACTOR=${SUCCESS_INCREMENT_FACTOR:-1}
THRESHOLD_TIME=${THRESHOLD_TIME:-10}  # Minutes
TIME_LIMIT=$((THRESHOLD_TIME * 60))

# Read interface names from environment variables
ETHERNET_IFACE=${ETHERNET_INTERFACE_NAME}
LTE_IFACE=${LTE_INTERFACE_NAME}

# Initialize
THRESHOLD=$MAX_THRESHOLD_COUNT
FAILURE_START=0
INITIAL_FAIL_TIME=0

# Enable sysrq for reboot
echo 1 > /proc/sys/kernel/sysrq

echo "$(date '+%Y-%m-%d %H:%M:%S') - Internet Monitor Started"
echo "$(date '+%Y-%m-%d %H:%M:%S') - Interfaces: Ethernet=$ETHERNET_IFACE, LTE=$LTE_IFACE"

# Function to get packet loss
get_packet_loss() {
    iface=$1
    result=$(ping -I "$iface" -c 1 -W 5 8.8.8.8 2>/dev/null)
    if [ $? -ne 0 ]; then
        echo 100
    else
        echo "$result" | grep -oP '\d+(?=% packet loss)' | head -1
    fi
}

while true; do
    BOTH_FAIL=true
    ETH_FAIL=false
    LTE_FAIL=false

    for iface in "$ETHERNET_IFACE" "$LTE_IFACE"; do
        [ -z "$iface" ] && continue

        loss=$(get_packet_loss "$iface")
        loss=${loss:-100}  # Default to 100% if empty

        echo "$(date '+%Y-%m-%d %H:%M:%S') - $iface Loss: ${loss}%"

        if [ "$loss" -eq 100 ]; then
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
        FAILURE_START=0
    fi

    # Clamp THRESHOLD between 0 and MAX
    if [ "$THRESHOLD" -lt 0 ]; then
        THRESHOLD=0
    elif [ "$THRESHOLD" -gt "$MAX_THRESHOLD_COUNT" ]; then
        THRESHOLD=$MAX_THRESHOLD_COUNT
    fi

    echo "$(date '+%Y-%m-%d %H:%M:%S') - THRESHOLD=$THRESHOLD"
    
    current_time=$(date +%s)

    if [ "$THRESHOLD" -eq 0 ]; then
        if [ "$FAILURE_START" -eq 1 ]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') - THRESHOLD is 0 and FAILURE_START=1. Rebooting now..."
            echo b > /proc/sysrq-trigger
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') - THRESHOLD is 0. Setting FAILURE_START=1"
            FAILURE_START=1
        fi
    else
        if [ "$INITIAL_FAIL_TIME" -ne 0 ] && [ $((current_time - INITIAL_FAIL_TIME)) -ge "$TIME_LIMIT" ]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') - Internet down too long while THRESHOLD > 0. Rebooting..."
            echo b > /proc/sysrq-trigger
        fi
        FAILURE_START=0
    fi

    sleep 5
done
