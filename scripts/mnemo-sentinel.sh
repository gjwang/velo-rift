#!/usr/bin/env bash
# Mnemo-Sentinel: Autonomous Repo Watcher & Validator
# Part of the Agents 1st Class Autonomous R&D Infrastructure

REPO_DIR="/Users/antigravity/rust_source/rift_ci"
TARGET_BRANCH="opt/vdir-open-acceleration"
cd "$REPO_DIR" || exit 1

echo "[Sentinel] Checking for upstream updates on $TARGET_BRANCH..."
git remote update > /dev/null 2>&1

LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse origin/$TARGET_BRANCH)

if [ "$LOCAL" != "$REMOTE" ]; then
    echo "[ALERT] Upstream changes detected ($LOCAL -> $REMOTE)"
    # This exit code will be picked up by the calling agent to trigger the DevOps session
    exit 100 
else
    echo "[OK] Local branch is up to date."
    exit 0
fi
