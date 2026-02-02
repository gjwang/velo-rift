#!/bin/bash
set -e

# Build the shim
cargo build -p vrift-shim
SHIM_PATH=$(pwd)/target/debug/libvrift_shim.dylib

# Build the test tool
gcc -o test_logging_work/simple_open test_logging_work/simple_open.c

# 1. Test Flight Recorder via SIGUSR1
echo "--- Testing Flight Recorder Dump ---"
VRIFT_DEBUG=1 DYLD_INSERT_LIBRARIES=$SHIM_PATH ./test_logging_work/simple_open 5 &
PID=$!
sleep 1
echo "Sending SIGUSR1 to $PID"
kill -USR1 $PID
wait $PID

echo "--- Check if Logs contains Dump header ---"
# Check the last output for the header
# We might need to redirect stderr to a file for easier checking
VRIFT_DEBUG=1 DYLD_INSERT_LIBRARIES=$SHIM_PATH ./test_logging_work/simple_open 1 2> test_logging_work/log.txt
grep "Flight Recorder Dump" test_logging_work/log.txt || (echo "Dump header not found"; exit 1)
grep "OpenHit" test_logging_work/log.txt || (echo "OpenHit event not found"; exit 1)

echo "--- Verification Successful ---"
