#!/bin/bash
# =============================================================================
# NixOS Test Driver Backdoor Script
# =============================================================================
#
# This script is the guest-side component that allows the NixOS test driver
# to execute commands inside the VM via virtio-console (/dev/hvc0).
#
# Protocol:
#   1. Service starts and redirects stdin/stdout to /dev/hvc0
#   2. Redirects stderr to serial console (/dev/ttyS0) for debug output
#   3. Prints "Spawning backdoor root shell..." - the test driver waits for this
#   4. exec's bash which reads commands from the test driver
#
# Reference:
#   Based on NixOS test-instrumentation.nix:28-71
#   https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/testing/test-instrumentation.nix
#
# =============================================================================

# Work directory for command execution
cd /tmp

# Wait for serial console to become available for debug output BEFORE redirecting
# This ensures we have debug output capability from the start
while ! [ -e /dev/ttyS0 ]; do
    sleep 0.1
done

# Create a debug log function that writes to BOTH serial AND a file
# The file is useful for post-mortem analysis
DEBUG_LOG="/tmp/backdoor-debug.log"
exec 3>/dev/ttyS0  # FD 3 for debug output to serial
exec 4>>"$DEBUG_LOG"  # FD 4 for debug log file

debug() {
    local msg="[backdoor $(date '+%H:%M:%S.%N')] $*"
    echo "$msg" >&3  # to serial
    echo "$msg" >&4  # to log file
}

debug "=== Backdoor script starting ==="
debug "PID: $$"
debug "Current console settings:"
cat /proc/consoles >&3 2>&1 || true
cat /proc/consoles >&4 2>&1 || true

# CRITICAL: Redirect kernel console messages AWAY from hvc0
# printk messages can corrupt the backdoor protocol
debug "Redirecting kernel printk to ttyS0..."
if [ -e /proc/sys/kernel/printk_devkmsg ]; then
    echo "off" > /proc/sys/kernel/printk_devkmsg 2>/dev/null || true
fi
# Set kernel log level to emergencies only
echo "1" > /proc/sys/kernel/printk 2>/dev/null || debug "Cannot set printk level"

# Check what's currently using hvc0
debug "Checking processes using hvc0:"
fuser /dev/hvc0 >&3 2>&1 || debug "fuser not available or no processes"
lsof /dev/hvc0 >&3 2>&1 || debug "lsof not available or no processes"

debug "Redirecting stdin/stdout to /dev/hvc0..."
# Redirect stdin and stdout to virtio-console
exec < /dev/hvc0 > /dev/hvc0

# Now stderr needs to go somewhere useful - use FD 3 (serial)
exec 2>&3

debug "Setting hvc0 to raw mode..."
# Configure the virtio-console for raw mode
# -echo: don't echo input back (test driver handles this)
# raw: disable all line processing
stty -F /dev/hvc0 raw -echo

debug "About to print magic string..."
# CRITICAL: This exact string is what the test driver waits for!
# See nixpkgs/nixos/lib/test-driver/src/test_driver/machine/__init__.py:862
echo "Spawning backdoor root shell..."
debug "Magic string sent, exec'ing bash..."

# Replace this process with bash
# --norc: don't read .bashrc (we want a clean shell)
# PS1="": empty prompt to avoid polluting output
# stdin/stdout are already redirected to /dev/hvc0, so just exec bash
PS1="" exec bash --norc
