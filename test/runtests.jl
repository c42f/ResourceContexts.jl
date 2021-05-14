using Contexts
using Test

# Use of @! to pass context to resource creation function
@! function foo(x, label)
    # Use of @defer inside a resource creation function
    @defer push!(x, label)
end

@! function bar(x; label=nothing)
    @defer push!(x, label)
end

@! function baz(x::T, label) where {T}
    @defer push!(x, label)
end

@testset "Cleanup ordering" begin
    cleanups = []
    @context begin
        @defer push!(cleanups, :A)
        @! foo(cleanups, :B)
        @! bar(cleanups; label=:C)
        @! baz(cleanups, :D)
        @test cleanups == []
    end
    @test cleanups == [:D, :C, :B, :A]
end

@testset "Exceptions during cleanup" begin
    try
        @context begin
            @defer error("A")
            @defer error("B")
        end
    catch exc
        stack = Base.catch_stack()
        @test stack[1][1] == ErrorException("B")
        @test stack[2][1] == ErrorException("A")
    end
end

@testset "enter_do — context management for `do` blocks" begin
    function invoke_user_func(f)
        fake_resource = 42
        f(fake_resource)
    end

    function fail_before_user_func(f)
        error("Oops1")
        f()
    end
    function fail_after_user_func(f)
        f()
        error("Oops2")
    end

    @context begin
        @test @!(enter_do(invoke_user_func)) == (42,)
    end

    @test try
        @context begin
            @! enter_do(fail_before_user_func)
        end
    catch e
        @test e isa TaskFailedException
        first(Base.catch_stack(e.task))[1]
    end == ErrorException("Oops1")

    @test try
        @context begin
            @! enter_do(fail_after_user_func)
        end
    catch e
        @test e isa TaskFailedException
        first(Base.catch_stack(e.task))[1]
    end == ErrorException("Oops2")
end

include("base_interop.jl")
