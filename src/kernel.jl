# squero-kernel/0 — the Julia session behind Squero Studio MX.
#
# The launcher starts this file (normally in a container) and speaks JSON lines on stdin/stdout.
# A binary reply is a JSON line followed by its raw frame: a matrix (`array.bytes`, Float64,
# column-major) or a figure artifact (`artifact.bytes`). Nothing here draws by itself: figures
# are SqueroPlot's, session events and the Paperboat bridges are SqueroBase's, and solving and
# simulation belong to Paperboat.

using JSON3
using LinearAlgebra
using SparseArrays
using Statistics
using SqueroBase
using SqueroPlot

const PROTOCOL = 0
const PACKAGES = ["JSON3", "LinearAlgebra", "SparseArrays", "Statistics", "SqueroBase", "SqueroPlot"]
const IMAGE = get(ENV, "SQUERO_KERNEL_IMAGE", "squero-julia-kernel:$(VERSION)-r2")
const VERSIONS = Dict("SqueroBase" => string(pkgversion(SqueroBase)), "SqueroPlot" => string(pkgversion(SqueroPlot)))
const SESSION_MODULES = ("Base", "Core", "Main", "LinearAlgebra", "SparseArrays", "Statistics", "SqueroBase", "SqueroPlot")

"""A fresh module is the session: `reset` and `clear` get a new one, as a new REPL would."""
function fresh_module()
    mod = Module(gensym(:SqueroSession))
    Core.eval(mod, :(using LinearAlgebra, SparseArrays, Statistics, SqueroBase, SqueroPlot))
    mod
end

mutable struct Session
    mod::Module
    source::String
end

const SESSION = Session(fresh_module(), "")

# ---------------------------------------------------------------------------------------------
# Figures: the kernel snapshots the figures a script changed and keeps the artifacts per version,
# so the app's history can export them after the session has moved on.

const SNAPSHOT_FORMATS = (:png, :svg, :pdf, :eps)
const ARTIFACT_LIMIT = 256                   # stored versions; the app keeps its own copies
const LAST_VERSION = Dict{String, String}()  # figure id → latest version
const STORE = Dict{String, Any}()            # "id@version" → Snapshot
const STORE_ORDER = String[]
const LINES = Dict{String, Vector{Int}}()    # figure id → source lines that drew into it
const MIME = Dict("png" => "image/png", "svg" => "image/svg+xml", "pdf" => "application/pdf",
                  "eps" => "application/postscript", "html" => "text/html")

figure_of(x::SqueroPlot.Figure) = x
figure_of(x::SqueroPlot.FigureAxisPlot) = x.figure
figure_of(x::SqueroPlot.AxisPlot) = x.axis.figure
figure_of(x::SqueroPlot.AbstractAxis) = x.figure
figure_of(x) = nothing

"""Figures reachable from the session: its bindings, the last value and the current figure."""
function session_figures(mod::Module, value)
    found = IdDict{Any, Nothing}()
    add(x) = (f = figure_of(x); f === nothing || (found[f] = nothing))
    for name in names(mod; all = true, imported = false)
        startswith(string(name), "#") && continue
        isdefined(mod, name) || continue
        v = getfield(mod, name)
        add(v)
        if v isa Union{Tuple, AbstractVector} && length(v) <= 64
            foreach(add, v)
        end
    end
    add(value)
    SqueroPlot.current_figure() === nothing || add(SqueroPlot.current_figure())
    figs = collect(keys(found))
    sort!(figs; by = f -> f.serial)
    figs
end

function store!(snap)
    key = string(snap.id, "@", snap.version)
    haskey(STORE, key) || push!(STORE_ORDER, key)
    STORE[key] = snap
    while length(STORE_ORDER) > ARTIFACT_LIMIT
        old = popfirst!(STORE_ORDER)
        delete!(STORE, old)
        delete!(VIEWS, old)
    end
end

function figure_meta(snap; source = "")
    Dict{String, Any}(
        "id" => snap.id, "version" => snap.version, "title" => snap.title,
        "width" => snap.width, "height" => snap.height, "plots" => snap.plots, "axes" => snap.axes,
        "formats" => [string(f) for f in snap.formats], "lines" => get(LINES, snap.id, Int[]),
        "source" => source,
    )
end

"""Figures seen after any statement of the current eval (a later `clear()` cannot hide them)."""
const SEEN = IdDict{Any, Nothing}()

"""Snapshot every figure the eval reached whose drawing changed since its last snapshot."""
function capture_figures(value)
    out = Any[]
    for f in session_figures(SESSION.mod, value)
        SEEN[f] = nothing
    end
    figs = sort!(collect(keys(SEEN)); by = f -> f.serial)
    empty!(SEEN)
    for fig in figs
        id = SqueroPlot.figure_id(fig)
        snap = try
            SqueroPlot.snapshot(fig; formats = SNAPSHOT_FORMATS, since = get(LAST_VERSION, id, nothing))
        catch err
            push!(out, Dict{String, Any}("id" => id, "error" => sprint(showerror, err)))
            continue
        end
        snap === nothing && continue
        LAST_VERSION[id] = snap.version
        store!(snap)
        push!(out, figure_meta(snap))
    end
    out
end

"""A 2-variable optimization result as a SqueroPlot surface with the optimum marked."""
function optimum_figure(result::AbstractDict, title::AbstractString)
    grid = result["grid"]
    x = Float64.(grid["x"])
    y = Float64.(grid["y"])
    rows = grid["z"]  # rows[j][i] = f(x[i], y[j]) (Paperboat's layout)
    Z = [Float64(rows[j][i]) for i in eachindex(x), j in eachindex(y)]
    xo = Float64.(result["x"])
    fo = Float64(get(result, "objective", 0.0))
    fig = SqueroPlot.Figure(; size = (640, 480), title = title)
    ax = SqueroPlot.Axis3(fig[1, 1]; title = title, xlabel = "x₁", ylabel = "x₂", zlabel = "f(x)")
    s = SqueroPlot.surface!(ax, x, y, Z)
    lo = minimum(Z)
    SqueroPlot.lines!(ax, [xo[1], xo[1]], [xo[2], xo[2]], [lo, fo]; color = :red, linewidth = 1.5)
    SqueroPlot.scatter!(ax, [xo[1]], [xo[2]], [fo]; color = :red, markersize = 12, strokecolor = :white, strokewidth = 1.5,
        label = "optimum")
    SqueroPlot.Colorbar(fig[1, 2], s; label = "objective")
    fig
end

# ---------------------------------------------------------------------------------------------
# Values

"""Plain JSON descriptions for a value; arrays stay in the session and travel with `get`."""
function describe(value)
    if value === nothing
        return Dict("type" => "Nothing")
    elseif value isa Bool || value isa Number
        return Dict("type" => string(typeof(value)), "shape" => "1", "value" => value)
    elseif value isa AbstractString
        return Dict("type" => "String", "shape" => "text", "value" => String(value))
    elseif value isa AbstractArray
        rows, cols = size(value, 1), length(size(value)) > 1 ? size(value, 2) : 1
        shape = ndims(value) == 1 ? string(length(value)) : "$(rows) × $(cols)"
        element = eltype(value)
        scalar = element <: Integer ? "Int64" : element <: AbstractFloat ? "Float64" : element <: Bool ? "Bool" : string(element)
        kind = ndims(value) == 1 ? "Vector{$scalar}" : "Matrix{$scalar}"
        preview = Float64[]
        if element <: Number
            # Row by row, as the matrix reads (a column-major walk would show A[2,1] second).
            walk = ndims(value) == 2 ? (value[i, j] for i in axes(value, 1) for j in axes(value, 2)) : value
            for x in Iterators.take(walk, 5)
                push!(preview, Float64(x))
            end
        end
        return Dict(
            "type" => kind,
            "shape" => shape,
            "preview" => preview,
            "runnable" => element <: Number,
        )
    elseif value isa SqueroPlot.Figure || value isa SqueroPlot.FigureAxisPlot
        fig = figure_of(value)
        return Dict("type" => "Figure", "shape" => "$(round(Int, fig.size[1])) × $(round(Int, fig.size[2]))",
                    "figure" => SqueroPlot.figure_id(fig))
    else
        return Dict("type" => string(typeof(value)), "shape" => "—")
    end
end

"""`whos`: the session's bindings and functions, with the handful of values the workspace cards show."""
function whois()
    out = Any[]
    for name in names(SESSION.mod; all = true, imported = false)
        text = string(name)
        startswith(text, "#") && continue
        text in SESSION_MODULES && continue
        isdefined(SESSION.mod, name) || continue
        value = getfield(SESSION.mod, name)
        (value isa Module || value isa Type) && continue
        if value isa Function  # the user's own functions, listed as a REPL's varinfo would
            push!(out, Dict{String, Any}("name" => text, "type" => "Function", "shape" => "—"))
            continue
        end
        item = describe(value)
        item["name"] = text
        push!(out, item)
    end
    sort!(out, by = item -> item["name"])
    out
end

function array_frame(value::AbstractArray{<:Number})
    rows = ndims(value) == 1 ? 1 : size(value, 1)
    cols = ndims(value) == 1 ? length(value) : size(value, 2)
    bytes = Vector{UInt8}(reinterpret(UInt8, vec(collect(Float64, value))))
    return rows, cols, bytes
end

"""The value as the REPL prints it (`text/plain`, limited to a screen), or "" for nothing."""
shown(value) = value === nothing ? "" :
    sprint(io -> show(IOContext(io, :limit => true, :displaysize => (24, 80)), MIME"text/plain"(), value))

# ---------------------------------------------------------------------------------------------
# Protocol

function reply(payload; id = nothing)
    out = Dict{String, Any}()
    for (key, value) in payload
        out[string(key)] = value
    end
    id === nothing || (out["id"] = id)
    out["ok"] = get(out, "ok", true)
    write(stdout, JSON3.write(out))
    write(stdout, UInt8('\n'))
    flush(stdout)
end

function fail(message; id = nothing)
    reply(Dict("ok" => false, "error" => string(message)); id = id)
end

"""A JSON header and its binary frame, back to back."""
function reply_frame(header::Dict{String, Any}, bytes::Vector{UInt8}; id = nothing)
    id === nothing || (header["id"] = id)
    header["ok"] = true
    write(stdout, JSON3.write(header))
    write(stdout, UInt8('\n'))
    write(stdout, bytes)
    flush(stdout)
end

"""
Apply the session events the statement just recorded: `clear()` swaps in a fresh module before
the next statement, `clear(:x)` carries every other binding over. The events stay queued for the UI.
"""
function apply_events(from::Int)
    for event in SqueroBase.EVENTS[from+1:end]
        get(event, "type", "") == "clear" || continue
        dropped = get(event, "names", nothing)
        old = SESSION.mod
        SESSION.mod = fresh_module()
        dropped === nothing && continue
        # ponytail: a carried-over function keeps its old module's globals; fine for a workspace.
        for name in names(old; all = true, imported = false)
            text = string(name)
            (startswith(text, "#") || text in dropped || !isdefined(old, name)) && continue
            value = getfield(old, name)
            value isa Module && continue
            Core.eval(SESSION.mod, Expr(:(=), name, QuoteNode(value)))
        end
    end
end

"""What a statement changed in the current figure: its content and plot counts."""
function figure_signature()
    fig = SqueroPlot.current_figure()
    fig === nothing && return nothing
    (fig, length(fig.content), SqueroPlot.plot_count(fig), SqueroPlot.axes_count(fig))
end

"""Run each top-level statement in turn, as a script would, applying `clear` between them."""
function run_statements(code::AbstractString)
    value = nothing
    line = nothing
    statements = Meta.parseall(code).args
    # A syntax error anywhere stops the script before its first statement runs.
    for ex in statements
        ex isa Expr && ex.head in (:error, :incomplete) && Core.eval(SESSION.mod, ex)
    end
    for ex in statements
        if ex isa LineNumberNode
            line = ex
            continue
        end
        from = length(SqueroBase.EVENTS)
        before = figure_signature()
        value = Core.eval(SESSION.mod, line === nothing ? ex : Expr(:toplevel, line, ex))
        after = figure_signature()
        # Remember which lines drew into which figure, for the editor's "→ figure" links.
        if after !== nothing && after != before && line !== nothing
            lines = get!(LINES, SqueroPlot.figure_id(after[1]), Int[])
            line.line in lines || push!(lines, line.line)
        end
        length(SqueroBase.EVENTS) > from && foreach(f -> SEEN[f] = nothing, session_figures(SESSION.mod, value))
        apply_events(from)
    end
    value
end

"""Run code in the session with stdout/stderr captured, so the protocol stream stays clean."""
function evaluate(code::AbstractString)
    isempty(strip(code)) && return (value = nothing, error = nothing, stdout = "")
    value = nothing
    error = nothing
    text = ""
    path, stream = mktemp()
    try
        value = redirect_stdout(stream) do
            redirect_stderr(stream) do
                run_statements(code)
            end
        end
    catch err
        error = sprint(showerror, err)
    finally
        close(stream)
        text = isfile(path) ? read(path, String) : ""
        rm(path; force = true)
    end
    (value = value, error = error, stdout = text)
end

"""What the statement recorded for the app: problems, runs and events."""
take_queues() = (
    Any[JSON3.read(problem_json(p)) for p in SqueroBase.take_problems()],
    Any[JSON3.read(run_json(r)) for r in SqueroBase.take_runs()],
    SqueroBase.take_events(),
)

function find_snapshot(request)
    id = string(get(request, "figure", ""))
    version = string(something(get(request, "version", nothing), get(LAST_VERSION, id, "")))
    snap = get(STORE, string(id, "@", version), nothing)
    snap === nothing && error("no stored artifact for $(id)@$(version)")
    snap
end

# The stage's view of a history version: a copy of the version's figure that pan, zoom and
# rotate change. The stored artifacts and the snapshot's own copy never change.
const VIEWS = Dict{String, Any}()

keyof(snap) = string(snap.id, "@", snap.version)

"""A figure for drawing a version: its view (if asked and present) or a fresh copy."""
function version_figure(snap, request)
    key = keyof(snap)
    use_view = Bool(get(request, "view", true))
    use_view && haskey(VIEWS, key) && return VIEWS[key]
    return SqueroPlot.snapshot_figure(snap)
end

"""`(width, height)` from a request, within sane bounds, or `nothing`."""
function requested_size(request)
    haskey(request, "width") && haskey(request, "height") || return nothing
    w = clamp(round(Int, Float64(request["width"])), 120, 6000)
    h = clamp(round(Int, Float64(request["height"])), 90, 6000)
    return (w, h)
end

layout_json(fig) = [Dict{String, Any}("index" => a.index, "kind" => string(a.kind), "x" => a.x, "y" => a.y,
                                      "w" => a.w, "h" => a.h, "title" => a.title) for a in SqueroPlot.axes_layout(fig)]

function render_bytes(fig, format::Symbol, request)
    ppu = clamp(Float64(get(request, "px_per_unit", 2)), 0.5, 4.0)
    format === :html && return Vector{UInt8}(SqueroPlot.to_html(fig))
    return SqueroPlot.render(fig; format = format, px_per_unit = ppu)
end

function send_artifact(request, allowed; id = nothing)
    snap = find_snapshot(request)
    format = Symbol(lowercase(string(get(request, "format", "svg"))))
    format in allowed || error("format must be one of $(join(allowed, ", "))")
    size = requested_size(request)
    view_state = get(request, "view_state", nothing)
    use_view = Bool(get(request, "view", false))
    has_client_view = use_view && view_state isa AbstractDict
    same_size = size === nothing || size == (snap.width, snap.height)
    fresh = !same_size || haskey(request, "px_per_unit") || has_client_view || (use_view && haskey(VIEWS, keyof(snap)))
    if fresh
        # Drawn again from the version's own figure (or its view) at the asked size: the stored
        # artifacts are the drawing as it was made.
        fig = if has_client_view
            cloned = SqueroPlot.snapshot_figure(snap)
            SqueroPlot.apply_view!(cloned, view_state)
            cloned
        elseif use_view && haskey(VIEWS, keyof(snap))
            VIEWS[keyof(snap)]
        else
            SqueroPlot.snapshot_figure(snap)
        end
        size === nothing || resize!(fig, size...)
        bytes = render_bytes(fig, format, request)
        width, height = round.(Int, fig.size)
    else
        bytes = SqueroPlot.save_snapshot(snap, format)
        width, height = snap.width, snap.height
    end
    reply_frame(Dict{String, Any}("artifact" => Dict(
        "figure" => snap.id, "version" => snap.version, "format" => string(format),
        "mime" => MIME[string(format)], "bytes" => length(bytes), "title" => snap.title,
        "width" => width, "height" => height,
    )), bytes; id = id)
end

"""Structured 2D/3D scene specification and binary typed buffers for the interactive stage."""
function send_scene(request; id = nothing)
    snap = find_snapshot(request)
    spec, bytes = SqueroPlot.scene_spec(snap.model)
    if isempty(bytes)
        return reply(Dict{String, Any}("scene" => spec); id = id)
    end
    return reply_frame(Dict{String, Any}(
        "scene" => spec,
        "artifact" => Dict(
            "figure" => snap.id,
            "version" => snap.version,
            "format" => "scene",
            "mime" => "application/octet-stream",
            "bytes" => length(bytes),
            "title" => snap.title,
            "width" => snap.width,
            "height" => snap.height,
        ),
    ), bytes; id = id)
end

"""Draw a version at the stage's size (its view if it has one) with the axes' layout."""
function send_render(request, snap; id = nothing)
    format = Symbol(lowercase(string(get(request, "format", "png"))))
    format in (:png, :svg) || error("figure.render draws png or svg")
    fig = version_figure(snap, request)
    size = requested_size(request)
    size === nothing || resize!(fig, size...)
    bytes = render_bytes(fig, format, request)
    reply_frame(Dict{String, Any}(
        "artifact" => Dict("figure" => snap.id, "version" => snap.version, "format" => string(format),
                           "mime" => MIME[string(format)], "bytes" => length(bytes), "title" => snap.title,
                           "width" => round(Int, fig.size[1]), "height" => round(Int, fig.size[2])),
        "axes" => layout_json(fig),
        "view" => haskey(VIEWS, keyof(snap)),
    ), bytes; id = id)
end

"""Pan, zoom, rotate or reset a version's view, then draw it (see `send_render`)."""
function interact(request; id = nothing)
    snap = find_snapshot(request)
    key = keyof(snap)
    action = string(get(request, "action", ""))
    if action == "reset"
        delete!(VIEWS, key)
        return send_render(request, snap; id = id)
    end
    view = get!(() -> SqueroPlot.snapshot_figure(snap), VIEWS, key)
    size = requested_size(request)
    size === nothing || resize!(view, size...)
    axes = SqueroPlot.axes_of(view)
    index = Int(get(request, "axis", 1))
    1 <= index <= length(axes) || error("no axis $index in $(snap.id)")
    ax = axes[index]
    if action == "zoom"
        factor = clamp(Float64(get(request, "factor", 1.0)), 0.05, 20.0)
        around = (Float64(get(request, "fx", 0.5)), Float64(get(request, "fy", 0.5)))
        SqueroPlot.zoom!(ax, factor; around = around)
    elseif action == "pan"
        SqueroPlot.pan!(ax, Float64(get(request, "dx", 0.0)), Float64(get(request, "dy", 0.0)))
    elseif action == "rotate"
        ax isa SqueroPlot.Axis3 || error("rotate needs an Axis3")
        SqueroPlot.rotate!(ax, Float64(get(request, "daz", 0.0)), Float64(get(request, "del", 0.0)))
    else
        error("figure.interact action must be pan, zoom, rotate or reset")
    end
    return send_render(request, snap; id = id)
end

function handle(request::AbstractDict)
    op = string(get(request, "op", ""))
    id = get(request, "id", nothing)

    if op == "hello"
        return reply(Dict(
            "op" => "hello",
            "julia" => string(VERSION),
            "image" => IMAGE,
            "protocol" => PROTOCOL,
            "packages" => PACKAGES,
            "versions" => VERSIONS,
        ); id = id)
    elseif op == "eval"
        code = string(get(request, "code", ""))
        SESSION.source = code
        result = evaluate(code)
        figures = capture_figures(result.value)
        problems, runs, events = take_queues()
        common = Dict{String, Any}("stdout" => result.stdout, "figures" => figures, "problems" => problems,
                                   "runs" => runs, "events" => events)
        if result.error !== nothing
            return reply(merge(common, Dict{String, Any}("ok" => false, "error" => result.error)); id = id)
        end
        return reply(merge(common, Dict{String, Any}("value" => describe(result.value), "text" => shown(result.value))); id = id)
    elseif op == "whos"
        return reply(Dict("value" => whois()); id = id)
    elseif op == "get"
        name = Symbol(string(get(request, "name", "")))
        if !isdefined(SESSION.mod, name)
            return fail("$(name) is not defined"; id = id)
        end
        value = getfield(SESSION.mod, name)
        if value isa AbstractArray{<:Number}
            rows, cols, bytes = array_frame(value)
            payload = Dict(
                "id" => id,
                "ok" => true,
                "array" => Dict(
                    "rows" => rows, "cols" => cols, "dtype" => "f64",
                    "order" => "col", "bytes" => length(bytes),
                ),
            )
            write(stdout, JSON3.write(payload))
            write(stdout, UInt8('\n'))
            write(stdout, bytes)
            flush(stdout)
            return
        end
        return reply(Dict("value" => describe(value)); id = id)
    elseif op == "set"
        name = Symbol(string(get(request, "name", "")))
        rows = Int(get(request, "rows", 1))
        cols = Int(get(request, "cols", 1))
        count = Int(get(request, "bytes", rows * cols * sizeof(Float64)))
        bytes = Vector{UInt8}(undef, count)
        readbytes!(stdin, bytes, count)
        values = reinterpret(Float64, bytes)
        value = rows == 1 && cols == 1 ? values[1] :
                rows == 1 ? collect(values) : reshape(collect(values), rows, cols)
        Core.eval(SESSION.mod, :($(name) = $value))
        return reply(Dict("value" => describe(value)); id = id)
    elseif op == "snapshot"
        line = Int(get(request, "line", 0))
        prefix = join(split(SESSION.source, '\n')[1:min(line, length(split(SESSION.source, '\n')))], '\n')
        saved = SESSION.mod
        current = SqueroPlot.current_figure()
        SESSION.mod = fresh_module()
        result = evaluate(prefix)
        variables = result.error === nothing ? whois() : Any[]
        take_queues()
        empty!(SEEN)
        SESSION.mod = saved
        SqueroPlot.CURRENT_FIGURE[] = current
        return reply(Dict(
            "value" => variables,
            "error" => result.error,
        ); id = id)
    elseif op == "figure.get"
        # The preview the stage shows: SVG (default) or PNG, as a binary frame.
        return send_artifact(request, (:svg, :png); id = id)
    elseif op == "figure.export"
        # Any stored artifact of a history version; HTML is built from the stored SVG.
        return send_artifact(request, (:png, :svg, :pdf, :eps, :html); id = id)
    elseif op == "figure.scene"
        return send_scene(request; id = id)
    elseif op == "figure.render"
        # The stage: a version drawn at the panel's size, with its axes' rectangles for hit-testing.
        return send_render(request, find_snapshot(request); id = id)
    elseif op == "figure.interact"
        return interact(request; id = id)
    elseif op == "figure.list"
        return reply(Dict("value" => [figure_meta(STORE[k]) for k in STORE_ORDER]); id = id)
    elseif op == "plot.optimum"
        result = get(request, "result", nothing)
        result isa AbstractDict && haskey(result, "grid") && haskey(result, "x") ||
            return fail("plot.optimum needs a solver result with x and grid"; id = id)
        title = string(get(request, "title", "optimum"))
        current = SqueroPlot.current_figure()
        fig = optimum_figure(result, title)
        SqueroPlot.CURRENT_FIGURE[] = current  # the app's plot does not become the script's figure
        snap = SqueroPlot.snapshot(fig; formats = SNAPSHOT_FORMATS)
        LAST_VERSION[snap.id] = snap.version
        store!(snap)
        return reply(Dict("figure" => figure_meta(snap)); id = id)
    elseif op == "reset"
        SESSION.mod = fresh_module()
        SESSION.source = ""
        SqueroBase.reset_queues!()
        SqueroPlot.CURRENT_FIGURE[] = nothing
        empty!(LINES)  # stored artifacts stay: the app's history outlives the session
        return reply(Dict("value" => nothing); id = id)
    elseif op == "shutdown"
        reply(Dict("value" => nothing); id = id)
        exit(0)
    else
        return fail("unknown op \"$op\""; id = id)
    end
end

function main()
    while !eof(stdin)
        line = readline(stdin)
        isempty(strip(line)) && continue
        request = try
            JSON3.read(line, Dict{String, Any})
        catch err
            fail("invalid JSON: $(sprint(showerror, err))")
            continue
        end
        try
            handle(request)
        catch err
            bt = catch_backtrace()
            fail(sprint(showerror, err) * "\n" * sprint(io -> Base.show_backtrace(io, bt)); id = get(request, "id", nothing))
        end
    end
end

main()
