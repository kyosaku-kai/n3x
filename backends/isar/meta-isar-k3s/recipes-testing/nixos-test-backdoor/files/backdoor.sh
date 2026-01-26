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

# Redirect stdin and stdout to virtio-console
exec < /dev/hvc0 > /dev/hvc0

# Wait for serial console to become available for stderr (debug output)
# This matches the NixOS behavior - stderr goes to serial for visibility
while ! exec 2> /dev/ttyS0; do
    sleep 0.1
done

echo "connecting to host..." >&2

# Configure the virtio-console for raw mode
# -echo: don't echo input back (test driver handles this)
# raw: disable all line processing
stty -F /dev/hvc0 raw -echo

# CRITICAL: This exact string is what the test driver waits for!
# See nixpkgs/nixos/lib/test-driver/src/test_driver/machine/__init__.py:862
echo "Spawning backdoor root shell..."

# Replace this process with bash
# --norc: don't read .bashrc (we want a clean shell)
# PS1="": empty prompt to avoid polluting output
# stdin/stdout are already redirected to /dev/hvc0, so just exec bash
PS1="" exec bash --norc
