import os
import time

vpath = "/vrift/reingest_test.txt"
if not os.path.exists("/tmp/vrift-real"):
    os.makedirs("/tmp/vrift-real")

# Path that would be mapped to /vrift/reingest_test.txt
real_path = "/tmp/vrift-real/reingest_test.txt"

print(f"Writing to {vpath} (real: {real_path})...")
try:
    with open(real_path, "w") as f:
        f.write("Updated content at " + str(time.time()))
    print("Write complete. Closing file should trigger re-ingest.")
except Exception as e:
    print(f"Failed: {e}")
