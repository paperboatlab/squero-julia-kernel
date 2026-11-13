"""Run every example script through squero-kernel/0 and check it: no error, the figures it
should draw, and their stored artifacts. PNG previews go to --out for a look.

    SQUERO_KERNEL=native python3 test/examples.py ../squero-studio-mx/examples --out /tmp/mx-examples
"""
import argparse
import json
import os
import subprocess
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IMAGE = os.environ.get("SQUERO_KERNEL_IMAGE", "squero-julia-kernel:1.11.6-r2")
NATIVE = os.environ.get("SQUERO_KERNEL") == "native"

parser = argparse.ArgumentParser()
parser.add_argument("folder")
parser.add_argument("--out", default=None)
args = parser.parse_args()
folder = os.path.abspath(args.folder)
out = os.path.abspath(args.out) if args.out else None
if out:
    os.makedirs(out, exist_ok=True)

CMD = (["julia", "--startup-file=no", f"--project={ROOT}", os.path.join(ROOT, "src", "kernel.jl")]
       if NATIVE else ["podman", "run", "--rm", "-i", "--network=none", "-v", f"{folder}:/workspace:rw", "-w", "/workspace", IMAGE])
work = out or folder
p = subprocess.Popen(CMD, stdin=subprocess.PIPE, stdout=subprocess.PIPE, cwd=work)


def send(obj):
    p.stdin.write((json.dumps(obj) + "\n").encode())
    p.stdin.flush()


def line():
    return json.loads(p.stdout.readline())


def artifact(figure, version, fmt):
    send({"op": "figure.export", "id": "a", "figure": figure, "version": version, "format": fmt})
    header = line()
    assert header["ok"], header
    return p.stdout.read(header["artifact"]["bytes"])


send({"op": "hello"})
assert line()["ok"]
scripts = sorted(os.path.relpath(os.path.join(d, f), folder).replace(os.sep, "/")
                 for d, _, files in os.walk(folder) for f in files if f.endswith(".jl"))
failures = 0
for script in scripts:
    code = open(os.path.join(folder, script), encoding="utf-8").read()
    send({"op": "reset"})
    line()
    started = time.perf_counter()
    send({"op": "eval", "id": "e", "code": code})
    reply = line()
    took = time.perf_counter() - started
    figures = [f for f in reply.get("figures", []) if "error" not in f]
    errors = [f for f in reply.get("figures", []) if "error" in f]
    status = "ok" if reply["ok"] and not errors and figures else "FAIL"
    failures += status != "ok"
    extra = f" problems={len(reply.get('problems', []))} runs={len(reply.get('runs', []))}"
    print(f"{status:4} {script:40} {took:5.2f} s  figures={len(figures)}{extra}")
    if not reply["ok"]:
        print("     ", reply.get("error", "")[:600])
    for f in errors:
        print("     ", f["error"][:600])
    for i, f in enumerate(figures):
        for fmt, magic in (("png", b"\x89PNG"), ("svg", b"<?xml"), ("pdf", b"%PDF-"), ("eps", b"%!PS-Adobe"), ("html", b"<!DOCTYPE")):
            data = artifact(f["id"], f["version"], fmt)
            assert data.startswith(magic), (script, fmt)
            if out and fmt in ("png", "pdf"):
                name = script.replace("/", "_").replace(".jl", "") + (f"-{i + 1}" if len(figures) > 1 else "") + f".{fmt}"
                open(os.path.join(out, name), "wb").write(data)
send({"op": "shutdown"})
p.wait(timeout=30)
print("failures:", failures)
raise SystemExit(1 if failures else 0)
