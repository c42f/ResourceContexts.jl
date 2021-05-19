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

@testset "detach_context_cleanup" begin
    did_cleanup = false
    @noinline function use_context_and_detach()
        some_value = @context begin
            @defer did_cleanup = true
            @defer begin
                yield()  # Task switching during cleanup should be ok
            end
            @! Contexts.detach_context_cleanup([1,2])
        end
        x = copy(some_value)  # prevent holding some_value live
        @test x == [1,2]
        @test !did_cleanup
    end
    use_context_and_detach()
    @test !did_cleanup
    GC.gc()
    # These yields are required because
    yield() # 1) The cleanup is run async within the finalizer
    yield() # 2) The cleanup calls yield() to assert task switching is ok
    @test did_cleanup
end

@testset "Cleanup robustness" begin
    cleanup_count = 0
    ctx = Contexts.Context()
    Contexts.defer(ctx) do
        cleanup_count += 1
    end
    Contexts.cleanup!(ctx)
    Contexts.cleanup!(ctx)
    @test cleanup_count == 1

    # Exceptions
    cleanup_count = 0
    ctx = Contexts.Context()
    Contexts.defer(ctx) do
        cleanup_count += 1
    end
    Contexts.defer(ctx) do
        error("X")
    end
    try
        Contexts.cleanup!(ctx)
    catch
    end
    # The second scheduled cleanup should still run even if the first throws
    @test cleanup_count == 1
    # Calling cleanup should not throw again
    @test isnothing(Contexts.cleanup!(ctx))
    @test cleanup_count == 1
end

@testset "Manually managed contexts" begin
    @testset "Finalization" begin
        did_cleanup = false
        function forgotten_cleanup()
            ctx = Contexts.Context()
            Contexts.defer(ctx) do
                did_cleanup = true
            end
        end
        forgotten_cleanup()
        GC.gc()
        # Check that the finalizer of the manually managed `ctx` ran, cleaning up
        # the resources used.
        @test did_cleanup
    end
end

include("base_interop.jl")
