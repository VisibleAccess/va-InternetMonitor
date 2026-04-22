FROM livekit/gstreamer:1.24.5-prod-rs

RUN apt-get update && apt-get install -y \
    iproute2 \
    iputils-ping \
    network-manager \
    && rm -rf /var/lib/apt/lists/*


# Copy your custom scripts and files
COPY ./internet_monitor.sh /usr/local/bin/internet_monitor.sh

# Make the scripts executable
RUN chmod +x /usr/local/bin/internet_monitor.sh

# Set the default command to run the setup script and keep the container running
CMD ["/bin/bash", "-c", "/usr/local/bin/internet_monitor.sh && /bin/bash"]                                                                                      
