# squero-julia-kernel

The Julia session behind **Squero Studio MX**, packaged as a container. It speaks
`squero-kernel/0` on stdin/stdout; the MX launcher owns the browser bridge. Plotting and
simulation are not here — charts are shared Paperboat components and solvers live in Paperboat.

## Protocol

One JSON object per line. A matrix reply adds a raw Float64 frame (column-major) after its JSON
line, as described by `array.bytes`.

| op | request | reply |
| --- | --- | --- |
| `hello` | — | `julia`, `image`, `protocol`, `packages` |
| `eval` | `id`, `code` | `value` (type/shape/preview), `text` (the REPL's display), `stdout`, `charts`, `problems`, `events` |
| `whos` | — | bindings with `name`, `type`, `shape`, `value`/`preview`; functions as `Function` |
| `get` | `id`, `name` | JSON line with `array` + raw Float64 bytes |
| `set` | `id`, `name`, `rows`, `cols`, `bytes` + frame | `value` |
| `snapshot` | `id`, `line` | `whos` of the last source's prefix |
| `chart` | `id` | reserved for the shared plot registry |
| `reset` / `shutdown` | — | `value` |

`eval` runs in a fresh module per session, so `reset` is a real clean slate. It runs the
code's top-level statements one at a time, like a script (a syntax error anywhere runs none of
them). SqueroBase's `clear()` swaps in a fresh module before the next statement, so a script
keeps what it defines after `clear()`; `clear(:x)` drops just `x`. The events still come back
in `events` for the UI. Stdout/stderr from
user code are captured and returned in `stdout`, never mixed into the protocol stream.

## Build and run

```sh
podman build -t squero-julia-kernel:1.11.6-r1 .
printf '%s\n' '{"op":"hello"}' | podman run --rm -i --network=none squero-julia-kernel:1.11.6-r1
bin/doctor
```

`--network=none` is the supported run mode; the kernel never needs a network. The image runs as
uid 1000, so `--userns=keep-id` on podman and `--user` on docker work with a project mount.

## Packages

JSON3 plus the stdlibs LinearAlgebra, SparseArrays and Statistics. Nothing here plots or
integrates. A sysimage with ControlSystems is a later build target; the protocol does not depend
on it.
