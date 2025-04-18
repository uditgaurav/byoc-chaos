FROM bitnami/aws-cli:2

# Use root for installation and runtime
USER root

# Set working directory
WORKDIR /app

# Install jq (bash is already present)
RUN apt-get update && \
    apt-get install -y --no-install-recommends jq && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Copy the chaos script and set permissions
COPY chaos.sh .
RUN chmod +x chaos.sh

# Run the script as default
ENTRYPOINT ["./chaos.sh"]
