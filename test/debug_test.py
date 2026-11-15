"""Debugger tests for squero-kernel/0 (breakpoints, conditional, stepping, stack, frame eval)."""
import json
import os
import subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CMD = ["julia", "--startup-file=no", f"--project={ROOT}", os.path.join(ROOT, "src", "kernel.jl")]

p = subprocess.Popen(CMD, stdin=subprocess.PIPE, stdout=subprocess.PIPE)


def send(obj):
    p.stdin.write((json.dumps(obj) + "\n").encode())
    p.stdin.flush()


def recv():
    raw = p.stdout.readline()
    assert raw, "kernel closed unexpectedly"
    return json.loads(raw)


_queued = []


def wait_event(name):
    for idx, msg in enumerate(_queued):
        if msg.get("event") == name:
            return _queued.pop(idx)
    while True:
        msg = recv()
        if msg.get("event") == name:
            return msg
        _queued.append(msg)


def wait_reply(req_id):
    for idx, msg in enumerate(_queued):
        if msg.get("id") == req_id:
            return _queued.pop(idx)
    while True:
        msg = recv()
        if msg.get("id") == req_id:
            return msg
        _queued.append(msg)


send({"op": "hello", "id": "h"})
assert wait_reply("h")["ok"]

script = """σ, ρ, β = 10.0, 28.0, 8 / 3
dt = 0.01
function lorenz(s)
    dx = σ * (s[2] - s[1])
    dy = s[1] * (ρ - s[3]) - s[2]
    dz = s[1] * s[2] - β * s[3]
    return [dx, dy, dz]
end
X = zeros(3, 10)
X[:, 1] = [1.0, 1.0, 1.0]
for k in 2:10
    s = X[:, k - 1]
    k1 = lorenz(s)
    k2 = lorenz(s + dt / 2 * k1)
    k3 = lorenz(s + dt / 2 * k2)
    k4 = lorenz(s + dt * k3)
    X[:, k] = s + dt / 6 * (k1 + 2k2 + 2k3 + k4)
    println("step ", k)
end
X[:, end]
"""

# 1. Conditional breakpoint on line 13 (`k1 = lorenz(s)` when `k == 4`)
send({
    "op": "debug.start",
    "id": "dbg1",
    "file": "lorenz.jl",
    "code": script,
    "breakpoints": [
        {"line": 13, "enabled": True, "condition": "k == 4"},
    ],
})
assert wait_reply("dbg1")["ok"]

ev1 = wait_event("debug.stopped")
assert ev1["reason"] == "breakpoint" and ev1["line"] == 13, ev1
names1 = {v["name"]: v for v in ev1["locals"]}
assert names1["k"]["value"] == 4, names1
assert "s" in names1 and "dt" in names1, names1
assert "step 2" in ev1.get("stdout", "") and "step 3" in ev1.get("stdout", ""), ev1

# Add unconditional breakpoint on line 17 while paused (tests live breakpoint update!).
send({
    "op": "debug.breakpoints",
    "id": "bp_add",
    "file": "lorenz.jl",
    "breakpoints": [
        {"line": 13, "enabled": True, "condition": "k == 4"},
        {"line": 17, "enabled": True},
    ],
})
assert wait_reply("bp_add")["ok"]

# 2. Step Into `lorenz(s)` -> pauses on line 4 inside `lorenz` with 2 stack frames!
send({"op": "debug.step", "id": "s_in", "kind": "into"})
assert wait_reply("s_in")["ok"]
ev2 = wait_event("debug.stopped")
assert ev2["reason"] == "step" and ev2["line"] == 4, ev2
assert [f["name"] for f in ev2["frames"]] == ["lorenz", "top-level"], ev2

# Inspect frame #2 locals (`top-level`) while stopped in `lorenz`.
top_frame_id = ev2["frames"][1]["id"]
send({"op": "debug.locals", "id": "loc2", "frameId": top_frame_id})
loc2 = wait_reply("loc2")
assert loc2["ok"] and any(v["name"] == "k" and v["value"] == 4 for v in loc2["value"]), loc2

# Evaluate expression in frame #1 (`lorenz`)
fn_frame_id = ev2["frames"][0]["id"]
send({"op": "debug.eval", "id": "ev_fn", "frameId": fn_frame_id, "code": "round(sum(s); digits=2)"})
res_fn = wait_reply("ev_fn")
assert res_fn["ok"] and isinstance(res_fn["value"]["value"], (int, float)), res_fn

# 3. Step Over inside `lorenz` -> line 5
send({"op": "debug.step", "id": "s_over", "kind": "over"})
assert wait_reply("s_over")["ok"]
ev3 = wait_event("debug.stopped")
assert ev3["line"] == 5 and ev3["frames"][0]["name"] == "lorenz", ev3

# 4. Step Out back to `top-level` (next statement after `k1 = lorenz(s)`, line 14)
send({"op": "debug.step", "id": "s_out", "kind": "out"})
assert wait_reply("s_out")["ok"]
ev4 = wait_event("debug.stopped")
assert ev4["frames"][0]["name"] == "top-level" and ev4["line"] == 14, ev4

# 5. Continue -> hits breakpoint at line 17 (`X[:, k] = ...`)
send({"op": "debug.continue", "id": "cont1"})
assert wait_reply("cont1")["ok"]
ev5 = wait_event("debug.stopped")
assert ev5["reason"] == "breakpoint" and ev5["line"] == 17, ev5
assert any(v["name"] == "k3" for v in ev5["locals"]), ev5

# 6. Clear breakpoints mid-session and Continue to completion
send({"op": "debug.breakpoints", "id": "bp_clr", "file": "lorenz.jl", "breakpoints": []})
assert wait_reply("bp_clr")["ok"]
send({"op": "debug.continue", "id": "cont2"})
assert wait_reply("cont2")["ok"]
term = wait_event("debug.terminated")
assert term["ok"] and not term["stopped"], term
assert "step 10" in term.get("stdout", ""), term

# 7. Stop mid-execution
send({
    "op": "debug.start",
    "id": "dbg2",
    "file": "lorenz.jl",
    "code": script,
    "breakpoints": [{"line": 13, "enabled": True}],
})
assert wait_reply("dbg2")["ok"]
ev_stop = wait_event("debug.stopped")
assert ev_stop["line"] == 13
send({"op": "debug.stop", "id": "stp"})
assert wait_reply("stp")["ok"]
term2 = wait_event("debug.terminated")
assert term2["ok"] and term2["stopped"] is True, term2

# 8. include() across workspace VFS overlay (eval + clear + debugger breakpoint inside included file)
vfs_files = {
    "sub/main.jl": 'include("helper.jl")\ninc_res = inc_double(21)\ninc_res\n',
    "sub/helper.jl": 'offset = 2\nfunction inc_double(x)\n    y = 2 * x + offset\n    return y\nend\n',
}
send({
    "op": "eval",
    "id": "inc_eval",
    "file": "sub/main.jl",
    "code": vfs_files["sub/main.jl"],
    "files": vfs_files,
})
inc_res = wait_reply("inc_eval")
assert inc_res["ok"] and inc_res["value"]["value"] == 44, inc_res

# clear(:offset) must preserve include() in the refreshed session module, and clear() too
send({"op": "eval", "id": "inc_clr", "file": "sub/main.jl", "code": 'clear(:offset)\ninc_double(1)\n', "files": vfs_files})
inc_clr = wait_reply("inc_clr")
assert inc_clr["ok"] and inc_clr["value"]["value"] == 4, inc_clr
send({"op": "eval", "id": "inc_clr2", "file": "sub/main.jl", "code": 'clear()\ninclude("helper.jl")\noffset\n', "files": vfs_files})
inc_clr2 = wait_reply("inc_clr2")
assert inc_clr2["ok"] and inc_clr2["value"]["value"] == 2, inc_clr2

# Debug sub/main.jl with breakpoints at include top-level (line 1) and inside helper function (line 3)
send({"op": "debug.breakpoints", "id": "bp_inc", "file": "sub/helper.jl", "breakpoints": [{"line": 1, "enabled": True}, {"line": 3, "enabled": True}]})
assert wait_reply("bp_inc")["ok"]
send({
    "op": "debug.start",
    "id": "dbg_inc",
    "file": "sub/main.jl",
    "code": vfs_files["sub/main.jl"],
    "breakpoints": [],
    "files": vfs_files,
})
assert wait_reply("dbg_inc")["ok"]
ev_inc1 = wait_event("debug.stopped")
assert ev_inc1["reason"] == "breakpoint" and ev_inc1["file"] == "sub/helper.jl" and ev_inc1["line"] == 1, ev_inc1
assert [f["name"] for f in ev_inc1["frames"]] == ["include(helper.jl)", "top-level"], ev_inc1
send({"op": "debug.continue", "id": "cont_inc1"})
assert wait_reply("cont_inc1")["ok"]
ev_inc2 = wait_event("debug.stopped")
assert ev_inc2["reason"] == "breakpoint" and ev_inc2["file"] == "sub/helper.jl" and ev_inc2["line"] == 3, ev_inc2
assert [f["name"] for f in ev_inc2["frames"]] == ["inc_double", "top-level"], ev_inc2
send({"op": "debug.continue", "id": "cont_inc2"})
assert wait_reply("cont_inc2")["ok"]
term_inc = wait_event("debug.terminated")
assert term_inc["ok"] and term_inc["value"]["value"] == 44, term_inc

send({"op": "shutdown", "id": "bye"})
wait_reply("bye")
p.wait(timeout=5)
print("debugger tests: all passed")
