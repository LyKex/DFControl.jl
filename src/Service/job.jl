function load_job(job_dir::AbstractString)
    orig_dir = job_dir
    scriptpath = joinpath(job_dir, "job.tt")
    if ispath(scriptpath)
        version = Jobs.version(job_dir)
    else
        error("No valid job found in $job_dir.")
    end
    metadata = ispath(joinpath(job_dir, ".metadata.jld2")) ? JLD2.load(joinpath(job_dir, ".metadata.jld2"))["metadata"] : Dict{Symbol, Any}()

    name, tcalcs, header, environment = FileIO.read_job_script(scriptpath)
    calculations, structure = FileIO.parse_calculations(tcalcs)
    job = Job(name         = name,
              dir          = orig_dir,
              version      = version,
              metadata     = metadata,
              structure    = structure,
              calculations = calculations,
              header       = header,
              environment  = environment)
    return job
end

job_versions(args...) = Jobs.job_versions(args...)
registered_jobs(args...) = Jobs.registered_jobs(args...)

function running_jobs(fuzzy)
    out = Tuple{String, Int}[]
    for (j, info) in JOB_QUEUE[]
        if occursin(fuzzy, j)
            if info[2] == Jobs.Running || info[2] == Jobs.Pending || info[2] == Jobs.Submitted
                push!(out, (j, info[1]))
            end
        end
    end
    return out
end

function workflow_logger(job::Job)
    return TeeLogger(MinLevelLogger(FileLogger(joinpath(job, ".workflow", "info.log");
                                               append = true), Logging.Info),
                     MinLevelLogger(FileLogger(joinpath(job, ".workflow", "info.log");
                                               append = true), Logging.Warn),
                     MinLevelLogger(FileLogger(joinpath(job, ".workflow", "error.log");
                                               append = true), Logging.Error))
end

queued_dir(job::Job, args...) = joinpath(job, ".workflow/queued", args...)
finished_dir(job::Job, args...) = joinpath(job, ".workflow/finished", args...)

function clear_queue!(job::Job)
    qd = queued_dir(job)
    if !ispath(qd)
        return
    end
    for f in readdir(qd)
        rm(joinpath(qd, f))
    end
end

queued(job::Job) = readdir(queued_dir(job))
finished(job::Job) = readdir(finished_dir(job))

# function submit_workflow(job::Job, funcs, d::Daemon = init_daemon())
#     queue_steps(job, funcs)
#     write_workflow_files(job)
#     while !is_started(d)
#         sleep(1)
#     end
#     return runexpr("""
#                DFControl.spawn_worker(DAEMON, Job("$(job.dir)"))
#                DFControl.save(DAEMON)
#                """; port = d.port)
# end

mods_test() = Base.loaded_modules

"""
    save(job::Job)

Saves the job's calculations and `job.tt` submission script in `job.dir`.
Some sanity checks will be performed on the validity of flags, execs, pseudopotentials, etc.
The job will also be registered for easy retrieval at a later stage.

If a previous job is present in the job directory (indicated by a valid job script),
it will be copied to the `.versions` sub directory as the previous version of `job`,
and the version of `job` will be incremented. 
"""
function save(jobdir::String, files; kwargs...)

    if jobdir[end] == '/'
        jobdir = jobdir[1:end-1]
    end
    #Since at this stage we know the job will belong to the current localhost we change the server
    # Here we find the main directory, needed for if a job's local dir is a .versions one
    dir = Jobs.main_job_dir(jobdir)
    version = Jobs.last_job_version(dir) + 1
    if ispath(joinpath(dir, "job.tt"))
        tj = load_job(dir)
        cp(tj, joinpath(tj, Jobs.VERSION_DIR_NAME, "$(tj.version)"); force = true)
    end
    if jobdir != dir
        # We know for sure it was a previously saved job
        # Now that we have safely stored it we can clean out the directory to then fill
        # it with the files from the job.version
        clean_dir!(dir)
        for f in readdir(jobdir)
            cp(f, dir; force = true)
        end
    end

    
    # Needs to be done so the inputs `dir` also changes.
    mkpath(dir)

    for (name, f) in files
        d = splitdir(name)[1]
        mkpath(joinpath(dir, d))
        write(joinpath(dir, name), f)
    end

    Jobs.maybe_register_job(jobdir)
    return version
end

"""
    submit(dir::String, workflow::Bool)

Writes the directory to either pending workflows or pending jobs file.
"""
function submit(job_dir::String, workflow::Bool)
    if workflow
        open(PENDING_WORKFLOWS_FILE, "a", lock=true) do f
            return write(f, job_dir * "\n")
        end
    else
        open(PENDING_JOBS_FILE, "a", lock=true) do f
            return write(f, job_dir * "\n")
        end
    end
end

# The actual submitting
function submit(s::Server, job_dir::String)
    if s.scheduler == Servers.Bash
        return bash_submit(job_dir)
    elseif s.scheduler == Servers.Slurm
        return slurm_submit(job_dir)
    end
end

"""
    last_running_calculation(path::String)

Returns the last `Calculation` for which an output file was created.
"""
function last_running_calculation(path::String)
    scrpath = joinpath(path, "job.tt")
    job = load_job(path)
    t = mtime(Jobs.scriptpath(job))
    times = map(x -> (o = joinpath(job, x.outfile); ispath(o) ? mtime(o) : 0.0), job.calculations)
    return isempty(times) ? nothing : findmax(times)[2]
end

"""
    state(job_dir::String)

Returns the job state of the job in `job_dir`.
"""
state(job_dir::String) =
    haskey(JOB_QUEUE[], job_dir) ? JOB_QUEUE[][job_dir][2] : Jobs.Unknown

function dirsize(path::String)
    totsize = 0.0
    for (root, dirs, files) in walkdir(path)
        for file in files
            totsize += filesize(root, file)
        end
    end
    return totsize
end

"""
    filesize(job::Job)

Total filesize on disk for a job and all its versions.
"""
Base.filesize(job::Job) = dirsize(job.dir)

"""
    cleanup(job::Job)
    
Cleanup `job.dir` interactively.
"""
function cleanup(job::Job)
    labels = String[]
    paths = String[]
    for v in versions(job)
        vpath = version_dir(job, v)
        s = round(dirsize(vpath) / 1e6; digits = 3)
        push!(labels, "Version $v:  $s Mb")
        push!(paths, vpath)
        opath = joinpath(vpath, Jobs.TEMP_CALC_DIR)
        if ispath(opath)
            s_out = round(dirsize(opath) / 1e6; digits = 3)
            push!(labels, "Version $v/outputs:  $s_out Mb")
            push!(paths, opath)
        end
    end
    menu = MultiSelectMenu(labels)
    choices = request("Select job files to delete:", menu)
    for i in choices
        if ispath(paths[i]) # Could be that outputs was already deleted
            @info "Deleting $(paths[i])"
            rm(paths[i]; recursive = true)
        end
    end
end

function save_metadata(job)
    return jldsave(joinpath(job, ".metadata.jld2"); metadata = job.metadata,
                   version = job.version)
end

timestamp(job::Job) = timestamp(job.dir)
has_timestamp(job) = haskey(job.metadata, :timestamp)

function clean_dir!(dir::AbstractString)
    for f in readdir(dir)
        if f == Jobs.TEMP_CALC_DIR ||
           f == Jobs.VERSION_DIR_NAME ||
           splitext(f)[end] == ".jl"
            continue
        end
        rm(joinpath(dir, f); recursive = true)
    end
end

exists_job(d::AbstractString) = ispath(d) && ispath(joinpath(d, "job.tt"))

"Finds the output files for each of the calculations of a job, and groups all found data into a dictionary."
function outputdata(jobdir::String, calculations::Vector{String})
    job = load_job(jobdir)
    calculations = isempty(calculations) ? map(x->x.name, job.calculations) : calculations
    respath = joinpath(job, "results.jld2")
    if ispath(respath)
        datadict = JLD2.load(respath, "outputdata")
    else
        datadict = Dict{String,Dict{Symbol,Any}}()
    end
    stime = isempty(datadict) ? 0.0 : mtime(respath)
    new_data = false
    for c in calculations
        calculation = job[c]
        p = joinpath(job, calculation.outfile)
        if mtime(p) > stime
            try 
                tout = outputdata(calculation, p)
                if !isempty(tout)
                    datadict[calculation.name] = tout
                    new_data = true
                end
            catch e
                @warn "Something went wrong reading output for calculation $c."
                @warn e
            end
        end
    end
    if new_data
        JLD2.jldsave(respath; outputdata=datadict)
        return respath
    elseif ispath(respath)
        return respath
    else
        return nothing
    end
end

rm_version!(jobdir::String, version::Int) = Jobs.rm_version!(load_job(jobdir), version)

add_environment(env::Environment, name::AbstractString) = Jobs.save(env, name)
function get_environment(name::AbstractString)
    out = Jobs.load_environment(name)
    if out === nothing
        error("No Environment found with name $name")
    end
    return out
end

rm_environment!(args...) = Jobs.rm_environment!(args...)

queue(args...) = queue!(Dict{String, Tuple{Int, Jobs.JobState}}(), args...)

function queue!(q, s::Server, init=false)
    if s.scheduler == Servers.Bash
        return bash_queue!(q, init) 
    elseif s.scheduler == Servers.Slurm
        return slurm_queue!(q, init) 
    end
end

function abort(job_dir::String)
    @assert haskey(JOB_QUEUE[], job_dir) "No job exists in dir: $job_dir!"
    id = JOB_QUEUE[][job_dir][1]
    s = local_server()
    if s.scheduler == Servers.Bash
        return bash_abort(id) 
    elseif s.scheduler == Servers.Slurm
        return slurm_abort(id) 
    end
    JOB_QUEUE[][job_dir] = (JOB_QUEUE[][job_dir][1], Jobs.Cancelled)
end
