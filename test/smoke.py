"""squero-kernel/0 smoke test: hello, eval, whos, and a 512x512 binary round-trip.

Run it against the container (default) or native Julia:

    python3 test/smoke.py
    SQUERO_KERNEL=native python3 test/smoke.py
"""
import json
import os
import struct
import subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IMAGE = os.environ.get("SQUERO_KERNEL_IMAGE", "squero-julia-kernel:1.11.6-r1")
NATIVE = os.environ.get("SQUERO_KERNEL") == "native"
CMD = (["julia", "--startup-file=no", f"--project={ROOT}", os.path.join(ROOT, "src", "kernel.jl")]
       if NATIVE else ["podman", "run", "--rm", "-i", "--network=none", IMAGE])

p = subprocess.Popen(CMD, stdin=subprocess.PIPE, stdout=subprocess.PIPE)


def send(obj, frame=None):
    p.stdin.write((json.dumps(obj) + "\n").encode())
    if frame:
        p.stdin.write(frame)
    p.stdin.flush()


def line():
    return json.loads(p.stdout.readline())


send({"op": "hello"})
hello = line()
assert hello["ok"] and hello["protocol"] == 0 and hello["julia"].startswith("1.11")
print("hello", hello["julia"], hello["image"])

send({"op": "eval", "id": "e", "code": "f(x, y) = x + y; t = f(2, 3)"})
assert line()["value"]["value"] == 5
send({"op": "whos"})
assert [v["name"] for v in line()["value"]] == ["t"]
print("eval/whos t = 5")

n = 512
values = [0.25] * (n * n)
send({"op": "set", "id": "s", "name": "Big", "rows": n, "cols": n, "bytes": n * n * 8},
     struct.pack("<%dd" % (n * n), *values))
assert line()["ok"]
send({"op": "get", "id": "g", "name": "Big"})
header = line()
raw = p.stdout.read(header["array"]["bytes"])
assert header["array"]["rows"] == n and header["array"]["cols"] == n
assert len(raw) == n * n * 8 and struct.unpack("<d", raw[:8])[0] == 0.25
print("512x512 round-trip", len(raw), "bytes")

send({"op": "reset"})
assert line()["ok"]
send({"op": "whos"})
assert line()["value"] == []
print("reset")
send({"op": "shutdown"})
p.wait(timeout=30)
print("ok")
