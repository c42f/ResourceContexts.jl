module ResourceContexts

export @context, @!, @defer, enter_do, ResourceContext

abstract type AbstractContext end

using Base.Meta: isexpr

using Logging: Logging, @logmsg

mutable struct ResourceContext <: AbstractContext
    resources::Vector{Any}
    is_detached::Bool
end

function ResourceContext(needs_finalizer::Bool=true)
    c = ResourceContext(Vector{Any}(), false)
    if needs_finalizer
        finalizer(cleanup!, c)
    end
    c
end

cleanup!(x) = close(x)
cleanup!(f::Function) = f()

# This partially recursive arrangement does two things:
# 1. Avoids paying the try/catch setup cost more than once when no exceptions
#    occur.
# 2. Arranges all exceptions on the exception stack, reflecting the cleanup
#    ordering and avoiding the need for CompositeException
function _cleanup!(resources, i)
    try
        while i > 0
            cleanup!(resources[i])
            i -= 1
        end
        i == 0 && empty!(resources)
    catch exc
        _cleanup!(resources, i-1)
        rethrow()
    end
end

function cleanup!(context::ResourceContext, unscope_cleanup_point=true)
    if !context.is_detached || unscope_cleanup_point
        # Clean up resources, last to first.
        _cleanup!(context.resources, length(context.resources))
    end
    nothing
end

"""
    defer(f::Function, `ctx`)

Defer the call to `f` until `ctx` is cleaned up.
"""
function defer(f::Function, ctx::ResourceContext)
    push!(ctx.resources, f)
    nothing
end

# Name of the context variable
const _context_name = :var"#context"

function _current_context_expr(__module__, __source__)
    quote
        if $(Expr(:islocal, esc(_context_name)))
            # Or this Expr(:isdefined)? Really, we'd like
            #   * Strict `:islocal` if inside a function
            #   * `:isdefined` for top level exprs
            $(esc(_context_name))
        else
            # Beautiful hack from Simeon Schaub here:
            # https://github.com/JuliaLang/julia/issues/6733#issuecomment-827441915
            in_function = $(Expr(:isdefined, esc(:var"#self#")))
            global_context($__module__, $(QuoteNode(__source__.file)),
                           $(__source__.line), in_function)
        end
    end
end

"""
    @defer expression

Defers execution of the cleanup `expression` until the exit of the current
`@context` block.
"""
macro defer(ex)
    quote
        ctx = $(_current_context_expr(__module__, __source__))
        defer(()->$(esc(ex)), ctx)
    end
end

"""
    @context begin ... end
    @context function f() ... end

`@context` creates a local context and runs the provided code within that
context. When the code exits, any resources registered with the context will be
cleaned up with `ResourceContexts.cleanup!()`.

When the code is a `function` definition, the context block is inserted around
the function body.
"""
macro context(ex)
    if ex.head == :function
        ex.args[2] = quote
            $(_context_name) = $ResourceContexts.ResourceContext(false)
            try
                $(ex.args[2])
            finally
                $ResourceContexts.cleanup!($(_context_name), false)
            end
        end
        esc(ex)
    else
        quote
            let $(esc(_context_name)) = ResourceContext(false)
                try
                    $(esc(ex))
                finally
                    cleanup!($(esc(_context_name)), false)
                end
            end
        end
    end
end

"""
    @! func(args)

The `@!` macro calls `func(ctx, args)`, where `ctx` is the "current context" as
created by the `@context` macro.  If `@!` is used outside a `@context` block, a
warning is emitted and the global context is used.

---

    @! function my_func(...)
        ...
    end

This form adds a `context::AbstractContext` argument as the first argument to
`my_func`. This allows the responsibility for resource cleanup to be passed
back to the caller by using `@defer` within `my_func` or `@!` to further chain
the resource handling.
"""
macro !(ex)
    if isexpr(ex, :call)
        i = length(ex.args) > 1 && isexpr(ex.args[2], :parameters) ? 3 : 2
        map!(a->esc(a), ex.args, ex.args)
        insert!(ex.args, i, :ctx)
        quote
            ctx = $(_current_context_expr(__module__, __source__))
            $ex
        end
    elseif isexpr(ex, :function)
        # Insert context argument
        callargs = isexpr(ex.args[1], :where) ?
                   ex.args[1].args[1].args : ex.args[1].args
        i = length(callargs) > 1 && isexpr(callargs[2], :parameters) ? 3 : 2
            # handle keywords
        insert!(callargs, i, :($_context_name::$ResourceContexts.AbstractContext))
        esc(ex)
    else
        error("Expected call or function definition as arguments to `@!`")
    end
end

# Global context
function __init__()
    atexit() do
        global_cleanup!()
    end
end

_global_context = ResourceContext(false)

@noinline function global_context(_module, file, line, in_function)
    # Heuristically reduce the log level in interactive usage because sloppy
    # resource management is probably ok there.
    filestr = string(file)
    level = ((_module === Main || startswith(filestr, "REPL")) && !in_function) ?
            Logging.Debug : Logging.Warn
    @logmsg level """Using global `ResourceContext` — use a `@context` block to avoid this message.
             Use `ResourceContexts.global_cleanup!()` to clean up the resource.""" #=
        =# _module=_module _group="context" _file=filestr _line=line
    return _global_context
end

function global_cleanup!()
    cleanup!(_global_context)
    empty!(_global_context.resources)
    nothing
end

#-------------------------------------------------------------------------------
# Utilities for interoperating with context-unaware code.

"""
    @! enter_do(func, args...)

`enter_do` transforms do-block-based resource management into context-based
resource management. That is, if the user is expected to write

```
func(args...) do x,y
    # do stuff with x,y
end
```

they can instead use `func` with a context, as in

```
x,y = @! enter_do(func, args...)
```
"""
@! function enter_do(func::Function, args...; kws...)
    # We need a separate stack to run the do block, so we use a separate task
    # here for that purpose. We know exactly which order the parent and child
    # tasks should run in so we should be able to use explicit yields and not
    # involve the main scheduler.
    parent_task = current_task()
    child_task = @task begin
        # cleanup_caller is the task which triggered yieldto(child_task) in the
        # @defer'd cleanup code further down.
        cleanup_caller::Task = parent_task
        try
            func(args...; kws...) do resources...
                cleanup_caller = yieldto(parent_task, resources)
            end
            # Success path: yield back to whoever triggered the cleanup.
            # `child_task` will never complete, but we've already run whatever
            # cleanup code in `func` so that should be ok.
            yieldto(cleanup_caller, nothing)
        catch
            # Failure path
            yieldto(cleanup_caller, :failed)
            rethrow()
        end
    end
    res = yieldto(child_task)
    if res === :failed
        # There was an exception during setup of the resource. We don't have a
        # value to return so force a TaskFailedException, ensuring that the
        # child task is scheduled so that it can run to completion while we
        # wait.
        schedule(child_task)
        wait(child_task)
    end
    @defer begin
        # Allow child task to free any resources
        #
        # If the user has called detach_context_cleanup(), this code may run in
        # a task other than parent_task and we need to make sure we yield back
        # appropriately.
        res = yieldto(child_task, current_task())
        if res === :failed
            # There was an exception during resource cleanup - report this with
            # a TaskFailedException.
            schedule(child_task)
            wait(child_task)
        end
    end
    return res
end


"""
    @! detach_context_cleanup(x)

Defer the cleanup of `context` to the time at which `x` is finalized by the
garbage collector and return `x`. This transforms context-based resource
handling into finalizer-based resource handling.

For this to work, `x` must be mutable. If `x` is immutable you could consider
making a wrapper type with the same API.

!!! note
    This function is best avoided if possible because it makes any failures during
    context cleanup impossible to handle neatly — instead, they are caught and
    logged asynchronously. However, it's very useful for interacting with
    context-unaware code.

# Examples

Create a temporary directory with two files in it, and return the directory
name as a string.  Cleanup of the directory is associated with finalization of
the string `dir`.

```
dir = @context begin
    dir = @! mktempdir()
    write(joinpath(dir, "file1.txt"), "Some content")
    write(joinpath(dir, "file2.txt"), "Some other content")
    @! ResourceContexts.detach_context_cleanup(dir)
end
```
"""
function detach_context_cleanup(ctx::AbstractContext, x)
    ctx.is_detached = true
    finalizer(x) do _
        # Must be async, as the finalizer itself isn't allowed to task switch
        # and context cleanup may involve several task-switchy things
        @async try
            cleanup!(ctx)
        catch exc
            @error "Error cleaning up context" exception=(exc, catch_backtrace())
            rethrow()
        end
    end
    x
end

#-------------------------------------------------------------------------------
include("base_interop.jl")

end
