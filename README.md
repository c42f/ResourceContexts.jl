# Contexts

[![Build Status](https://github.com/c42f/Contexts.jl/workflows/CI/badge.svg)](https://github.com/c42f/Contexts.jl/actions)

`Contexts` is an experimental Julia package for deferred resource cleanup
without `do` blocks.

Resources are things like
* Open file handles
* Temporary files and directories
* Many other things which are currently handled with `do`-blocks.

The `@!` macro calls a function and associates any resources created inside it
with the "current context" as created by the `@context` macro. When a
`@context` block exits, all cleanup code associated with the registered
resources is run immediately.

The `@defer` macro defers an arbitrary cleanup expression to the end of the
current `@context`.

## Examples

Open a file, read all the lines and close it again

```julia
function f()
    @context readlines(@!(open("tmp/hi.txt", "r")))
end
```

Create a temporary file and ensure it's cleaned up afterward

```julia
@context function f()
    path, io = @! mktemp()
    write(io, "content")
    flush(io)
    @info "mktemp output" path ispath(path) isopen(io) read(path, String)
end
```

Defer shredding of a secretbuffer until scope exit

```julia
@context function f()
    buf = SecretBuffer()
    @defer shred!(buf)
    secret_computation(buf)
end
```

Acquire a pair of locks (and release them in the opposite order)

```julia
function f()
    lk1 = ReentrantLock()
    lk2 = ReentrantLock()
    @context begin
        @! lock(lk1)
        @! lock(lk2)
        @info "Hi from locked section" islocked(lk1) islocked(lk2)
    end
    @info "Outside locked section" islocked(lk1) islocked(lk2)
end
```

## Design

There's been plenty of prior discussion about how to clean up resources in a
timely and convenient fashion, including:

* Resource cleanup with `defer` and `!` syntax https://github.com/JuliaLang/julia/issues/7721
* The woes of finalizers https://github.com/JuliaLang/julia/issues/11207
* A previous prototype, Defer.jl, used similar syntax to Contexts.jl
  https://github.com/adambrewster/Defer.jl
* Structured concurrency and the cancellation problem is closely related
  https://github.com/JuliaLang/julia/issues/33248 because `@async` tasks are a
  type of resource.

The standard solution is still the `do` block, but this has some disadvantages:
* It's extremely inconvenient at the REPL; you cannot work with the
  intermediate open resources without entering the context of the `do` block.
* It creates highly nested code when many resources are present. This is both
  visually confusing and the excess nesting leads to very deep stack traces.
* Custom cleanup code is separated from the resource creation in a `finally`
  block.

This package tries to synthesize some of these ideas, while also taking
seriously the idea that *resources may be required to maintain objects, but may
have separate identities (and APIs) from those objects*. For example, consider
a file within a temporary cache directory. The file is the object of interest
to the user, but the directory is the resource which needs to be cleaned up.

In general an object and its backing resources should not be conflated. This is
because one wants the freedom to deal in existing concrete types in the bulk of
the code, ignoring the fact that they might be backed by varying resources in
different cicumstances. This is a break with some familiar APIs such as the
standard file handles returned by `open()` which are both a stream interface
and a resource which needs `close()`ing.

