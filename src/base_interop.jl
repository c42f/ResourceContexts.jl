
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
    (path, io)
end

function Base.lock(ctx::AbstractContext, lk::Base.AbstractLock)
    lock(lk)
    @defer ctx unlock(lk)
end
