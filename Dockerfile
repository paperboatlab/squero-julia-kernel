# squero-julia-kernel — the Julia session Squero Studio MX talks to.
#
# The kernel project depends on SqueroBase and SqueroPlot by path (`../SqueroBase.jl`,
# `../SqueroPlot.jl`), so build from the folder that holds the three checkouts:
#
#   podman build -f squero-julia-kernel/Dockerfile -t squero-julia-kernel:1.11.6-r4 .
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
# Precompiled for every CPU of the architecture, with the targets Julia's own releases use: code built
# for the build machine's CPU alone is rejected on another (a GitHub runner's Granite Rapids on a
# laptop), and every first start then compiles for a minute.
ARG TARGETARCH
RUN case "${TARGETARCH:-$(uname -m)}" in \
      arm64|aarch64) export JULIA_CPU_TARGET="generic;cortex-a57;thunderx2t99;carmel,clone_all;apple-m1,base(3);neoverse-512tvb,base(3)" ;; \
      *) export JULIA_CPU_TARGET="generic;sandybridge,-xsaveopt,clone_all;haswell,-rdrnd,base(1)" ;; \
    esac && \
    julia --startup-file=no --project=/opt/squero/app -e 'using Pkg; Pkg.instantiate(); Pkg.precompile()'

COPY --chown=1000:1000 squero-julia-kernel/src ./app/src
ENV SQUERO_KERNEL_IMAGE=squero-julia-kernel:1.11.6-r4
ENTRYPOINT ["julia", "--startup-file=no", "--project=/opt/squero/app", "/opt/squero/app/src/kernel.jl"]
