"""squero-kernel/0 smoke test: hello, eval, whos, clear(), figures (capture, history, binary
artifacts, export), plot.optimum, the Paperboat bridges, and a 512x512 binary round-trip.

Run it against the container (default) or native Julia:

    python3 test/smoke.py
    SQUERO_KERNEL=native python3 test/smoke.py
"""
import json
import os
import struct
import subprocess
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IMAGE = os.environ.get("SQUERO_KERNEL_IMAGE", "squero-julia-kernel:1.11.6-r2")
NATIVE = os.environ.get("SQUERO_KERNEL") == "native"
# SqueroBase and SqueroPlot are the kernel project's own dependencies (path deps natively, baked
# into the image otherwise); nothing is mounted.
CMD = (["julia", "--startup-file=no", f"--project={ROOT}", os.path.join(ROOT, "src", "kernel.jl")]
       if NATIVE else ["podman", "run", "--rm", "-i", "--network=none", IMAGE])

started = time.perf_counter()
p = subprocess.Popen(CMD, stdin=subprocess.PIPE, stdout=subprocess.PIPE)


def send(obj, frame=None):
    p.stdin.write((json.dumps(obj) + "\n").encode())
    if frame:
        p.stdin.write(frame)
    p.stdin.flush()


def line():
    return json.loads(p.stdout.readline())


def artifact(op, figure, fmt, version=None):
    request = {"op": op, "id": "a", "figure": figure, "format": fmt}
    if version:
        request["version"] = version
    send(request)
    header = line()
    assert header["ok"], header
    raw = p.stdout.read(header["artifact"]["bytes"])
    assert len(raw) == header["artifact"]["bytes"]
    return header["artifact"], raw


def timed_eval(code, id="e"):
    t = time.perf_counter()
    send({"op": "eval", "id": id, "code": code})
    reply = line()
    return reply, time.perf_counter() - t


send({"op": "hello"})
hello = line()
assert hello["ok"] and hello["protocol"] == 0 and hello["julia"].startswith("1.11")
assert "SqueroPlot" in hello["packages"] and "SqueroBase" in hello["packages"], hello
print("hello", hello["julia"], hello["image"], hello["versions"], f"(start {time.perf_counter() - started:.1f} s)")

send({"op": "eval", "id": "e", "code": "f(x, y) = x + y; t = f(2, 3)"})
evaluated = line()
assert evaluated["value"]["value"] == 5 and evaluated["text"] == "5"
assert evaluated["figures"] == [] and "charts" not in evaluated
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

# Figures: a SqueroPlot figure is captured, snapshotted and stored per version.
script = """x = range(0, 2π; length = 50)
fig = Figure()
ax = Axis(fig[1, 1]; title = "Waves")
lines!(ax, x, sin.(x))
stem!(ax, x[1:5:end], cos.(x[1:5:end]))
"""
first, cold = timed_eval(script, "fig1")
assert first["ok"], first
fig = first["figures"][0]
assert len(first["figures"]) == 1
assert fig["title"] == "Waves" and fig["plots"] == 2 and fig["axes"] == 1, fig
assert fig["formats"] == ["eps", "pdf", "png", "svg"] and fig["lines"], fig
assert (fig["width"], fig["height"]) == (600, 450)
v1 = fig["version"]
meta, svg = artifact("figure.get", fig["id"], "svg")
assert meta["mime"] == "image/svg+xml" and svg.startswith(b"<?xml") and b"<path" in svg and b"Waves" in svg
meta, png = artifact("figure.get", fig["id"], "png")
assert png[:8] == b"\x89PNG\r\n\x1a\n"
print(f"figure captured: {fig['id']}@{v1}, svg {len(svg)} B, png {len(png)} B (first figure {cold:.2f} s)")

# Nothing changed: no new history entry.
same, _ = timed_eval("1 + 1")
assert same["figures"] == [], same
# A change makes a new version; the old one still exports.
changed, warm = timed_eval('scatter!(ax, x, cos.(x)); ax.title = "Waves 2"', "fig2")
assert len(changed["figures"]) == 1 and changed["figures"][0]["version"] != v1
assert changed["figures"][0]["plots"] == 3 and changed["figures"][0]["title"] == "Waves 2"
for fmt, magic in (("pdf", b"%PDF-"), ("eps", b"%!PS-Adobe-3.0 EPSF-3.0"), ("png", b"\x89PNG"), ("svg", b"<?xml"), ("html", b"<!DOCTYPE html>")):
    _, old = artifact("figure.export", fig["id"], fmt, v1)
    assert old.startswith(magic), (fmt, old[:20])
_, old_svg = artifact("figure.export", fig["id"], "svg", v1)
assert old_svg == svg, "a stored version never changes"
print(f"history: new version on change ({warm:.2f} s), none without; old version exports pdf/eps/png/svg/html")

# The stage: a version drawn at the panel's size, with the axes' rectangles; pan/zoom/rotate
# change only that version's view, never its stored artifacts.
def png_size(raw):
    return struct.unpack(">II", raw[16:24])


def stage(op, **extra):
    send({"op": op, "id": "r", "figure": fig["id"], "version": v1, "width": 900, "height": 500,
          "format": "png", "px_per_unit": 1, **extra})
    header = line()
    assert header["ok"], header
    return header, p.stdout.read(header["artifact"]["bytes"])


t = time.perf_counter()
header, frame = stage("figure.render")
render_ms = (time.perf_counter() - t) * 1000
assert png_size(frame) == (900, 500) and header["axes"][0]["kind"] == "axis" and header["view"] is False
ax0 = header["axes"][0]
assert 0 < ax0["x"] < 900 and ax0["w"] > 500, ax0
t = time.perf_counter()
zoomed_header, zoomed = stage("figure.interact", action="zoom", axis=1, factor=0.5, fx=0.5, fy=0.5)
zoom_ms = (time.perf_counter() - t) * 1000
assert zoomed != frame and zoomed_header["view"] is True
_, panned = stage("figure.interact", action="pan", axis=1, dx=0.2, dy=0.0)
assert panned != zoomed
_, same_old = artifact("figure.export", fig["id"], "svg", v1)
assert same_old == svg, "the view never changes the stored version"
send({"op": "figure.export", "id": "x", "figure": fig["id"], "version": v1, "format": "png",
      "width": 1280, "height": 720, "view": True, "px_per_unit": 1})
sized = line()
sized_png = p.stdout.read(sized["artifact"]["bytes"])
assert png_size(sized_png) == (1280, 720) and sized["artifact"]["width"] == 1280
send({"op": "figure.export", "id": "x", "figure": fig["id"], "version": v1, "format": "pdf", "width": 800, "height": 800})
sized_pdf_header = line()
assert p.stdout.read(sized_pdf_header["artifact"]["bytes"]).startswith(b"%PDF-")
reset_header, reset = stage("figure.interact", action="reset")
assert reset == frame and reset_header["view"] is False
print(f"stage: render 900x500 {render_ms:.0f} ms, zoom {zoom_ms:.0f} ms, pan, reset; export at 1280x720 and 800x800")

# Several figures in one run are all captured; clear() keeps the stored artifacts.
multi, _ = timed_eval("""f1 = Figure(); lines(f1[1, 1], 1:3, [1, 4, 9])
f2 = Figure(); s = surface(f2[1, 1], [sin(i) * cos(j) for i in 1:20, j in 1:20])
clear()""", "multi")
assert multi["ok"] and len(multi["figures"]) == 2, multi
assert multi["figures"][1]["axes"] == 1
_, again = artifact("figure.export", fig["id"], "pdf", v1)
assert again.startswith(b"%PDF-")
print("two figures from one run; artifacts survive clear()")

# Interactive scene spec (2D & 3D) and client-supplied view_state export.
def fetch_scene(figure, version=None):
    req = {"op": "figure.scene", "id": "sc", "figure": figure}
    if version:
        req["version"] = version
    send(req)
    header = line()
    assert header["ok"], header
    nbytes = header.get("artifact", {}).get("bytes", 0)
    raw = p.stdout.read(nbytes) if nbytes > 0 else b""
    assert len(raw) == nbytes
    return header["scene"], raw

sc2, _ = fetch_scene(fig["id"], v1)
assert sc2["layout"]["items"][0]["block"]["kind"] == "axis"
send({"op": "figure.export", "id": "vs2", "figure": fig["id"], "version": v1, "format": "svg",
      "view": True, "view_state": {"axes": [{"index": 1, "limits": [0.5, 4.5, -0.5, 0.5], "xgridvisible": False}]}})
vs2_hdr = line()
vs2_svg = p.stdout.read(vs2_hdr["artifact"]["bytes"])
assert vs2_svg.startswith(b"<?xml") and b"<path" in vs2_svg and vs2_svg != svg
_, still_scripted = artifact("figure.export", fig["id"], "svg", v1)
assert still_scripted == svg

f3d = multi["figures"][1]
sc3, raw3 = fetch_scene(f3d["id"], f3d["version"])
assert len(raw3) > 0 and sc3["layout"]["items"][0]["block"]["kind"] == "axis3"
assert sc3["layout"]["items"][0]["block"]["plots"][0]["positions"]["buf"] is True
_, f3d_scripted = artifact("figure.export", f3d["id"], "svg", f3d["version"])
send({"op": "figure.export", "id": "vs3", "figure": f3d["id"], "version": f3d["version"], "format": "svg",
      "view": True, "view_state": {"axes": [{"index": 1, "azimuth": 1.1, "elevation": 0.45}]}})
vs3_hdr = line()
vs3_svg = p.stdout.read(vs3_hdr["artifact"]["bytes"])
assert vs3_svg.startswith(b"<?xml") and vs3_svg != f3d_scripted
print(f"scene & view_state: 2D/3D scenes (3D frame {len(raw3)} B), vector SVG view export")

# Paperboat bridges: an optimization problem and a run request are queued for the app.
bridged, _ = timed_eval('optimize((f = [-1.0, -2.0], A = [1.0 1.0], b = [4.0], lb = [0.0, 0.0])); '
                        'simulate((nodes = [], edges = []); duration = 5, solver = :rk4)')
assert bridged["problems"][0]["A"] == [[1.0, 1.0]] and bridged["runs"][0]["type"] == "graph.run", bridged
# An optimization result (as Paperboat's CLI returns it) is drawn as a SqueroPlot surface.
grid = [0.0, 0.5, 1.0]
result = {"ok": True, "kind": "nlp", "x": [0.5, 0.5], "objective": 0.0,
          "grid": {"x": grid, "y": grid, "z": [[(a - 0.5) ** 2 + (b - 0.5) ** 2 for a in grid] for b in grid]}}
send({"op": "plot.optimum", "id": "o", "result": result, "title": "nlp optimum"})
opt = line()
assert opt["ok"] and opt["figure"]["title"] == "nlp optimum" and opt["figure"]["plots"] == 3, opt
_, opt_svg = artifact("figure.get", opt["figure"]["id"], "svg")
assert b"<path" in opt_svg
print("bridges: problems, runs; plot.optimum surface")

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
_, kept = artifact("figure.export", fig["id"], "svg", v1)
assert kept == svg
print("reset (history artifacts kept)")
send({"op": "shutdown"})
p.wait(timeout=30)
print("ok")
