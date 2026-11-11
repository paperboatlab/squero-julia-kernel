# squero-julia-kernel — the Julia session Squero Studio MX talks to.
FROM julia:1.11.6-bookworm

RUN useradd -m -u 1000 kernel
WORKDIR /app
COPY --chown=1000:1000 Project.toml Manifest.toml ./
USER kernel
ENV JULIA_DEPOT_PATH=/home/kernel/.julia
RUN julia --startup-file=no --project=. -e 'using Pkg; Pkg.instantiate(); Pkg.precompile()'

COPY --chown=1000:1000 src ./src
ENV SQUERO_KERNEL_IMAGE=squero-julia-kernel:1.11.6-r1
ENTRYPOINT ["julia", "--startup-file=no", "--project=/app", "/app/src/kernel.jl"]
