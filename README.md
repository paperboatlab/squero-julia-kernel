# squero-julia-kernel

The Julia session behind **Squero Studio MX**, packaged as a container. It speaks
`squero-kernel/0` on stdin/stdout; the MX launcher owns the browser bridge.

Every session loads two packages:

- **[SqueroPlot.jl](../SqueroPlot.jl)**: figures (`Figure`, `Axis`, `lines!`, `surface!`, …).
  The kernel snapshots the figures a script changed and stores their artifacts.
- **[SqueroBase.jl](../SqueroBase.jl)**: `clear`/`clc` session events, `optimize` (a problem for
  Paperboat's solver) and `simulate` (a `graph.run` for a Paperboat backend).

Solving and simulation stay in Paperboat; nothing here integrates or solves.

## Protocol

One JSON object per line. A reply with a binary frame says so in its header, and the raw bytes
follow the JSON line: `array.bytes` (Float64, column-major) or `artifact.bytes` (a figure file).
Figure images never travel as base64 inside JSON.

| op | request | reply |
| --- | --- | --- |
| `hello` | — | `julia`, `image`, `protocol`, `packages`, `versions` |
| `eval` | `id`, `code` | `value`, `text` (the REPL's display), `stdout`, `figures`, `problems`, `runs`, `events` |
| `whos` | — | bindings with `name`, `type`, `shape`, `value`/`preview`; functions as `Function`; figures as `Figure` |
| `get` | `id`, `name` | JSON line with `array` + raw Float64 bytes |
| `set` | `id`, `name`, `rows`, `cols`, `bytes` + frame | `value` |
| `snapshot` | `id`, `line` | `whos` of the last source's prefix |
| `figure.get` | `id`, `figure`, `version?`, `format` (`svg`/`png`) | JSON line with `artifact` + the bytes: the preview the stage shows |
| `figure.export` | `id`, `figure`, `version?`, `format` (`png`/`svg`/`pdf`/`eps`/`html`) | `artifact` + bytes of a stored version |
| `figure.list` | `id` | metadata of every stored version |
| `plot.optimum` | `id`, `result` (Paperboat's solver JSON with `grid`), `title` | `figure`: a SqueroPlot surface with the optimum, stored like any figure |
| `reset` / `shutdown` | — | `value` |

`figures` in an `eval` reply lists the figures whose drawing changed in that run (each is new
history for the app): `id`, `version` (a digest of the SVG), `title`, `width`, `height`,
`plots`, `axes`, `formats`, and `lines`, the source lines that drew into it. The kernel finds
figures among the session's bindings, the run's value and SqueroPlot's current figure, also
those a later `clear()` in the same run would hide. It stores PNG, SVG, PDF and EPS per version
(the last 256 versions), so a history entry exports after the variables, the session or the live
figure have changed. `clear`, `clc` and `reset` never drop stored artifacts.

`eval` runs in a fresh module per session, so `reset` is a real clean slate. It runs the
code's top-level statements one at a time, like a script (a syntax error anywhere runs none of
them). `clear()` swaps in a fresh module before the next statement, so a script keeps what it
defines after `clear()`; `clear(:x)` drops just `x`. Stdout/stderr from user code are captured
and returned in `stdout`, never mixed into the protocol stream.

## Build and run

```sh
bin/build-image          # podman/docker build with the parent folder as context
printf '%s\n' '{"op":"hello"}' | podman run --rm -i --network=none squero-julia-kernel:1.11.6-r2
bin/doctor
```

The image needs `SqueroBase.jl` and `SqueroPlot.jl` checked out beside this folder (the
project's path dependencies). `--network=none` is the supported run mode; the kernel never needs
a network. The image runs as uid 1000, so `--userns=keep-id` on podman and `--user` on docker
work with a project mount.

Natively, `julia --project=. -e 'using Pkg; Pkg.instantiate()'` resolves the same sibling paths.

## Test

```sh
SQUERO_KERNEL=native python3 test/smoke.py                                  # the protocol
SQUERO_KERNEL=native python3 test/examples.py ../squero-studio-mx/examples  # every MX example
```

## Packages

JSON3, the stdlibs LinearAlgebra, SparseArrays and Statistics, SqueroBase and SqueroPlot
(which brings Cairo, Colors, FreeType2_jll, PrecompileTools and SHA).
