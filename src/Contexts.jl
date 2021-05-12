module Contexts

export @context, @!, @defer, AbstractContext

abstract type AbstractContext end

struct Context <: AbstractContext
    resources
end

Context() = Context([])

cleanup!(x) = close(x)
cleanup!(f::Function) = f()

# This recursive arrangement does two things:
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
    catch exc
        _cleanup!(resources, i-1)
        rethrow()
    end
end

function cleanup!(context::Context)
    # Clean up resources last to first.
    _cleanup!(context.resources, length(context.resources))
end

function defer(f::Function, ctx::Context)
    push!(ctx.resources, f)
    nothing
end

"""
    @defer expression
    @defer context expression

Defers execution of the cleanup `expression` until the exit of the current
`@context` block, or the cleanup of the explicitly provided `context`.
"""
macro defer(ex)
    quote
        ctx = $(Expr(:islocal, esc(_context_name))) ?
            $(esc(_context_name)) : global_context($__module__, $(__source__.line), $(QuoteNode(__source__.file)))
        defer(()->$(esc(ex)), ctx)
    end
end

macro defer(ctx, ex)
    quote
        defer(()->$(esc(ex)), $(esc(ctx)))
    end
end

"""
    @context begin ... end
    @context function f() ... end

`@context` creates a local context and runs the provided code within that
context. When the code exits, any resources registered with the context will be
cleaned up with `Contexts.cleanup!()`.

When the code is a `function` definition, the context block is inserted around
the function body.
"""
macro context(ex)
    if ex.head == :function
        ex.args[2] = quote
            try
                $(_context_name) = $Contexts.Context()
                $(ex.args[2])
            finally
                $Contexts.cleanup!($(_context_name))
            end
        end
        esc(ex)
    else
        quote
            let $(esc(_context_name)) = Context()
                try
                    $(esc(ex))
                finally
                    cleanup!($(esc(_context_name)))
                end
            end
        end
    end
end

"""
    @! func(args)

The `@!` macro calls `func(ctx, args)`, where `ctx` is the "current context" as
created by the `@context` macro.

If `@!` is used outside a `@context` block, a warning is emitted and the global
context is used.
"""
macro !(ex)
    @assert ex.head == :call
    map!(a->esc(a), ex.args, ex.args)
    insert!(ex.args, 2, :ctx)
    quote
        ctx = $(Expr(:islocal, esc(_context_name))) ?
            $(esc(_context_name)) : global_context($__module__, $(__source__.line), $(QuoteNode(__source__.file)))
        $ex
    end
end

#-------------------------------------------------------------------------------
# Global context
function __init__()
    atexit() do
        global_cleanup!()
    end
end

_context_name = :var"#context"

_global_context = Context()

@noinline function global_context(_module, file, line)
    @warn """Using global `Context` — use a `@context` block to avoid this warning.
             Use `Contexts.global_cleanup!()` to clean up the resource.""" #=
        =# _module=_module _group="context" _file=file _line=line
    _global_context
end

function global_cleanup!()
    cleanup!(_global_context)
    empty!(_global_context.resources)
    nothing
end

include("base_interop.jl")

end
