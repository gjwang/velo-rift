#!/usr/bin/env python3
import os
import sys
import glob
import time

def main():
    print("\033[1;34m[VLog] Velo Rift Log Consumer\033[0m")
    log_pattern = "/tmp/vrift-shim-*.log"
    
    seen_files = set()
    
    while True:
        files = glob.glob(log_pattern)
        for f in files:
            if f not in seen_files:
                pid = f.split('-')[-1].split('.')[0]
                print(f"\n\033[1;32m--- Log for PID {pid} ({f}) ---\033[0m")
                try:
                    with open(f, 'r', errors='replace') as fd:
                        print(fd.read())
                except Exception as e:
                    print(f"Error reading {f}: {e}")
                seen_files.add(f)
        
        if len(sys.argv) > 1 and sys.argv[1] == "--once":
            break
            
        time.sleep(1)

if __name__ == "__main__":
    main()
