import math
import os
import socket
import struct
import time


# Voxtype's native-endian wire frame: sequence, minimum, maximum, peak dBFS.
FRAME = struct.Struct("=Ifff")
SOCKET_PATH = os.path.join(
    os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "voxtype", "audio.sock"
)


def follow_levels():
    while True:
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as stream:
                stream.connect(SOCKET_PATH)
                pending = bytearray()
                peak = -120.0
                last_update = 0.0
                while True:
                    chunk = stream.recv(FRAME.size - len(pending))
                    if not chunk:
                        break
                    pending.extend(chunk)
                    if len(pending) != FRAME.size:
                        continue
                    _, _, _, dbfs = FRAME.unpack(pending)
                    pending.clear()
                    if math.isfinite(dbfs):
                        peak = max(peak, dbfs)
                    now = time.monotonic()
                    if now - last_update >= 1 / 30:
                        level = max(0.0, min(1.0, (peak + 60) / 54))
                        print(f"{level:.4f}", flush=True)
                        peak = -120.0
                        last_update = now
        except OSError:
            pass
        print("0", flush=True)
        time.sleep(0.5)


if __name__ == "__main__":
    try:
        follow_levels()
    except BrokenPipeError:
        pass
