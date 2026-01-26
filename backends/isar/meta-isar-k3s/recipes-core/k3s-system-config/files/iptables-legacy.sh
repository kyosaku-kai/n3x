#!/bin/sh
# Configure iptables to use legacy mode (required for k3s)
# k3s requires iptables-legacy, not nftables backend

set -e

# Only run if update-alternatives exists and iptables is available
if command -v update-alternatives >/dev/null 2>&1; then
    # Set iptables to legacy mode
    if update-alternatives --list iptables 2>/dev/null | grep -q legacy; then
        update-alternatives --set iptables /usr/sbin/iptables-legacy 2>/dev/null || true
        update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy 2>/dev/null || true
    fi
fi

exit 0
