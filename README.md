# squero-julia-kernel

The containerised Julia session behind Squero Studio MX in the
[Paperboat](https://github.com/paperboatlab/paperboat) ecosystem. It speaks `squero-kernel/0` over
stdin/stdout and preloads [`SqueroPlot.jl`](../SqueroPlot.jl) and
[`SqueroBase.jl`](../SqueroBase.jl); solving and simulation stay in Paperboat.

**Docs:** [`docs/protocol.md`](docs/protocol.md) and <https://paperboatlab.github.io/apps/squero-studio-mx/>

## Build

Pull the prebuilt multi-arch image (`amd64` and `arm64`), or build locally with `SqueroBase.jl` and
`SqueroPlot.jl` checked out beside this folder:

```sh
bin/build-image
SQUERO_KERNEL_BUILD=local bin/build-image
```

For a native session without a container (requires Julia 1.11+):

```sh
julia --project=. -e 'using Pkg; Pkg.instantiate()'
```

## Run

```sh
printf '%s\n' '{"op":"hello"}' | podman run --rm -i --network=none squero-julia-kernel:1.11.6-r4
bin/doctor
```

## Check

```sh
SQUERO_KERNEL=native python3 test/smoke.py
SQUERO_KERNEL=native python3 test/examples.py ../squero-studio-mx/examples
```

## CI

| Check | What it runs | Status |
| --- | --- | --- |
| CI | protocol smoke test and MX example runs | [![ci](https://github.com/paperboatlab/squero-julia-kernel/actions/workflows/ci.yml/badge.svg?branch=dev)](https://github.com/paperboatlab/squero-julia-kernel/actions/workflows/ci.yml?query=branch%3Adev) |
| Image | multi-arch container build and publish (from `main` and tags) | [![publish-image](https://github.com/paperboatlab/squero-julia-kernel/actions/workflows/publish-image.yml/badge.svg?branch=main)](https://github.com/paperboatlab/squero-julia-kernel/actions/workflows/publish-image.yml?query=branch%3Amain) |

## Licence

GNU General Public License version 3 (see [LICENSE](LICENSE)).
