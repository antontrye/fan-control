#!/usr/bin/env bash

# Alpine LXC Container Setup Script for Fan Control

set -euo pipefail

# Set script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check if files directory exists
if [ ! -d "$SCRIPT_DIR/files" ]; then
    echo "ERROR: files directory not found at $SCRIPT_DIR/files"
    echo "Please ensure all required files are present in the files/ directory"
    exit 1
fi

# Parse command line arguments
DEBUG_MODE=false
CUSTOM_ROOTFS=""
SHOW_HELP=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --debug)
            DEBUG_MODE=true
            echo "Debug mode enabled - container will NOT be removed on failure"
            shift
            ;;
        --rootfs)
            CUSTOM_ROOTFS="$2"
            shift 2
            ;;
        --help|-h)
            SHOW_HELP=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            SHOW_HELP=true
            shift
            ;;
    esac
done

if [ "$SHOW_HELP" = true ]; then
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --debug        Enable debug mode (container preserved on failure)"
    echo "  --rootfs PATH  Use custom Alpine rootfs tarball instead of downloading"
    echo "  -h, --help     Show this help message"
    echo ""
    echo "By default, downloads the latest Alpine minirootfs from the official repository."
    exit 0
fi

# Cleanup function
cleanup_on_failure() {
    local exit_code=$?

    if [ $exit_code -ne 0 ] && [ "$DEBUG_MODE" = false ]; then
        echo ""
        echo "ERROR: Setup failed! Cleaning up..."

        if [ -n "${CONTAINER_ID:-}" ]; then
            # Stop container if running
            if pct status $CONTAINER_ID 2>/dev/null | grep -q "running"; then
                echo "Stopping container $CONTAINER_ID..."
                pct stop $CONTAINER_ID 2>/dev/null || true
                sleep 2
            fi

            # Destroy container
            if pct list 2>/dev/null | grep -q "^$CONTAINER_ID "; then
                echo "Removing container $CONTAINER_ID..."
                pct destroy $CONTAINER_ID --force 2>/dev/null || true
            fi
        fi

        # Clean up temporary files
        rm -f /tmp/ipmi.conf.$$ 2>/dev/null || true
        rm -f "$SCRIPT_DIR"/*.tmp 2>/dev/null || true

        echo "Cleanup complete. Please check your configuration and try again."
        echo "Run with --debug to keep the container for troubleshooting."
    elif [ $exit_code -ne 0 ] && [ "$DEBUG_MODE" = true ]; then
        echo ""
        echo "ERROR: Setup failed! (Debug mode - container preserved)"
        echo "Container ID: ${CONTAINER_ID:-unknown}"
        echo "You can manually inspect/remove with: pct destroy ${CONTAINER_ID:-}"
    fi

    exit $exit_code
}

# Set trap for cleanup
trap cleanup_on_failure EXIT

# Find .env file - check script directory first, then home directory
if [ -f "$SCRIPT_DIR/.env" ]; then
    CONFIG_FILE="$SCRIPT_DIR/.env"
    echo "Using config: $CONFIG_FILE"
    source "$CONFIG_FILE"
elif [ -f "$HOME/.env" ]; then
    CONFIG_FILE="$HOME/.env"
    echo "Using config: $CONFIG_FILE"
    source "$CONFIG_FILE"
else
    # Check if required variables are already set (e.g., from environment)
    required_vars=(\
      CONTAINER_ID \
      CONTAINER_NAME \
      STORAGE \
      DISK_SIZE \
      MEMORY \
      BRIDGE \
      IPMI_HOST \
      IPMI_USER \
      IPMI_PASS \
      IPMI_KEY \
    )
    missing_vars=()

    for var in "${required_vars[@]}"; do
        if [ -z "${!var:-}" ]; then
            missing_vars+=("$var")
        fi
    done

    if [ ${#missing_vars[@]} -gt 0 ]; then
        echo "ERROR: .env file not found and required variables are not set"
        echo "Missing variables: ${missing_vars[*]}"
        echo "Please either:"
        echo "  1. Copy .env.example to .env and edit it"
        echo "  2. Export the required variables before running this script"
        exit 1
    else
        echo "Using environment variables (no .env file found)"
    fi
fi

# Verify required files exist
required_files=(
    "files/interfaces"
    "files/ipmi.conf.template"
    "files/fan"
    "files/fan_control.sh"
    "files/fan_control.init"
    "files/fan_control.logrotate"
)

echo "Checking required files..."
for file in "${required_files[@]}"; do
    if [ ! -f "$SCRIPT_DIR/$file" ]; then
        echo "ERROR: Required file not found: $file"
        exit 1
    fi
done
echo "All required files present"

# Check if container already exists
if pct list 2>/dev/null | grep -q "^$CONTAINER_ID "; then
    echo "ERROR: Container $CONTAINER_ID already exists!"
    echo "Please remove it first with: pct destroy $CONTAINER_ID"
    exit 1
fi

# Handle Alpine rootfs
if [ -n "$CUSTOM_ROOTFS" ]; then
    # User provided custom rootfs
    if [ ! -f "$CUSTOM_ROOTFS" ]; then
        echo "ERROR: Custom rootfs not found: $CUSTOM_ROOTFS"
        exit 1
    fi
    ROOTFS_TARBALL="$CUSTOM_ROOTFS"
    echo "Using custom rootfs: $ROOTFS_TARBALL"
else
    # Download latest Alpine minirootfs
    echo "Fetching latest Alpine Linux release information..."
    
    # Get the latest Alpine version
    ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine"
    LATEST_VERSION=$(curl -s "$ALPINE_MIRROR/latest-stable/releases/x86_64/latest-releases.yaml" | grep -m1 "version:" | awk '{print $2}')
    
    if [ -z "$LATEST_VERSION" ]; then
        echo "ERROR: Failed to determine latest Alpine version"
        echo "Please download manually and use --rootfs option"
        exit 1
    fi
    
    # Construct download URL
    ALPINE_ARCH="x86_64"
    ALPINE_FILE="alpine-minirootfs-${LATEST_VERSION}-${ALPINE_ARCH}.tar.gz"
    DOWNLOAD_URL="${ALPINE_MIRROR}/latest-stable/releases/${ALPINE_ARCH}/${ALPINE_FILE}"
    
    # Check if we already have this version
    if [ -f "$SCRIPT_DIR/$ALPINE_FILE" ]; then
        echo "Found existing Alpine rootfs: $ALPINE_FILE (v$LATEST_VERSION)"
        ROOTFS_TARBALL="$SCRIPT_DIR/$ALPINE_FILE"
    else
        # Download the rootfs
        echo "Downloading Alpine Linux v$LATEST_VERSION minirootfs..."
        echo "URL: $DOWNLOAD_URL"
        
        if ! curl -L -o "$SCRIPT_DIR/$ALPINE_FILE.tmp" "$DOWNLOAD_URL"; then
            echo "ERROR: Failed to download Alpine rootfs"
            echo "Please check your internet connection or download manually"
            exit 1
        fi
        
        # Move to final location
        mv "$SCRIPT_DIR/$ALPINE_FILE.tmp" "$SCRIPT_DIR/$ALPINE_FILE"
        ROOTFS_TARBALL="$SCRIPT_DIR/$ALPINE_FILE"
        
        echo "Successfully downloaded: $ALPINE_FILE"
        
        # Clean up older versions (optional)
        echo "Cleaning up older Alpine rootfs files..."
        find "$SCRIPT_DIR" -name "alpine-minirootfs-*.tar.gz" ! -name "$ALPINE_FILE" -type f -exec rm -f {} \; 2>/dev/null || true
    fi
fi

# Final check that rootfs exists
if [ ! -f "$ROOTFS_TARBALL" ]; then
    echo "ERROR: Root filesystem tarball not found: $ROOTFS_TARBALL"
    exit 1
fi

echo "Creating Alpine container from minimal rootfs..."
echo "Container ID: $CONTAINER_ID"
echo "Container Name: $CONTAINER_NAME"

# Create container
pct create $CONTAINER_ID $ROOTFS_TARBALL \
    --hostname $CONTAINER_NAME \
    --memory $MEMORY \
    --rootfs $STORAGE:$DISK_SIZE \
    --unprivileged 0 \
    --net0 name=eth0,bridge=$BRIDGE,ip=dhcp \
    --ostype alpine \
    --console 1 \
    --start 0

echo "Starting container..."
pct start $CONTAINER_ID
sleep 5

# Wait for container with timeout
echo "Waiting for container to be ready..."
if ! timeout 30 bash -c "until pct exec $CONTAINER_ID -- true 2>/dev/null; do sleep 1; done"; then
    echo "ERROR: Container failed to start within 30 seconds"
    exit 1
fi

echo "Configuring network..."

# Copy network configuration
pct push $CONTAINER_ID "$SCRIPT_DIR/files/interfaces" /etc/network/interfaces

pct exec $CONTAINER_ID -- rc-service networking restart || true
sleep 3

echo "Installing packages..."

# Install minimal packages
if ! pct exec $CONTAINER_ID -- apk update; then
    echo "ERROR: Failed to update package repositories"
    echo "Check network connectivity in the container"
    exit 1
fi

if ! pct exec $CONTAINER_ID -- apk add --no-cache bash ipmitool lm-sensors openrc logrotate; then
    echo "ERROR: Failed to install required packages"
    exit 1
fi

echo "Deploying configuration..."

# Create secure credentials file from template
cp "$SCRIPT_DIR/files/ipmi.conf.template" "/tmp/ipmi.conf.$$"
sed -i "s/__IPMI_HOST__/$IPMI_HOST/g" "/tmp/ipmi.conf.$$"
sed -i "s/__IPMI_USER__/$IPMI_USER/g" "/tmp/ipmi.conf.$$"
sed -i "s/__IPMI_PASS__/$IPMI_PASS/g" "/tmp/ipmi.conf.$$"
sed -i "s/__IPMI_KEY__/$IPMI_KEY/g" "/tmp/ipmi.conf.$$"

# Deploy IPMI configuration
pct push $CONTAINER_ID "/tmp/ipmi.conf.$$" /etc/ipmi.conf
rm -f "/tmp/ipmi.conf.$$"
pct exec $CONTAINER_ID -- chmod 600 /etc/ipmi.conf

echo "Deploying fan control scripts..."

# Deploy fan command
pct push $CONTAINER_ID "$SCRIPT_DIR/files/fan" /usr/local/bin/fan
pct exec $CONTAINER_ID -- chmod 755 /usr/local/bin/fan

# Deploy main fan control script
pct push $CONTAINER_ID "$SCRIPT_DIR/files/fan_control.sh" /usr/local/bin/fan_control.sh
pct exec $CONTAINER_ID -- chmod 755 /usr/local/bin/fan_control.sh

echo "Configuring logrotate..."

# Deploy logrotate configuration
pct push $CONTAINER_ID "$SCRIPT_DIR/files/fan_control.logrotate" /etc/logrotate.d/fan_control

echo "Creating OpenRC service..."

# Deploy init.d service
pct push $CONTAINER_ID "$SCRIPT_DIR/files/fan_control.init" /etc/init.d/fan_control
pct exec $CONTAINER_ID -- chmod 755 /etc/init.d/fan_control

# Enable and start service
echo "Enabling fan control service..."
pct exec $CONTAINER_ID -- rc-update add fan_control default

echo "Starting fan control service..."
if ! pct exec $CONTAINER_ID -- rc-service fan_control start; then
    echo "WARNING: Failed to start fan_control service"
    echo "You may need to start it manually after checking IPMI connectivity"
fi

# Clear the trap - setup succeeded
trap - EXIT

echo ""
echo "==========================================="
echo "Alpine Fan Control Setup Complete!"
echo ""
echo "Container: $CONTAINER_ID ($CONTAINER_NAME)"
echo "Target Temp: 75°C"
echo "Log Size: 50MB max (auto-rotating)"
echo ""
echo "Useful Commands:"
echo ""
echo "  Follow live logs:"
echo "    pct exec $CONTAINER_ID -- tail -f /var/log/fan_control.log"
echo ""
echo "  View recent logs:"
echo "    pct exec $CONTAINER_ID -- tail -n 50 /var/log/fan_control.log"
echo ""
echo "  Service control:"
echo "    pct exec $CONTAINER_ID -- rc-service fan_control status"
echo "    pct exec $CONTAINER_ID -- rc-service fan_control restart"
echo ""
echo "  Manual fan test:"
echo "    pct exec $CONTAINER_ID -- /usr/local/bin/fan 50"
echo ""
echo "  Enter container:"
echo "    pct enter $CONTAINER_ID"
echo ""
echo "Log Levels: Set LOG_LEVEL=\"DEBUG\" in /usr/local/bin/fan_control.sh for verbose output"
echo "==========================================="