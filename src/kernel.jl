# squero-kernel/0 — the Julia session behind Squero Studio MX.
#
# The launcher starts this file (normally in a container) and speaks JSON lines on stdin/stdout.
# A matrix reply is a JSON line followed by its raw Float64 frame (column-major). Nothing here
# draws or integrates: plotting and simulation belong to Paperboat.

using JSON3
using LinearAlgebra
using SparseArrays
using Statistics

const PROTOCOL = 0
const PACKAGES = ["JSON3", "LinearAlgebra", "SparseArrays", "Statistics"]
const IMAGE = get(ENV, "SQUERO_KERNEL_IMAGE", "squero-julia-kernel:$(VERSION)-r1")

"""A fresh module is the session: `reset` and `clear` get a new one, as a new REPL would."""
function fresh_module()
    mod = Module(gensym(:SqueroSession))
    Core.eval(mod, :(using LinearAlgebra, SparseArrays, Statistics))
    mod
end

mutable struct Session
    mod::Module
    source::String
end

const SESSION = Session(fresh_module(), "")

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
            for x in Iterators.take(Iterators.flatten(value isa AbstractVector ? (value,) : value), 5)
                push!(preview, Float64(x))
            end
        end
        return Dict(
            "type" => kind,
            "shape" => shape,
            "preview" => preview,
            "runnable" => element <: Number,
        )
    else
        return Dict("type" => string(typeof(value)), "shape" => "—")
    end
end

"""`whos`: numeric session bindings, with the handful of values the workspace cards show."""
function whois()
    out = Any[]
    for name in names(SESSION.mod; all = true, imported = false)
        text = string(name)
        startswith(text, "#") && continue
        text in ("Base", "Core", "LinearAlgebra", "SparseArrays", "Statistics", "Main") && continue
        isdefined(SESSION.mod, name) || continue
        value = getfield(SESSION.mod, name)
        if value isa Function || value isa Module || value isa Type
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
                Core.eval(SESSION.mod, Meta.parseall(code))
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
        ))
    elseif op == "eval"
        code = string(get(request, "code", ""))
        SESSION.source = code
        result = evaluate(code)
        if result.error !== nothing
            return reply(Dict("ok" => false, "error" => result.error, "stdout" => result.stdout); id = id)
        end
        return reply(Dict("value" => describe(result.value), "stdout" => result.stdout); id = id)
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
        SESSION.mod = fresh_module()
        result = evaluate(prefix)
        variables = result.error === nothing ? whois() : Any[]
        SESSION.mod = saved
        return reply(Dict(
            "value" => variables,
            "error" => result.error,
        ); id = id)
    elseif op == "chart"
        return reply(Dict("value" => nothing, "note" => "chart specs land with the shared plot registry"))
    elseif op == "reset"
        SESSION.mod = fresh_module()
        SESSION.source = ""
        return reply(Dict("value" => nothing))
    elseif op == "shutdown"
        reply(Dict("value" => nothing))
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
