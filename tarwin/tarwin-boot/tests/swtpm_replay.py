"""Replay the actual Kira test packet on a fresh, disposable software TPM.

python3 swtpm_replay.py /path/to/built/tarwin-boot-tests
Requires swtpm 0.10+, not a host TPM or privileged device access.
"""
import hashlib
import pathlib
import socket
import struct
import subprocess
import sys
import tempfile


def receive(stream, count):
    data = bytearray()
    while len(data) < count:
        part = stream.recv(count - len(data))
        if not part:
            raise EOFError("short TPM response")
        data.extend(part)
    return bytes(data)


def transact(stream, packet):
    stream.sendall(packet)
    header = receive(stream, 10)
    _, size, rc = struct.unpack(">HII", header)
    if not 10 <= size <= 4096 or rc:
        raise ValueError(f"TPM response size={size}, rc={rc:#x}")
    return header + receive(stream, size - 10)


def pcr8(stream):
    read = bytes.fromhex("8001 00000014 0000017e 00000001 000b03 000100")
    reply = transact(stream, read)
    if reply[14:30] != bytes.fromhex("00000001 000b03 000100 00000001 0020"):
        raise ValueError("unexpected PCR_Read selection or digest width")
    return reply[30:]


def run(binary):
    wire = subprocess.check_output([binary, "--wire"])
    packet, padding, event = wire[:65], wire[65:66], wire[66:]
    if padding != b"\0" or event[:14] != struct.pack("<IIIH", 8, 13, 1, 11):
        raise ValueError("incorrect Event2 header")
    digest = event[14:46]
    if digest != bytes(range(32)) or event[46:] != struct.pack("<I", 3) + b"abc":
        raise ValueError("incorrect Event2 payload")
    with tempfile.TemporaryDirectory(dir="/tmp") as root, socket.socket(socket.AF_UNIX) as server:
        path = str(pathlib.Path(root, "tpm"))
        server.bind(path)
        server.listen(1)
        tpm = subprocess.Popen([
            "swtpm", "socket", "--tpm2", "--terminate", "--tpmstate", f"dir={root}",
            "--server", f"type=unixio,fd={server.fileno()}",
            "--flags", "not-need-init,startup-clear",
        ], pass_fds=(server.fileno(),))
        try:
            with socket.socket(socket.AF_UNIX) as client:
                client.settimeout(5)
                client.connect(path)
                before = pcr8(client)
                response = transact(client, packet)
                if response != bytes.fromhex("8002 00000013 00000000 00000000 0000 01 0000"):
                    raise ValueError("unexpected PCR_Extend response")
                if len(before) != 32 or pcr8(client) != hashlib.sha256(before + digest).digest():
                    raise ValueError("PCR 8 differs from replay of the staged event")
        finally:
            try:
                tpm.wait(timeout=5)
            except subprocess.TimeoutExpired:
                tpm.kill()
                tpm.wait()
    print("swtpm: SHA-256 PCR 8 matches replay of the Kira Event2 record")


if __name__ == "__main__":
    run(sys.argv[1])
