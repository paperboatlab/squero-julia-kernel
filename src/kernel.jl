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

# Save the protocol output stream before any `redirect_stdout` so JSON replies and async
# debugger events never mix with user `println` output.
const PROTO_OUT = stdout
const PROTO_LOCK = ReentrantLock()

include("debugger.jl")
using .SqueroDebugger

const PROTOCOL = 0
const PACKAGES = ["JSON3", "LinearAlgebra", "SparseArrays", "Statistics", "SqueroBase", "SqueroPlot"]
const IMAGE = get(ENV, "SQUERO_KERNEL_IMAGE", "squero-julia-kernel:$(VERSION)-r3")
const IMAGE_DIGEST = get(ENV, "SQUERO_KERNEL_DIGEST", "")
const VERSIONS = Dict("SqueroBase" => string(pkgversion(SqueroBase)), "SqueroPlot" => string(pkgversion(SqueroPlot)))
const SESSION_MODULES = Set(["Base", "Core", "Main", "eval", "include", "LinearAlgebra", "SparseArrays", "Statistics", "SqueroBase", "SqueroPlot"])

mutable struct Session
    mod::Module
    source::String
    file_stack::Vector{String}
    vfs::Dict{String, String}
end

function norm_rel(path::AbstractString)
    s = replace(String(path), '\\' => '/')
    parts = String[]
    for part in split(s, '/')
        (isempty(part) || part == ".") && continue
        if part == ".."
            if !isempty(parts) && parts[end] != ".."
                pop!(parts)
            else
                push!(parts, "..")
            end
        else
            push!(parts, part)
        end
    end
    join(parts, "/")
end

function workspace_relpath(full_path::AbstractString)
    p = try
        relpath(abspath(String(full_path)), abspath(pwd()))
    catch
        String(full_path)
    end
    startswith(p, "..") ? replace(String(full_path), '\\' => '/') : replace(p, '\\' => '/')
end

function resolve_include_target(path::AbstractString)
    raw = replace(String(path), '\\' => '/')
    if isabspath(raw)
        norm = normpath(raw)
        rel = workspace_relpath(norm)
        haskey(SESSION.vfs, rel) && return (rel, norm, SESSION.vfs[rel])
        if isfile(norm)
            return (rel, norm, nothing)
        end
        return (nothing, norm, nothing)
    end
    candidates = String[]
    for cur in reverse(SESSION.file_stack)
        isempty(cur) && continue
        rel_cur = isabspath(cur) ? workspace_relpath(cur) : replace(cur, '\\' => '/')
        d = dirname(rel_cur)
        cand = (isempty(d) || d == ".") ? norm_rel(raw) : norm_rel("$d/$raw")
        push!(candidates, cand)
    end
    push!(candidates, norm_rel(raw))
    for cand in candidates
        haskey(SESSION.vfs, cand) && return (cand, abspath(joinpath(pwd(), cand)), SESSION.vfs[cand])
        full = normpath(joinpath(pwd(), cand))
        isfile(full) && return (cand, full, nothing)
    end
    for cur in reverse(SESSION.file_stack)
        isabspath(cur) || continue
        full = normpath(joinpath(dirname(cur), String(path)))
        isfile(full) && return (workspace_relpath(full), full, nothing)
    end
    return (nothing, raw, nothing)
end

function eval_mapped_source(mod::Module, mapexpr::Function, src::AbstractString, filename::AbstractString)
    val = nothing
    tree = Meta.parseall(src; filename = filename)
    line = nothing
    for ex in tree.args
        if ex isa LineNumberNode
            line = ex
            continue
        end
        mapped = mapexpr(ex)
        val = Core.eval(mod, line === nothing ? mapped : Expr(:toplevel, line, mapped))
    end
    val
end

function session_include(mod::Module, path::AbstractString; mapexpr::Union{Nothing, Function} = nothing)
    display_file, full, vfs_src = resolve_include_target(path)
    display_file === nothing && throw(SystemError("opening file $(repr(String(path)))", 2))
    push!(SESSION.file_stack, full)
    try
        if SqueroDebugger.STATE.active && mapexpr === nothing
            src = vfs_src !== nothing ? vfs_src : read(full, String)
            return run_debug_statements(src, display_file; nested = true, mod = mod)
        end
        src = vfs_src !== nothing ? vfs_src : read(full, String)
        if mapexpr === nothing
            return Base.include_string(mod, src, full)
        else
            return eval_mapped_source(mod, mapexpr, src, full)
        end
    finally
        pop!(SESSION.file_stack)
    end
end

"""A fresh module is the session: `reset` and `clear` get a new one, as a new REPL would."""
function fresh_module()
    mod = Module(gensym(:SqueroSession))
    Core.eval(mod, :(using LinearAlgebra, SparseArrays, Statistics, SqueroBase, SqueroPlot))
    Core.eval(mod, :(include(path::AbstractString) = $(session_include)($mod, path)))
    Core.eval(mod, :(include(mapexpr::Function, path::AbstractString) = $(session_include)($mod, path; mapexpr = mapexpr)))
    mod
end

const SESSION = Session(fresh_module(), "", String[], Dict{String, String}())

# Cancel: the launcher sends SIGINT, which stops the running statement with an InterruptException
# (the eval replies with it) instead of ending the kernel.
Base.exit_on_sigint(false)

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
    elseif value isa Bool
        return Dict("type" => string(typeof(value)), "shape" => "1", "value" => value)
    elseif value isa Number
        v = value isa AbstractFloat && !isfinite(value) ? string(value) : value
        return Dict("type" => string(typeof(value)), "shape" => "1", "value" => v)
    elseif value isa AbstractString
        return Dict("type" => "String", "shape" => "text", "value" => String(value))
    elseif value isa AbstractArray
        rows, cols = size(value, 1), length(size(value)) > 1 ? size(value, 2) : 1
        shape = ndims(value) == 1 ? string(length(value)) : "$(rows) × $(cols)"
        element = eltype(value)
        scalar = element <: Integer ? "Int64" : element <: AbstractFloat ? "Float64" : element <: Bool ? "Bool" : string(element)
        kind = ndims(value) == 1 ? "Vector{$scalar}" : "Matrix{$scalar}"
        preview = Any[]
        if element <: Number
            # Row by row, as the matrix reads (a column-major walk would show A[2,1] second).
            walk = ndims(value) == 2 ? (value[i, j] for i in axes(value, 1) for j in axes(value, 2)) : value
            for x in Iterators.take(walk, 5)
                fx = Float64(x)
                push!(preview, isfinite(fx) ? fx : string(fx))
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
# Help: docstrings for the app's Help window

# Markdown is in the sysimage but not a project dependency; loading it by id renders docstrings.
const Markdown = Base.require(Base.PkgId(Base.UUID("d6f4376e-aef5-505a-96c1-9c027394607a"), "Markdown"))
const DOC_MODULES = (Base, LinearAlgebra, SparseArrays, Statistics, SqueroBase, SqueroPlot)
const NAME = r"^[\p{L}_][\p{L}\p{N}_!]*(\.[\p{L}_][\p{L}\p{N}_!]*)*$"

"""A name's docs as HTML (Julia's Markdown renders them). Only names and operators: nothing runs."""
function doc_html(name::AbstractString)
    ex = occursin(NAME, name) ? Meta.parse(name) : Base.isoperator(Symbol(name)) ? Symbol(name) : nothing
    ex === nothing && error("not a name: $(name)")
    found = Core.eval(SESSION.mod, :(Base.Docs.@doc $ex))
    found === nothing && return nothing
    # Outside a REPL, @doc gives the raw docstring; Markdown parses it as the REPL would.
    text = found isa Base.Docs.DocStr ? sprint(io -> foreach(t -> print(io, t), found.text)) : nothing
    md = text === nothing ? found : Base.invokelatest(Markdown.parse, text)
    sprint(io -> Base.invokelatest(show, io, MIME"text/html"(), md))
end

"""What the Help window can search: the exported names of the session's modules and its own bindings."""
function doc_names()
    out = Dict{String, String}()
    for m in DOC_MODULES, n in names(m)
        text = string(n)
        (startswith(text, "#") || text == string(nameof(m))) && continue
        get!(out, text, string(nameof(m)))
    end
    for n in names(SESSION.mod; all = true, imported = false)
        text = string(n)
        startswith(text, "#") || text in SESSION_MODULES || (out[text] = "workspace")
    end
    [Dict("name" => k, "module" => v) for (k, v) in sort!(collect(out); by = first)]
end

# ---------------------------------------------------------------------------------------------
# Protocol

function emit(payload)
    out = Dict{String, Any}()
    for (key, value) in payload
        out[string(key)] = value
    end
    lock(PROTO_LOCK) do
        write(PROTO_OUT, JSON3.write(out))
        write(PROTO_OUT, UInt8('\n'))
        flush(PROTO_OUT)
    end
end

function reply(payload; id = nothing)
    out = Dict{String, Any}()
    for (key, value) in payload
        out[string(key)] = value
    end
    id === nothing || (out["id"] = id)
    out["ok"] = get(out, "ok", true)
    lock(PROTO_LOCK) do
        write(PROTO_OUT, JSON3.write(out))
        write(PROTO_OUT, UInt8('\n'))
        flush(PROTO_OUT)
    end
end

function fail(message; id = nothing)
    reply(Dict("ok" => false, "error" => string(message)); id = id)
end

"""A JSON header and its binary frame, back to back."""
function reply_frame(header::Dict{String, Any}, bytes::Vector{UInt8}; id = nothing)
    id === nothing || (header["id"] = id)
    header["ok"] = true
    lock(PROTO_LOCK) do
        write(PROTO_OUT, JSON3.write(header))
        write(PROTO_OUT, UInt8('\n'))
        write(PROTO_OUT, bytes)
        flush(PROTO_OUT)
    end
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
        SqueroDebugger.STATE.active && (SqueroDebugger.STATE.mod = SESSION.mod)
        dropped === nothing && continue
        # ponytail: a carried-over function keeps its old module's globals; fine for a workspace.
        for name in names(old; all = true, imported = false)
            text = string(name)
            (startswith(text, "#") || text in dropped || text in SESSION_MODULES || !isdefined(old, name)) && continue
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
function run_statements(code::AbstractString; file::AbstractString = "")
    value = nothing
    line = nothing
    fname = isempty(file) ? "none" : String(file)
    statements = Meta.parseall(code; filename = fname).args
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
function evaluate(code::AbstractString; file::AbstractString = "")
    isempty(strip(code)) && return (value = nothing, error = nothing, stdout = "")
    value = nothing
    error = nothing
    text = ""
    path, stream = mktemp()
    !isempty(file) && push!(SESSION.file_stack, String(file))
    try
        value = redirect_stdout(stream) do
            redirect_stderr(stream) do
                run_statements(code; file = file)
            end
        end
    catch err
        error = sprint(showerror, err)
    finally
        !isempty(file) && !isempty(SESSION.file_stack) && pop!(SESSION.file_stack)
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

const DEBUG_TASK = Ref{Union{Task, Nothing}}(nothing)

function serialize_frames(frames)
    out = Any[]
    for f in reverse(frames)
        push!(out, Dict{String, Any}(
            "id" => f.id,
            "name" => f.name,
            "file" => f.file,
            "line" => f.line,
        ))
    end
    out
end

function serialize_locals(frame_id::Int)
    pairs = SqueroDebugger.frame_locals(frame_id)
    out = Any[]
    seen = Set{String}()
    for (k, v) in pairs
        name = string(k)
        push!(seen, name)
        item = describe(v)
        item["name"] = name
        item["text"] = shown(v)
        push!(out, item)
    end
    idx = findfirst(f -> f.id == frame_id, SqueroDebugger.STATE.frames)
    if idx !== nothing && (SqueroDebugger.STATE.frames[idx].name == "top-level" || startswith(SqueroDebugger.STATE.frames[idx].name, "include("))
        for item in whois()
            item["type"] == "Function" && continue
            item["name"] in seen && continue
            if isdefined(SESSION.mod, Symbol(item["name"]))
                item["text"] = shown(getfield(SESSION.mod, Symbol(item["name"])))
            end
            push!(out, item)
        end
    end
    out
end

function run_debug_statements(code::AbstractString, file::String; nested::Bool = false, mod::Module = SESSION.mod)
    value = nothing
    line = nothing
    ln = 1
    active_mod = mod
    statements = Meta.parseall(code; filename = file).args
    for ex in statements
        ex isa Expr && ex.head in (:error, :incomplete) && Core.eval(active_mod, ex)
    end
    frame_name = nested ? "include($(basename(file)))" : "top-level"
    SqueroDebugger.enter!(frame_name, file, 1, () -> Pair{Symbol, Any}[])
    try
        for ex in statements
            if ex isa LineNumberNode
                line = ex
                ln = ex.line
                continue
            end
            SqueroDebugger.check!(ln, file, () -> Pair{Symbol, Any}[])
            from = length(SqueroBase.EVENTS)
            before = figure_signature()
            inst = SqueroDebugger.instrument(ex, file, ln, Set{Symbol}())
            prev_mod = SESSION.mod
            value = Core.eval(active_mod, line === nothing ? inst : Expr(:toplevel, line, inst))
            after = figure_signature()
            if after !== nothing && after != before && line !== nothing
                lines = get!(LINES, SqueroPlot.figure_id(after[1]), Int[])
                line.line in lines || push!(lines, line.line)
            end
            length(SqueroBase.EVENTS) > from && foreach(f -> SEEN[f] = nothing, session_figures(SESSION.mod, value))
            apply_events(from)
            if SESSION.mod !== prev_mod && active_mod === prev_mod
                active_mod = SESSION.mod
            end
        end
    finally
        SqueroDebugger.exit!()
    end
    value
end

function start_debug_session!(file::String, code::String; stop_on_entry::Bool = false)
    if DEBUG_TASK[] !== nothing && !istaskdone(DEBUG_TASK[])
        SqueroDebugger.request_command!(:stop)
        try wait(DEBUG_TASK[]) catch end
    end
    SESSION.source = code
    log_path, stream = mktemp()
    offset = Ref(0)
    drain_stdout = () -> begin
        isopen(stream) && flush(stream)
        isfile(log_path) || return ""
        raw = read(log_path)
        offset[] >= length(raw) && return ""
        chunk = String(raw[(offset[] + 1):end])
        offset[] = length(raw)
        chunk
    end

    SqueroDebugger.reset_session!(
        SESSION.mod,
        file;
        stop_on_entry = stop_on_entry,
        on_pause = (reason, f, ln, frames) -> begin
            top_id = isempty(frames) ? 0 : frames[end].id
            figs = capture_figures(nothing)
            emit(Dict{String, Any}(
                "event" => "debug.stopped",
                "reason" => reason,
                "file" => f,
                "line" => ln,
                "frames" => serialize_frames(frames),
                "locals" => serialize_locals(top_id),
                "stdout" => drain_stdout(),
                "figures" => figs,
            ))
        end,
        on_resume = () -> emit(Dict{String, Any}("event" => "debug.resumed")),
    )

    DEBUG_TASK[] = @async begin
        value = nothing
        error_msg = nothing
        stopped = false
        !isempty(file) && push!(SESSION.file_stack, file)
        try
            value = redirect_stdout(stream) do
                redirect_stderr(stream) do
                    run_debug_statements(code, file)
                end
            end
        catch err
            if err isa SqueroDebugger.DebugStopException
                stopped = true
            else
                error_msg = sprint(showerror, err)
            end
        finally
            !isempty(file) && !isempty(SESSION.file_stack) && pop!(SESSION.file_stack)
            SqueroDebugger.finish_session!()
            out_text = try
                close(stream)
                drain_stdout()
            catch
                ""
            end
            rm(log_path; force = true)
            figs = capture_figures(value)
            problems, runs, events = take_queues()
            emit(Dict{String, Any}(
                "event" => "debug.terminated",
                "ok" => error_msg === nothing,
                "stopped" => stopped,
                "error" => error_msg,
                "stdout" => out_text,
                "figures" => figs,
                "problems" => problems,
                "runs" => runs,
                "events" => events,
                "value" => describe(value),
                "text" => shown(value),
            ))
        end
    end
end

function sync_vfs!(request::AbstractDict)
    haskey(request, "files") || return
    raw = request["files"]
    raw isa AbstractDict || return
    empty!(SESSION.vfs)
    for (k, v) in raw
        SESSION.vfs[norm_rel(string(k))] = string(v)
    end
end

function handle(request::AbstractDict)
    op = string(get(request, "op", ""))
    id = get(request, "id", nothing)

    if op == "hello"
        info = Dict{String, Any}(
            "op" => "hello",
            "julia" => string(VERSION),
            "image" => IMAGE,
            "protocol" => PROTOCOL,
            "packages" => PACKAGES,
            "versions" => VERSIONS,
        )
        !isempty(IMAGE_DIGEST) && (info["image_digest"] = IMAGE_DIGEST)
        return reply(info; id = id)
    elseif op == "eval"
        code = string(get(request, "code", ""))
        file = string(get(request, "file", ""))
        sync_vfs!(request)
        SESSION.source = code
        result = evaluate(code; file = file)
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
            payload = Dict{String, Any}(
                "array" => Dict(
                    "rows" => rows, "cols" => cols, "dtype" => "f64",
                    "order" => "col", "bytes" => length(bytes),
                ),
            )
            return reply_frame(payload, bytes; id = id)
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
        # `vector`: a Vector whatever the shape; otherwise 1 × n is a vector too, unless `matrix`.
        vector = get(request, "vector", nothing)
        value = rows == 1 && cols == 1 && vector === nothing ? values[1] :
                vector === true || (vector === nothing && rows == 1) ? collect(values) : reshape(collect(values), rows, cols)
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
    elseif op == "debug.breakpoints"
        file = string(get(request, "file", ""))
        bps = get(request, "breakpoints", Any[])
        SqueroDebugger.set_breakpoints!(file, bps)
        return reply(Dict("value" => nothing); id = id)
    elseif op == "debug.start"
        file = string(get(request, "file", "script.jl"))
        code = string(get(request, "code", ""))
        stop_on_entry = Bool(get(request, "stopOnEntry", false))
        sync_vfs!(request)
        if haskey(request, "breakpoints")
            SqueroDebugger.set_breakpoints!(file, request["breakpoints"])
        end
        start_debug_session!(file, code; stop_on_entry = stop_on_entry)
        return reply(Dict("value" => nothing); id = id)
    elseif op == "debug.continue"
        SqueroDebugger.request_command!(:continue)
        return reply(Dict("value" => nothing); id = id)
    elseif op == "debug.step"
        kind = string(get(request, "kind", "over"))
        cmd = kind == "into" ? :into : kind == "out" ? :out : :over
        SqueroDebugger.request_command!(cmd)
        return reply(Dict("value" => nothing); id = id)
    elseif op == "debug.pause"
        SqueroDebugger.request_command!(:pause)
        return reply(Dict("value" => nothing); id = id)
    elseif op == "debug.stop"
        SqueroDebugger.request_command!(:stop)
        return reply(Dict("value" => nothing); id = id)
    elseif op == "debug.locals"
        frame_id = Int(get(request, "frameId", 0))
        return reply(Dict("value" => serialize_locals(frame_id)); id = id)
    elseif op == "debug.eval"
        frame_id = Int(get(request, "frameId", 0))
        code = string(get(request, "code", ""))
        val = try
            SqueroDebugger.eval_in_frame(frame_id, code)
        catch err
            return fail(sprint(showerror, err); id = id)
        end
        return reply(Dict("value" => describe(val), "text" => shown(val)); id = id)
    elseif op == "doc"
        return reply(Dict("value" => doc_html(string(get(request, "name", "")))); id = id)
    elseif op == "doc.names"
        return reply(Dict("value" => doc_names()); id = id)
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
    while true
        line = try
            eof(stdin) && break
            readline(stdin)
        catch err
            err isa InterruptException && continue  # a Cancel that came after the run ended
            rethrow()
        end
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
