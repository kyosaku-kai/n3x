#!/bin/bash
# =============================================================================
# sgdisk wrapper - WSL2 sync() hang workaround
# =============================================================================
#
# This wrapper intercepts sgdisk calls and disables the problematic sync()
# by setting LD_PRELOAD to override the sync() function with a no-op.
#
# The nosync.so library overrides only sync() - fsync() still works for
# per-file syncs, so data integrity is maintained.
#
# The real sgdisk binary is at /usr/bin/sgdisk.real
#
# =============================================================================

# Only use LD_PRELOAD if the nosync library exists
if [ -f /usr/lib/nosync.so ]; then
    exec env LD_PRELOAD=/usr/lib/nosync.so /usr/bin/sgdisk.real "$@"
else
    exec /usr/bin/sgdisk.real "$@"
fi
