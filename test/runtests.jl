using Contexts
using Test

function foo(ctx::AbstractContext, do_cleanup)
    # Use of @defer with explicit context
    @defer ctx do_cleanup()
end

@testset "Cleanup ordering" begin
    cleanups = []
    @context begin
        @! foo(()->push!(cleanups, :A))
        @defer push!(cleanups, :B)
        @test cleanups == []
    end
    @test cleanups == [:B, :A]
end

@testset "Exceptions during cleanup" begin
    try
        @context begin
            @! foo(()->push!(cleanups, :A))
            @defer error("A")
            @defer error("B")
        end
    catch exc
        stack = Base.catch_stack()
        @test stack[1][1] == ErrorException("B")
        @test stack[2][1] == ErrorException("A")
    end
end

@testset "Contexts Base interop" begin
end
