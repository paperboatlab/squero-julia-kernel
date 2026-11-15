# Source-level AST debugger for squero-kernel/0.
#
# Instruments user-defined functions, loops, and top-level blocks in the session module with
# lightweight hooks (`enter!`, `exit!`, `check!`) so native Julia semantics, broadcasting,
# closures, packages, and SqueroPlot calls run at full speed while supporting breakpoints,
# conditional breakpoints, stepping (over / into / out), call-stack frames, and frame-scoped eval.

module SqueroDebugger

using JSON3

struct DebugStopException <: Exception end

struct Breakpoint
    line::Int
    enabled::Bool
    condition::String
end

mutable struct Frame
    id::Int
    name::String
    file::String
    line::Int
    locals_fn::Function
    locals_cache::Vector{Pair{Symbol, Any}}
end

mutable struct State
    active::Bool
    paused::Bool
    mode::Symbol            # :continue, :over, :into, :out
    target_depth::Int
    pause_requested::Bool
    stop_requested::Bool
    file::String
    breakpoints::Dict{String, Vector{Breakpoint}}
    active_lines::Set{Int}  # fast path for current file
    frames::Vector{Frame}
    next_frame_id::Int
    cmd_ch::Channel{Symbol}
    check_ticks::Int
    mod::Module
    on_pause::Function
    on_resume::Function
end

const STATE = State(
    false,
    false,
    :continue,
    0,
    false,
    false,
    "",
    Dict{String, Vector{Breakpoint}}(),
    Set{Int}(),
    Frame[],
    1,
    Channel{Symbol}(8),
    0,
    Main,
    (args...) -> nothing,
    () -> nothing,
)

const STATE_LOCK = ReentrantLock()

"""Normalize a workspace filename so `"plots/lorenz.jl"` and `"lorenz.jl"` match cleanly."""
norm_file(f::AbstractString) = replace(String(f), '\\' => '/')

function refresh_active_lines!()
    empty!(STATE.active_lines)
    for list in values(STATE.breakpoints)
        for bp in list
            bp.enabled && push!(STATE.active_lines, bp.line)
        end
    end
end

function set_breakpoints!(file::AbstractString, list)
    key = norm_file(file)
    parsed = Breakpoint[]
    for item in list
        line = Int(get(item, "line", 0))
        line > 0 || continue
        enabled = Bool(get(item, "enabled", true))
        cond = strip(String(get(item, "condition", "")))
        push!(parsed, Breakpoint(line, enabled, cond))
    end
    lock(STATE_LOCK) do
        STATE.breakpoints[key] = parsed
        refresh_active_lines!()
    end
    parsed
end

function matching_breakpoint(file::AbstractString, line::Int)
    key = norm_file(file)
    base = basename(key)
    bps = get(STATE.breakpoints, key, nothing)
    if bps === nothing
        for (k, list) in STATE.breakpoints
            if basename(k) == base
                bps = list
                break
            end
        end
    end
    bps === nothing && return nothing
    for bp in bps
        if bp.enabled && bp.line == line
            return bp
        end
    end
    nothing
end

function reset_session!(mod::Module, file::AbstractString; stop_on_entry::Bool = false, on_pause = (args...) -> nothing, on_resume = () -> nothing)
    lock(STATE_LOCK) do
        while isready(STATE.cmd_ch)
            take!(STATE.cmd_ch)
        end
        STATE.active = true
        STATE.paused = false
        STATE.mode = stop_on_entry ? :into : :continue
        STATE.target_depth = 0
        STATE.pause_requested = false
        STATE.stop_requested = false
        STATE.file = norm_file(file)
        STATE.frames = Frame[]
        STATE.next_frame_id = 1
        STATE.check_ticks = 0
        STATE.mod = mod
        STATE.on_pause = on_pause
        STATE.on_resume = on_resume
        refresh_active_lines!()
    end
end

function finish_session!()
    lock(STATE_LOCK) do
        STATE.active = false
        STATE.paused = false
        STATE.pause_requested = false
        STATE.stop_requested = false
        empty!(STATE.frames)
    end
end

function request_command!(cmd::Symbol)
    if cmd === :stop
        STATE.stop_requested = true
    elseif cmd === :pause
        STATE.pause_requested = true
        return
    end
    STATE.paused && put!(STATE.cmd_ch, cmd)
end

# ---- AST analysis & instrumentation ---------------------------------------------------------

function is_fn_sig(ex)
    ex isa Expr || return false
    ex.head === :call && return true
    ex.head === :where && return is_fn_sig(ex.args[1])
    ex.head === :(::) && return is_fn_sig(ex.args[1])
    false
end

function extract_lhs_symbols!(syms::Set{Symbol}, ex)
    if ex isa Symbol
        ex === :_ || push!(syms, ex)
        return
    end
    ex isa Expr || return
    if ex.head in (:(::), :kw, :(...), :local)
        length(ex.args) >= 1 && extract_lhs_symbols!(syms, ex.args[1])
    elseif ex.head in (:tuple, :parameters, :vect)
        for a in ex.args
            extract_lhs_symbols!(syms, a)
        end
    end
end

function extract_fn_params!(syms::Set{Symbol}, sig)
    sig isa Expr || return
    if sig.head === :call
        for i in 2:length(sig.args)
            arg = sig.args[i]
            if arg isa Expr && arg.head === :parameters
                for kw in arg.args
                    extract_lhs_symbols!(syms, kw)
                end
            else
                extract_lhs_symbols!(syms, arg)
            end
        end
    elseif sig.head === :where || sig.head === :(::)
        extract_fn_params!(syms, sig.args[1])
    elseif sig.head === :tuple
        for a in sig.args
            extract_lhs_symbols!(syms, a)
        end
    end
end

function extract_for_vars!(syms::Set{Symbol}, head)
    head isa Expr || return
    if head.head in (:(=), :in, :∈)
        length(head.args) >= 1 && extract_lhs_symbols!(syms, head.args[1])
    elseif head.head === :block
        for a in head.args
            extract_for_vars!(syms, a)
        end
    end
end

const COMPOUND_ASSIGN = Set([:+=, :-=, :*=, :/=, :\=, :^=, :%=, :÷=, :&=, :|=, :⊻=, :>>>=, :>>=, :<<=])

"""Collect local variable symbols assigned inside `ex` without descending into nested functions."""
function collect_locals!(syms::Set{Symbol}, ex)
    ex isa Expr || return
    ex.head in (:function, :->, :struct, :quote, :macro, :module, :global) && return
    if ex.head === :(=) && length(ex.args) >= 2
        is_fn_sig(ex.args[1]) && return
        extract_lhs_symbols!(syms, ex.args[1])
        collect_locals!(syms, ex.args[2])
        return
    elseif ex.head in COMPOUND_ASSIGN && length(ex.args) >= 2
        ex.args[1] isa Symbol && push!(syms, ex.args[1])
        collect_locals!(syms, ex.args[2])
        return
    elseif ex.head === :local
        for a in ex.args
            if a isa Expr && a.head === :(=)
                extract_lhs_symbols!(syms, a.args[1])
                collect_locals!(syms, a.args[2])
            else
                extract_lhs_symbols!(syms, a)
            end
        end
        return
    elseif ex.head === :for && length(ex.args) >= 2
        extract_for_vars!(syms, ex.args[1])
        collect_locals!(syms, ex.args[2])
        return
    elseif ex.head === :let && length(ex.args) >= 2
        binds = ex.args[1]
        if binds isa Expr && binds.head === :block
            for b in binds.args
                b isa Expr && b.head === :(=) && extract_lhs_symbols!(syms, b.args[1])
            end
        elseif binds isa Expr && binds.head === :(=)
            extract_lhs_symbols!(syms, binds.args[1])
        end
        collect_locals!(syms, ex.args[2])
        return
    elseif ex.head === :try
        length(ex.args) >= 2 && ex.args[2] isa Symbol && push!(syms, ex.args[2])
    end
    for a in ex.args
        collect_locals!(syms, a)
    end
end

function make_locals_fn(syms::Vector{Symbol})
    if isempty(syms)
        return :(() -> Pair{Symbol, Any}[])
    end
    checks = Any[]
    for s in sort!(copy(syms))
        push!(checks, :(@isdefined($s) && push!(__dbg_l, $(QuoteNode(s)) => $s)))
    end
    Expr(:(->), Expr(:tuple), Expr(:block, :(__dbg_l = Pair{Symbol, Any}[]), checks..., :__dbg_l))
end

function fn_name_of(sig)
    sig isa Symbol && return string(sig)
    sig isa Expr || return "<anon>"
    if sig.head === :call && length(sig.args) >= 1
        return string(sig.args[1])
    elseif sig.head === :where || sig.head === :(::)
        return fn_name_of(sig.args[1])
    end
    "<fn>"
end

"""Instrument an expression AST for debugging while preserving Julia evaluation order and return values."""
function instrument(ex, file::String, cur_line::Int, outer_locals::Set{Symbol})
    ex isa Expr || return ex
    head = ex.head

    # Never rewrite type definitions, quotes, or macro definitions
    head in (:struct, :abstract, :primitive, :quote, :macro, :module, :using, :import, :export) && return ex

    # Function definitions: `function f(x) ... end` or `f(x) = ...`
    if head === :function && length(ex.args) >= 2
        sig = ex.args[1]
        body = ex.args[2]
        fn_locals = copy(outer_locals)
        extract_fn_params!(fn_locals, sig)
        collect_locals!(fn_locals, body)
        lfn = make_locals_fn(collect(fn_locals))
        ibody = instrument(body, file, cur_line, fn_locals)
        fname = fn_name_of(sig)
        wrapped = Expr(:block,
            Expr(:call, GlobalRef(SqueroDebugger, :enter!), fname, file, cur_line, lfn),
            Expr(:try, ibody, false, false, Expr(:call, GlobalRef(SqueroDebugger, :exit!))),
        )
        return Expr(:function, sig, wrapped)
    elseif head === :(=) && length(ex.args) >= 2 && is_fn_sig(ex.args[1])
        sig = ex.args[1]
        body = ex.args[2]
        fn_locals = copy(outer_locals)
        extract_fn_params!(fn_locals, sig)
        collect_locals!(fn_locals, body)
        lfn = make_locals_fn(collect(fn_locals))
        ibody = instrument(body, file, cur_line, fn_locals)
        fname = fn_name_of(sig)
        wrapped = Expr(:block,
            Expr(:call, GlobalRef(SqueroDebugger, :enter!), fname, file, cur_line, lfn),
            Expr(:try, ibody, false, false, Expr(:call, GlobalRef(SqueroDebugger, :exit!))),
        )
        return Expr(:(=), sig, wrapped)
    elseif head === :-> && length(ex.args) >= 2
        sig = ex.args[1]
        body = ex.args[2]
        fn_locals = copy(outer_locals)
        if sig isa Symbol
            push!(fn_locals, sig)
        else
            extract_fn_params!(fn_locals, sig)
        end
        collect_locals!(fn_locals, body)
        lfn = make_locals_fn(collect(fn_locals))
        ibody = instrument(body, file, cur_line, fn_locals)
        wrapped = Expr(:block,
            Expr(:call, GlobalRef(SqueroDebugger, :enter!), "<lambda>", file, cur_line, lfn),
            Expr(:try, ibody, false, false, Expr(:call, GlobalRef(SqueroDebugger, :exit!))),
        )
        return Expr(:->, sig, wrapped)
    elseif head === :for && length(ex.args) >= 2
        loop_locals = copy(outer_locals)
        extract_for_vars!(loop_locals, ex.args[1])
        collect_locals!(loop_locals, ex.args[2])
        ibody = instrument(ex.args[2], file, cur_line, loop_locals)
        return Expr(:for, ex.args[1], ibody)
    elseif head === :while && length(ex.args) >= 2
        loop_locals = copy(outer_locals)
        collect_locals!(loop_locals, ex.args[2])
        ibody = instrument(ex.args[2], file, cur_line, loop_locals)
        return Expr(:while, ex.args[1], ibody)
    elseif head === :let && length(ex.args) >= 2
        let_locals = copy(outer_locals)
        collect_locals!(let_locals, ex)
        ibody = instrument(ex.args[2], file, cur_line, let_locals)
        return Expr(:let, ex.args[1], ibody)
    elseif head === :block
        out = Any[]
        ln = cur_line
        lfn_expr = isempty(outer_locals) ? :(() -> Pair{Symbol, Any}[]) : make_locals_fn(collect(outer_locals))
        for arg in ex.args
            if arg isa LineNumberNode
                ln = arg.line
                push!(out, arg)
            else
                # Skip hooks before pure type/module/macro definitions
                if !(arg isa Expr && arg.head in (:struct, :abstract, :primitive, :macro, :module))
                    push!(out, Expr(:call, GlobalRef(SqueroDebugger, :check!), ln, file, lfn_expr))
                end
                push!(out, instrument(arg, file, ln, outer_locals))
            end
        end
        return Expr(:block, out...)
    elseif head === :if || head === :elseif
        args = Any[ex.args[1]]
        for i in 2:length(ex.args)
            push!(args, instrument(ex.args[i], file, cur_line, outer_locals))
        end
        return Expr(head, args...)
    elseif head === :try
        args = Any[]
        for (i, a) in enumerate(ex.args)
            if i == 3 && a isa Expr
                catch_locals = copy(outer_locals)
                ex.args[2] isa Symbol && push!(catch_locals, ex.args[2])
                push!(args, instrument(a, file, cur_line, catch_locals))
            elseif a isa Expr
                push!(args, instrument(a, file, cur_line, outer_locals))
            else
                push!(args, a)
            end
        end
        return Expr(:try, args...)
    end

    # Recurse into call arguments (`do` blocks, nested closures, etc.) while keeping expression intact
    new_args = Any[instrument(a, file, cur_line, outer_locals) for a in ex.args]
    Expr(head, new_args...)
end

# ---- Runtime hooks --------------------------------------------------------------------------

function enter!(name::String, file::String, line::Int, locals_fn::Function)
    id = STATE.next_frame_id
    STATE.next_frame_id += 1
    push!(STATE.frames, Frame(id, name, file, line, locals_fn, Pair{Symbol, Any}[]))
    nothing
end

function exit!()
    isempty(STATE.frames) || pop!(STATE.frames)
    nothing
end

"""Evaluate a Julia expression inside a specific frame's captured locals + `STATE.mod`."""
function eval_in_locals(locals::Vector{Pair{Symbol, Any}}, code::AbstractString)
    ex = Meta.parse(strip(code); raise = true)
    if isempty(locals)
        return Core.eval(STATE.mod, ex)
    end
    binds = Any[Expr(:(=), k, QuoteNode(v)) for (k, v) in locals]
    let_ex = Expr(:let, Expr(:block, binds...), ex)
    Core.eval(STATE.mod, let_ex)
end

function eval_in_frame(frame_id::Int, code::AbstractString)
    idx = findfirst(f -> f.id == frame_id, STATE.frames)
    locals = idx === nothing ? Pair{Symbol, Any}[] : STATE.frames[idx].locals_cache
    eval_in_locals(locals, code)
end

function frame_locals(frame_id::Int)
    idx = findfirst(f -> f.id == frame_id, STATE.frames)
    idx === nothing && return Pair{Symbol, Any}[]
    f = STATE.frames[idx]
    !isempty(f.locals_cache) && return f.locals_cache
    try
        return f.locals_fn()
    catch
        return Pair{Symbol, Any}[]
    end
end

function check!(line::Int, file::String, locals_fn::Function)
    STATE.active || return nothing
    STATE.stop_requested && throw(DebugStopException())

    # Periodically yield so the stdin reader task can deliver pause/stop/breakpoint commands mid-loop.
    STATE.check_ticks += 1
    if (STATE.check_ticks & 0xff) == 0
        yield()
        STATE.stop_requested && throw(DebugStopException())
    end

    depth = length(STATE.frames)
    reason = ""
    if STATE.pause_requested
        STATE.pause_requested = false
        reason = "pause"
    elseif STATE.mode === :into
        reason = "step"
    elseif STATE.mode === :over && depth <= STATE.target_depth
        reason = "step"
    elseif STATE.mode === :out && depth <= STATE.target_depth
        reason = "step"
    elseif line in STATE.active_lines
        bp = matching_breakpoint(file, line)
        if bp !== nothing
            if isempty(bp.condition)
                reason = "breakpoint"
            else
                locals = locals_fn()
                ok = try
                    Bool(eval_in_locals(locals, bp.condition))
                catch
                    false
                end
                ok && (reason = "breakpoint")
            end
        end
    end

    isempty(reason) && return nothing

    # Update top frame's line and snapshot locals for every active frame in the stack.
    if !isempty(STATE.frames)
        STATE.frames[end].line = line
        STATE.frames[end].locals_fn = locals_fn
    end
    for f in STATE.frames
        f.locals_cache = try
            f.locals_fn()
        catch
            Pair{Symbol, Any}[]
        end
    end

    STATE.paused = true
    try
        STATE.on_pause(reason, file, line, STATE.frames)
        cmd = take!(STATE.cmd_ch)
        if cmd === :stop
            STATE.stop_requested = true
            throw(DebugStopException())
        elseif cmd === :over
            STATE.mode = :over
            STATE.target_depth = depth
        elseif cmd === :into
            STATE.mode = :into
            STATE.target_depth = depth
        elseif cmd === :out
            STATE.mode = :out
            STATE.target_depth = max(0, depth - 1)
        else
            STATE.mode = :continue
        end
    finally
        STATE.paused = false
        for f in STATE.frames
            empty!(f.locals_cache)
        end
    end
    STATE.on_resume()
    nothing
end

end # module SqueroDebugger
