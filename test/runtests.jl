using ResourceContexts
using Test
using Logging
using Compat

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
        stack = current_exceptions()
        @test stack[1][1] == ErrorException("B")
        @test stack[2][1] == ErrorException("A")
    end
end

@! function do_nothing()
    nothing
end

Main.eval(:(
# Eval in Main, in case test is eval'd elsewhere
function do_nothing_from_function()
    @! $(@__MODULE__).do_nothing()
end
))

@testset "Logging when using the global context" begin
    q = :(@! do_nothing())
    # Simulate call coming from the REPL in any module
    q.args[2] = LineNumberNode(1, Symbol("REPL[1]"))
    @test_logs (:debug, r"^Using global `ResourceContext`",
                Test.Ignored(), Test.Ignored(),
                Test.Ignored(), "REPL[1]", 1) #=
        =# min_level=Logging.Debug Main.eval(q)
    # Simulate call coming from Main module in global scope
    q.args[2] = LineNumberNode(1, Symbol("SomeOtherFile"))
    @test_logs (:debug,) min_level=Logging.Debug Main.eval(q)
    # Call coming from within a function
    @test_logs (:warn,) min_level=Logging.Debug Main.do_nothing_from_function()
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
        first(current_exceptions(e.task))[1]
    end == ErrorException("Oops1")

    @test try
        @context begin
            @! enter_do(fail_after_user_func)
        end
    catch e
        @test e isa TaskFailedException
        first(current_exceptions(e.task))[1]
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
            @! ResourceContexts.detach_context_cleanup([1,2])
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
    ctx = ResourceContexts.ResourceContext()
    ResourceContexts.defer(ctx) do
        cleanup_count += 1
    end
    ResourceContexts.cleanup!(ctx)
    ResourceContexts.cleanup!(ctx)
    @test cleanup_count == 1

    # Exceptions
    cleanup_count = 0
    ctx = ResourceContexts.ResourceContext()
    ResourceContexts.defer(ctx) do
        cleanup_count += 1
    end
    ResourceContexts.defer(ctx) do
        error("X")
    end
    try
        ResourceContexts.cleanup!(ctx)
    catch
    end
    # The second scheduled cleanup should still run even if the first throws
    @test cleanup_count == 1
    # Calling cleanup should not throw again
    @test isnothing(ResourceContexts.cleanup!(ctx))
    @test cleanup_count == 1
end

@testset "Manually managed contexts" begin
    @testset "Finalization" begin
        did_cleanup = false
        function forgotten_cleanup()
            ctx = ResourceContexts.ResourceContext()
            ResourceContexts.defer(ctx) do
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
