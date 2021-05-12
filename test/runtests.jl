using Contexts
using Test

function foo(ctx::AbstractContext, x)
    # Use of @defer with explicit context
    @defer ctx push!(x, :A)
end

@testset "Cleanup ordering" begin
    cleanups = []
    @context begin
        @! foo(cleanups)
        @defer push!(cleanups, :B)
        @test cleanups == []
    end
    @test cleanups == [:B, :A]
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

@testset "Base interop" begin
    @testset "open() and mktemp()" begin
        path = ""
        io1 = nothing
        io2 = nothing
        io3 = nothing
        io4 = nothing
        @context begin
            (path,io1) = @! mktemp()
            msg = "hi from Contexts.jl"
            write(io1, msg)
            flush(io1)
            # Test various forms of open()
            io2 = @! open(path)
            @test read(io2, String) == msg
            io3 = @! open(path, "r")
            @test read(io3, String) == msg
            io4 = @! open(path, read=true)
            @test read(io4, String) == msg
        end
        @test !isempty(path) && !ispath(path)
        @test !isopen(io1)
        @test !isopen(io2)
        @test !isopen(io3)
        @test !isopen(io4)
    end

    @testset "mktemp() and mktempdir()" begin
        parent_dir = nothing
        dir2 = nothing
        filepath = nothing
        @context begin
            parent_dir = @! mktempdir()
            # forms with parent dirs
            dir2 = @! mktempdir(parent_dir)
            (filepath,_) = @! mktemp(parent_dir)
            # All resources are created
            @test isdir(parent_dir)
            @test isdir(dir2)
            @test isfile(filepath)
            @test parent_dir == dirname(dir2)
            @test parent_dir == dirname(filepath)
        end
        # All resources are cleaned up
        @test !ispath(parent_dir)
        @test !ispath(dir2)
        @test !ispath(filepath)
    end

    @testset "lock()" begin
        lk = ReentrantLock()
        @context begin
            @! lock(lk)
            @test islocked(lk)
        end
        @test !islocked(lk)
    end

    @testset "redirect_stdout / stderr / stdin" begin
        orig_stdin = stdin
        orig_stdout = stdout
        orig_stderr = stderr
        @context begin
            (_,io) = @! mktemp()
            @! redirect_stdout(io)
            println("hi")
            flush(io)
            seek(io, 0)
            @test readline(io) == "hi"
        end
        @context begin
            (_,io) = @! mktemp()
            @! redirect_stderr(io)
            println(stderr, "hi")
            flush(io)
            seek(io, 0)
            @test readline(io) == "hi"
        end
        @context begin
            (_,io) = @! mktemp()
            println(io, "hi")
            flush(io)
            seek(io,0)
            @! redirect_stdin(io)
            @test readline() == "hi"
        end
        @test orig_stdin == stdin
        @test orig_stdout == stdout
        @test orig_stderr == stderr
    end

    @testset "cd()" begin
        oldpath = pwd()
        @context begin
            @! cd()
            @test pwd() == homedir()
            path = @! mktempdir()
            @! cd(path)
            @test pwd() == path
        end
        @test pwd() == oldpath
    end
end
