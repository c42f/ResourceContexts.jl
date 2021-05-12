# Contexts.jl

[![Build Status](https://github.com/c42f/Contexts.jl/workflows/CI/badge.svg)](https://github.com/c42f/Contexts.jl/actions)

`Contexts` is an experimental Julia package for **composable resource
management** without `do` blocks.

Resources are objects which need cleanup code to run to finalize their state.
For example,
* Open file handles
* Temporary files and directories
* Background `Task`s for managing IO
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

Interoperability with "do-block-based" resource management is available with
the `enter_do` function:

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

# Context-based form
@context begin
    x = @! enter_do(resource_func, 2)
    @info "Resource ready" x
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

