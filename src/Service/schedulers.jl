using ..Servers: Bash, Slurm, Scheduler

function queue!(q, s::Scheduler, init)
    if init
        if ispath(QUEUE_FILE)
            copy!(q, JSON3.read(read(QUEUE_FILE), Dict{String, Tuple{Int, Jobs.JobState}}))
        end
    end
    for (dir, info) in q
        if !isdir(dir)
            pop!(q, dir)
            continue
        end
        id = info[1]
        if info[2] == Jobs.Running || info[2] == Jobs.Pending || info[2] == Jobs.Submitted || info[2] == Jobs.Unknown
            q[dir] = (id, Servers.jobstate(s, id))
        end
    end
    JSON3.write(QUEUE_FILE, q)
    return q
end


## BASH ##
function Servers.jobstate(::Bash, id::Int)
    out = Pipe()
    err = Pipe()
    p = run(pipeline(ignorestatus(`ps -p $id`), stderr = err, stdout=out))
    close(out.in)
    close(err.in)
    return p.exitcode == 1 ? Jobs.Completed : Jobs.Running
end

Servers.submit(b::Bash, j::String) = 
    Int(getpid(run(Cmd(`bash job.tt`, detach=true, dir=j), wait=false)))

Servers.abort(b::Bash, id::Int) = 
    run(`pkill $id`)

## SLURM ##
function Servers.jobstate(::Slurm, id::Int)
    cmd = `sacct -u $(ENV["USER"]) --format=State -j $id -P`
    state = readlines(cmd)[2]
    if state == "PENDING"
        return Jobs.Pending
    elseif state == "RUNNING"
        return Jobs.Running
    elseif state == "COMPLETED"
        return Jobs.Completed
    elseif state == "CANCELLED"
        return Jobs.Cancelled
    elseif state == "BOOT_FAIL"
        return Jobs.BootFail
    elseif state == "DEADLINE"
        return Jobs.Deadline
    elseif state == "FAILED"
        return Jobs.Failed
    elseif state == "NODE_FAIL"
        return Jobs.NodeFail
    elseif state == "OUT_OF_MEMORY"
        return Jobs.OutOfMemory
    elseif state == "PREEMTED"
        return Jobs.Preempted
    elseif state == "REQUEUED"
        return Jobs.Requeued
    elseif state == "RESIZING"
        return Jobs.Resizing
    elseif state == "REVOKED"
        return Jobs.Revoked
    elseif state == "SUSPENDED"
        return Jobs.Suspended
    elseif state == "TIMEOUT"
        return Jobs.Timeout
    end
    return Jobs.Unknown
end

Servers.submit(::Slurm, j::String) =
    parse(Int, split(read(Cmd(`sbatch job.tt`, dir=j), String))[end])

Servers.abort(s::Slurm, id::Int) = 
    run(`scancel $id`)
