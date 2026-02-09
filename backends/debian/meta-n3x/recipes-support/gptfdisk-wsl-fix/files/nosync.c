/*
 * nosync.c - LD_PRELOAD library to disable sync() syscall
 *
 * PURPOSE:
 *   Overrides the sync() function to be a no-op, preventing the
 *   global filesystem sync that causes hangs in WSL2.
 *
 * ROOT CAUSE:
 *   gptfdisk's sgdisk calls sync() in DiskSync() which iterates ALL
 *   mounted filesystems. In WSL2, this includes 9p mounts (/mnt/c)
 *   that can hang indefinitely on sync.
 *
 * USAGE:
 *   LD_PRELOAD=/usr/lib/nosync.so sgdisk ...
 *
 * NOTE:
 *   This only affects sync(). fsync() and syncfs() are NOT overridden
 *   so per-file and per-filesystem syncs still work correctly.
 *
 * BUILD:
 *   gcc -shared -fPIC -o nosync.so nosync.c
 *
 * Copyright (c) 2026 n3x contributors
 * SPDX-License-Identifier: MIT
 */

#define _GNU_SOURCE
#include <unistd.h>

/* Override sync() to be a no-op */
void sync(void) {
    /* Do nothing - sgdisk follows with fsync(fd) anyway */
    return;
}
