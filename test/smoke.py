"""squero-kernel/0 smoke test: hello, eval, whos, clear(), and a 512x512 binary round-trip.

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
# SqueroBase (clear, clc, the chart verbs) is mounted as the MX launcher mounts it.
BASE = os.environ.get("SQUERO_BASE", os.path.join(os.path.dirname(ROOT), "squero-mx-base"))
CMD = (["julia", "--startup-file=no", f"--project={ROOT}", os.path.join(ROOT, "src", "kernel.jl")]
       if NATIVE else ["podman", "run", "--rm", "-i", "--network=none",
                       "-v", f"{BASE}:/opt/squero-mx-base:ro,z", "-e", "SQUERO_BASE=/opt/squero-mx-base", IMAGE])

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
evaluated = line()
assert evaluated["value"]["value"] == 5 and evaluated["text"] == "5"
send({"op": "eval", "id": "m", "code": "[1 2; 3 4]"})
matrix = line()
assert matrix["text"] == "2×2 Matrix{Int64}:\n 1  2\n 3  4"
assert matrix["value"]["preview"] == [1, 2, 3, 4], "the preview reads row by row"
send({"op": "whos"})
assert [(v["name"], v["type"]) for v in line()["value"]] == [("f", "Function"), ("t", "Int64")]
print("eval/whos f, t = 5")

# clear() applies between statements: what the script defines after it survives.
send({"op": "eval", "id": "c", "code": "x = 1:5\ny = 2:6\nclear()\nclc()\nz = 10\na = 5\nf(x, y) = x + y\nt = f(2, 3)"})
cleared = line()
assert cleared["ok"] and [e["type"] for e in cleared["events"]] == ["clear", "clc"], cleared
send({"op": "whos"})
assert [v["name"] for v in line()["value"]] == ["a", "f", "t", "z"]
send({"op": "eval", "id": "d", "code": "w = 1; clear(:a); f(1, 1)"})
assert line()["value"]["value"] == 2
send({"op": "whos"})
assert [v["name"] for v in line()["value"]] == ["f", "t", "w", "z"]
send({"op": "eval", "id": "p", "code": "q = 1\nbad("})
assert not line()["ok"]
send({"op": "whos"})
assert "q" not in [v["name"] for v in line()["value"]], "a syntax error runs nothing"
print("clear between statements")

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
