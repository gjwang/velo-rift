import os
import sys

path = "/vrift"
if len(sys.argv) > 1:
    path = sys.argv[1]

print(f"Statting {path}...")
try:
    st = os.stat(path)
    print("Success!")
    print(f"  Mode: {oct(st.st_mode)}")
    print(f"  Size: {st.st_size}")
    print(f"  Nlink: {st.st_nlink}")
except Exception as e:
    print(f"Failed: {e}")
