#!/bin/sh

# Read interface names from environment variables
ETHERNET_IFACE=${ETHERNET_INTERFACE_NAME}
LTE_IFACE=${LTE_INTERFACE_NAME}
LOSS_THRESHOLD=100
FAILURE_START=0  # Timestamp of first full failure
TIME=$(( (${THRESHOLD_TIME:-15}) * 60))

# Ensure sysrq is enabled for reboot
echo 1 > /proc/sys/kernel/sysrq

echo "$(date '+%Y-%m-%d %H:%M:%S') - Monitoring Internet Access"
echo "$(date '+%Y-%m-%d %H:%M:%S') - Interfaces: Ethernet=$ETHERNET_IFACE, LTE=$LTE_IFACE"

while true; do
    # Function to get packet loss percentage for a given interface
    get_packet_loss() {
        iface=$1
        result=$(ping -I "$iface" -c 5 -w 10 8.8.8.8 2>/dev/null)
        if [ $? -ne 0 ]; then
            echo 100
        else
            echo "$result" | grep -oP '\d+(?=% packet loss)' | head -1
        fi
    }

    # Check both interfaces
    ethernet_loss=$(get_packet_loss "$ETHERNET_IFACE")
    lte_loss=$(get_packet_loss "$LTE_IFACE")

    echo "$(date '+%Y-%m-%d %H:%M:%S') - Ethernet ($ETHERNET_IFACE) Loss: ${ethernet_loss}%, LTE ($LTE_IFACE) Loss: ${lte_loss}%"

    if [ "$ethernet_loss" -ge "$LOSS_THRESHOLD" ] && [ "$lte_loss" -ge "$LOSS_THRESHOLD" ]; then
        if [ "$FAILURE_START" -eq 0 ]; then
            FAILURE_START=$(date +%s)
            echo "$(date '+%Y-%m-%d %H:%M:%S') - Internet down on both interfaces. Starting countdown..."
        fi

        current_time=$(date +%s)
        elapsed=$((current_time - FAILURE_START))

        if [ "$elapsed" -ge $TIME ]; then
		echo "$(date '+%Y-%m-%d %H:%M:%S') - No internet on both interfaces for the last $((TIME / 60)) minutes. Rebooting now..."
            echo b > /proc/sysrq-trigger
        fi
    else
        if [ "$FAILURE_START" -ne 0 ]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') - Internet recovered on at least one interface. Resetting failure timer."
        fi
        FAILURE_START=0
    fi
done

