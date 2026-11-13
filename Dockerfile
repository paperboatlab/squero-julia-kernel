# squero-julia-kernel — the Julia session Squero Studio MX talks to.
#
# The kernel project depends on SqueroBase and SqueroPlot by path (`../SqueroBase.jl`,
# `../SqueroPlot.jl`), so build from the folder that holds the three checkouts:
#
#   podman build -f squero-julia-kernel/Dockerfile -t squero-julia-kernel:1.11.6-r2 .
#
# (bin/build-image does this.) SqueroPlot draws with Cairo and its own bundled fonts; the image
# needs no system fonts, X server or GPU.
FROM docker.io/library/julia:1.11.6-bookworm

RUN useradd -m -u 1000 kernel
WORKDIR /opt/squero
COPY --chown=1000:1000 SqueroBase.jl ./SqueroBase.jl
COPY --chown=1000:1000 SqueroPlot.jl ./SqueroPlot.jl
COPY --chown=1000:1000 squero-julia-kernel/Project.toml squero-julia-kernel/Manifest.toml ./app/
USER kernel
ENV JULIA_DEPOT_PATH=/home/kernel/.julia
RUN julia --startup-file=no --project=/opt/squero/app -e 'using Pkg; Pkg.instantiate(); Pkg.precompile()'

COPY --chown=1000:1000 squero-julia-kernel/src ./app/src
ENV SQUERO_KERNEL_IMAGE=squero-julia-kernel:1.11.6-r2
ENTRYPOINT ["julia", "--startup-file=no", "--project=/opt/squero/app", "/opt/squero/app/src/kernel.jl"]
