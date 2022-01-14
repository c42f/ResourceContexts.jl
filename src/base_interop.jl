# Filesystem

@! function Base.open(filename::AbstractString, mode::AbstractString; kws...)
    io = open(filename, mode; kws...)
    @defer close(io)
    io
end

@! function Base.open(filename::AbstractString; kws...)
    io = open(filename; kws...)
    @defer close(io)
    io
end

@! function Base.mktemp(parent=tempdir())
    (path, io) = mktemp(parent, cleanup=false)
    @defer begin
        close(io)
        rm(path, force=true)
    end
    (path, io)
end

@! function Base.mktempdir(parent=tempdir(); prefix="jl_")
    path = mktempdir(parent, cleanup=false)
    @defer rm(path, recursive=true, force=true)
    path
end

@! function Base.cd(path::AbstractString=homedir())
    oldpath = pwd()
    cd(path)
    @defer cd(oldpath)
    # TODO: `Base.cd(::Function, path)` has some magic here for unix which we
    # could replicate.
end

# Locks

@! function Base.lock(lk::Base.AbstractLock)
    lock(lk)
    @defer unlock(lk)
end


# Standard streams

# Incompatibility due to
# https://github.com/JuliaLang/julia/pull/39132
@static if VERSION < v"1.7"

@! function Base.redirect_stdout(stream)
    prev_stream = stdout
    x = redirect_stdout(stream)
    @defer redirect_stdout(prev_stream)
    x
end

@! function Base.redirect_stderr(stream)
    prev_stream = stderr
    x = redirect_stderr(stream)
    @defer redirect_stderr(prev_stream)
    x
end

@! function Base.redirect_stdin(stream)
    prev_stream = stdin
    x = redirect_stdin(stream)
    @defer redirect_stdin(prev_stream)
    x
end

else

@! function (f::Base.RedirectStdStream)(stream)
    # See https://github.com/JuliaLang/julia/blob/294b0dfcd308b3c3f829b2040ca1e3275595e058/base/stream.jl#L1417
    stdold = f.unix_fd == 0 ? stdin :
             f.unix_fd == 1 ? stdout :
             f.unix_fd == 2 ? stderr :
             throw(ArgumentError("Not implemented to get old handle of fd except for stdio"))
    x = f(stream)
    @defer f(stdold)
    x
end

@! function Base.redirect_stdio(; kws...)
    @! enter_do(redirect_stdio; kws...)
end

end
