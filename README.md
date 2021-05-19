# ResourceContexts.jl

[![Build Status](https://github.com/c42f/ResourceContexts.jl/workflows/CI/badge.svg)](https://github.com/c42f/ResourceContexts.jl/actions)

`ResourceContexts` is an experimental Julia package for **composable resource
management** without `do` blocks.

Resources are objects which need cleanup code to run to finalize their state.
For example,
* Open file handles
* Temporary files and directories
* Background `Task`s
* Many other things which are currently handled with `do`-blocks.

The `@!` macro calls or defines "context functions" — functions which take an
`AbstractContext` as the first argument and associate any resources with that
context. This package provides context-based overrides for `Base` functions
`open`, `mktemp`, `mktempdir`, `cd`, `run`, `lock` and
`redirect_{stdout,stderr,stdin}`.

The `@context` macro associates a context with the current code block which
will be passed to any context functions invoked with `@!`. When a `@context`
block exits the cleanup code associated with the context runs.

The `@defer` macro defers an arbitrary cleanup expression to the end of the
current `@context`.

## Examples

### Manging resources without do blocks

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

Start ten external processes and wait for all of them to finish before
continuing

```julia
@context begin
    for i=1:10
        @! run(`sleep $(rand(2))`)
    end
end
```

### Functions which pass resources back to their callers

Functions called as `@! foo(args...)` are passed the current context in the
first argument; `foo(current_context, args...)` is called.  When `foo` is
*defined* using `@!`, the context will automatically defer resource cleanup to
the caller when using `@defer`. For example:

Returning a bare `Ptr` to a temporary buffer:

```julia
@! function raw_buffer(len)
    buf = Vector{UInt8}(undef, len)
    @defer GC.@preserve buf nothing
    pointer(buf)
end

@context begin
    len = 1_000_000_000
    ptr = @! raw_buffer(len)
    GC.gc() # `buf` is preserved regardless of this call to gc()
    unsafe_store!(ptr, 0xff)
end
```

Defer zeroing of a secret buffer to the caller

```julia
@! function create_secret()
    buf = Base.SecretBuffer()
    write(buf, rand(UInt64)) # super secret ?
    seek(buf, 0)
    @defer Base.shred!(buf)
    buf
end

@context begin
    buf = @! create_secret()
    @info "Secret first byte" read(buf, 1)
end
# buf has been `shred!`ed at this point
```

### Interop with "do-block-based" resource management

This is available with the `enter_do` function, which can "steal" the state
from inside the do block and make it available in a `@context` block, or in the
REPL:

```julia
function resource_func(f::Function, arg)
    @info "Setting up resources"
    fake_resource = 40
    f(fake_resource + arg)
    @info "Tear down resources"
end

# Normal usage
resource_func(2) do x
    @info "Resource ready" x
end

# Safely access the resource in the REPL
x = @! enter_do(resource_func, 2)
```

### Interop with finalizer-based resource management

The special function `@! detach_context_cleanup(x)` can be used to detach
context cleanup from the current `@context` block and associate it with the
finalization of `x` instead. That is, it turns *lexical* resource management
into *dynamic* resource management.

For example, to create a temporary directory with two files in it, return
the directory name as a string and only clean up the directory when `dir` is
finalized:

```
dir = @context begin
    dir = @! mktempdir()
    write(joinpath(dir, "file1.txt"), "Some content")
    write(joinpath(dir, "file2.txt"), "Some other content")
    @! ResourceContexts.detach_context_cleanup(dir)
end
```

# Design

The standard solution for Julian resource management is still the `do` block,
but this has some severe ergonomic disadvantages:
* It's extremely inconvenient at the REPL; you cannot work with the
  intermediate open resources without entering the context of the `do` block.
* It creates highly nested code when many resources are present. This is both
  visually confusing and the excess nesting leads to very deep stack traces.
* Custom cleanup code is separated from the resource creation in a `finally`
  block.

The ergonomic factors mean that people often prefer the non-scoped form as
argued [here](https://github.com/JuliaLang/julia/issues/7721#issuecomment-171345256).
However this also suffers some severe disadantages:
* Resources leak (or must be finalized by the GC) when people forget to guard
  resource cleanup with a `try ... finally`.
* Finalizers run in a restricted environment where any errors occur outside the
  original context where the resource was created. This makes for *unstructured
  error handling* where it's impossible to propagate errors in a natural way.
* Functions which return objects must keep the backing resources alive by
  holding references to them somewhere. There's two ways to do this:
  - Have the returned object hold a reference to each resource. This is bad
    for the implementer because it reduces composability: one cannot combine
    any desired return type with arbitrary backing resources.
  - Have multiple returns such as `(object,resource)`. This is unnatural
    because it forces the user to unpack return values.

## The solution

This package uses the macro `@!` as a proxy for the [proposed postfix `!`
syntax](https://github.com/JuliaLang/julia/issues/7721#issuecomment-170942938)
and adds some new ideas:

**The user should not be able to "forget the `!`"**. We prevent this by
introducing a new *context calling convention* for resource creation functions
where the current `AbstractContext` is passed as the first argument. The
`@context` macro creates a new context in lexical scope and the `@!` macro is
syntactic sugar for calling with the current context.

**Resource creation functions should be able to *compose* any desired object
return type with arbitrary resources**. This preserves the [composability of
the `do` block form](https://github.com/JuliaLang/julia/issues/7721#issuecomment-719152859)
by rejecting the conflation of the returned object and its backing resources.
This is a break with some familiar APIs such as the standard file handles
returned by `open(filename)` which are both a stream interface and a resource
in need of cleanup.

## Possible language integration

What would all this look like as a language feature?

* `@!` could be replaced with a postfix `!` as proposed way back in 2015 or so.
* `defer` might become a keyword so that it can have special behavior such as
  ignoring its return value. In a similar way to the code which runs inside
  `finally`, there's no sense in having a "value returned by" `defer`. In
  particular, I've observed that it frequently leads to the introduction of
  temporary variables simply to transfer the result of the expression occurring
  prior to the `defer` line.
* `@context` would be implicit at function boundaries, global `let` blocks, and
  potentially other scopes within functions. Getting this part correct is
  still a tricky design problem. For example, looping constructs should
  introduce an implicit context, but how then can the user disable this in
  particular cases?

Using the example from above, we've got

```julia
function create_secret()!
    buf = Base.SecretBuffer()
    write(buf, rand(UInt64)) # super secret ?
    seek(buf, 0)
    defer Base.shred!(buf)
end

let
    buf = create_secret()!
    @info "Secret first byte" read(buf, 1)
end # <- `buf` shredded here
```

One might be concerned that this definition of `create_secret()` hides the
calling convention and that explicitly annotating the passed context might be
more transparent. In that case we could go with syntax more like the existing
macro annotations such as `@nospecialize` which attach metadata to function
arguments. For example,

```julia
function create_secret(@passcontext(ctx::AbstractContext))
    buf = Base.SecretBuffer()
    write(buf, rand(UInt64)) # super secret ?
    seek(buf, 0)
    defer Base.shred!(buf)
end
```

## References

* Resource cleanup with `defer` and `!` syntax
  - [The postfix `!` syntax](https://github.com/JuliaLang/julia/issues/7721#issuecomment-170942938)
  - [`close` as a possible default for cleanup](https://github.com/JuliaLang/julia/issues/7721#issuecomment-171004109)
  - [The `@!` macro proxy syntax for `!`](https://github.com/JuliaLang/julia/issues/7721#issuecomment-277142281)
* The benefits and drawbacks of `do` syntax
  - [The ergonomic problems of `do`](https://github.com/JuliaLang/julia/issues/7721#issuecomment-171345256)
  - [Some composability benefits of `do`](https://github.com/JuliaLang/julia/issues/7721#issuecomment-719152859)
* Finalizers were discussed at length in https://github.com/JuliaLang/julia/issues/11207
* A previous prototype, [Defer.jl](https://github.com/adambrewster/Defer.jl)
  used similar macro-based syntax.
* Structured concurrency and the cancellation problem is closely related
  https://github.com/JuliaLang/julia/issues/33248 when viewing `@async` tasks
  as a type of resource and the task nursury as the context.

