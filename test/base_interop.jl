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

    @testset "cd()" begin
        oldpath = pwd()
        @context begin
            @! cd()
            # Can't just compare paths here due to the fact that some of these
            # could be symlinks on macOS.  Instead use `samefile` with an alias
            # for @test pretty printing
            ≃(a,b) = Base.Filesystem.samefile(a,b)
            @test pwd() ≃ homedir()
            path = @! mktempdir()
            @! cd(path)
            @test pwd() ≃ path
        end
        @test pwd() == oldpath
    end

    @testset "run()" begin
        in_io = Pipe()
        out_io = IOBuffer()
        local proc
        @context begin
            proc = @! run(pipeline(`$(Base.julia_cmd()) -e 'write(stdout, readline(stdin))'`,
                                   stdout=out_io, stdin=in_io))
            @test !process_exited(proc)
            println(in_io, "hi")
        end
        @test process_exited(proc)
        @test String(take!(out_io)) == "hi"
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

        stdout_result = nothing
        @context begin
            (_,io) = @! mktemp()
            @! redirect_stdout(io)
            println("hi")
            flush(io)
            seek(io, 0)
            stdout_result = readline(io)
        end
        @test stdout_result == "hi"

        stderr_result = nothing
        @context begin
            (_,io) = @! mktemp()
            @! redirect_stderr(io)
            println(stderr, "hi")
            flush(io)
            seek(io, 0)
            stderr_result = readline(io)
        end
        if VERSION < v"1.7-DEV"
            @test stderr_result == "hi"
        else
            @test_broken stderr_result == "hi"
        end

        stdin_result = nothing
        @context begin
            (_,io) = @! mktemp()
            println(io, "hi")
            flush(io)
            seek(io,0)
            @! redirect_stdin(io)
            stdin_result = readline()
        end
        if VERSION < v"1.7-DEV"
            @test stdin_result == "hi"
        else
            @test_broken stdin_result == "hi"
        end

        @test orig_stdin == stdin
        @test orig_stdout == stdout
        @test orig_stderr == stderr
    end
end
