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

# Processes

"""
    @! run(command, args...)

Run a `command` object asynchronously as in `run(...; wait=false)` and return
the `Process` object. The process object is bound to the scope of the current
`@context` and will be waited for with `wait()` when the context exits.
"""
@! function Base.run(cmds::Base.AbstractCmd, args...)
    proc = run(cmds, args..., wait=false)
    @defer success(proc) || Base.pipeline_error(proc)
    proc
end

# Locks

@! function Base.lock(lk::Base.AbstractLock)
    lock(lk)
    @defer unlock(lk)
end


# Standard streams

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

