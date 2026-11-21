"""Connect the diagnostic's private serial socket to the bounded Metal check."""
import socket
import subprocess
import sys
import time

with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as port:
    end = time.monotonic() + 5
    while True:
        try:
            port.connect(sys.argv[1])
            break
        except (FileNotFoundError, ConnectionRefusedError):
            if time.monotonic() >= end:
                raise
            time.sleep(0.02)
    subprocess.run([sys.argv[2], "--guest-stdio"], stdin=port, stdout=port,
                   check=True, timeout=25)
