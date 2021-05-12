# Filesystem

function Base.open(ctx::AbstractContext, filename::AbstractString, mode::AbstractString; kws...)
    io = open(filename, mode; kws...)
    @defer ctx close(io)
    io
end

function Base.open(ctx::AbstractContext, filename::AbstractString; kws...)
    io = open(filename; kws...)
    @defer ctx close(io)
    io
end

function Base.mktemp(ctx::AbstractContext, parent=tempdir())
    (path, io) = mktemp(parent, cleanup=false)
    @defer ctx close(io)
    @defer ctx rm(path, force=true)
    (path, io)
end

function Base.mktempdir(ctx::AbstractContext, parent=tempdir(); prefix="jl_")
    path = mktempdir(parent, cleanup=false)
    @defer ctx rm(path, recursive=true, force=true)
    path
end

function Base.cd(ctx::AbstractContext, path::AbstractString=homedir())
    oldpath = pwd()
    cd(path)
    @defer ctx cd(oldpath)
    # TODO: `Base.cd(::Function, path)` has some magic here for unix which we
    # could replicate.
end

# Locks

function Base.lock(ctx::AbstractContext, lk::Base.AbstractLock)
    lock(lk)
    @defer ctx unlock(lk)
end


# Standard streams

function Base.redirect_stdout(ctx::AbstractContext, stream)
    prev_stream = stdout
    x = redirect_stdout(stream)
    @defer ctx redirect_stdout(prev_stream)
    x
end

function Base.redirect_stderr(ctx::AbstractContext, stream)
    prev_stream = stderr
    x = redirect_stderr(stream)
    @defer ctx redirect_stderr(prev_stream)
    x
end

function Base.redirect_stdin(ctx::AbstractContext, stream)
    prev_stream = stdin
    x = redirect_stdin(stream)
    @defer ctx redirect_stdin(prev_stream)
    x
end

