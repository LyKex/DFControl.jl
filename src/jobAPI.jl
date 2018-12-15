#------------- Basic Functionality ---------------#
"""
    save(job::DFJob)

Saves a DFJob, it's job file and all it's input files.
"""
function save(job::DFJob, local_dir=job.local_dir)
    local_dir = local_dir != "" ? local_dir : error("Please specify a valid local_dir!")
    if !ispath(local_dir)
        mkpath(local_dir)
        @info "$local_dir did not exist, it was created."
    end
    sanitizeflags!(job)
    job.local_dir = local_dir
    return writejobfiles(job)
end

"""
    submit(job::DFJob; server=job.server, server_dir=job.server_dir)

Saves the job locally, and then either runs it locally using `qsub` (when `job.server == "localhost"`) or sends it to the specified `job.server` in `job.server_dir`, and submits it using `qsub` on the server.
"""
function submit(job::DFJob; server=job.server, server_dir=job.server_dir)
    save(job)
    job.server = server
    job.metadata[:slurmid] = qsub(job)
end

"""
    abort(job::DFJob)

Will look for the job id inside it's metadata and try to remove it from the server queue.
If the lastrunning input happened to be a QE input, the correct abort file will be written.
If it's Wannier90 the job will be brutally removed from the slurm queue.
"""
function abort(job::DFJob)
    lastrunning = runninginput(job)
    if lastrunning == nothing
        error("Is this job running?")
    end
    if package(lastrunning) == QE
        length(inputs(job, QE)) > 1 &&
            @warn "It's absolutely impossible to guarantee a graceful abort of a multi job script with QE."

        abortpath = writeabortfile(job, lastrunning)
        while ispath(abortpath)
            continue
        end
        qdel(job)
    else
        if !haskey(job.metadata, :slurmid)
            error("No slurm id found for this job.")
        end
        qdel(job)
    end
end

"""
    setflow!(job::DFJob, should_runs...)

Sets whether or not calculations should be run. Calculations are specified using their indices.
"""
function setflow!(job::DFJob, should_runs...)
    for (name, run) in should_runs
        for input in inputs(job, name)
            input.run = run
        end
    end
    return job
end

"""
    setheaderword!(job::DFJob, word::String, new_word::String)


Replaces the specified word in the header with the new word.
"""
function setheaderword!(job::DFJob, word::String, new_word::String; print=true)
    for (i, line) in enumerate(job.header)
        if occursin(word, line)
            job.header[i] = replace(line, word => new_word)
            s = """Old line:
            $line
            New line:
            $(job.header[i])
            """
            print && (@info s)
        end
    end
    return job
end

function isrunning(job::DFJob)
    @assert haskey(job.metadata, :slurmid) error("No slurmid found for job $(job.name)")
    cmd = `qstat -f $(job.metadata[:slurmid])`
    if runslocal(job)
        str = read(cmd, String)
    else
        str = sshreadstring(job.server, cmd)
    end
    isempty(str) && return false
    splstr = split(str)
    for (i,s) in enumerate(splstr)
        if s=="job_state"
            return any(splstr[i+2] .== ["Q","R"])
        end
    end
end

function progressreport(job::DFJob; kwargs...)
    dat = outputdata(job; kwargs...)
    plotdat = SymAnyDict(:fermi=>0.0)
    for (n, d) in dat
        i = input(job, n)
        if isbandscalc(i) && haskey(d, :bands)
            plotdat[:bands] = d[:bands]
        elseif isscfcalc(i) || isnscfcalc(i)
            haskey(d, :fermi) && (plotdat[:fermi] = d[:fermi])
            haskey(d, :accuracy) && (plotdat[:accuracy] = d[:accuracy])
        end
    end
    return plotdat
end

"""
Sets the server dir of the job.
"""
function setserverdir!(job, dir)
    job.server_dir = dir
    return job
end

"""
Sets the local dir of the job.
"""
function setlocaldir!(job, dir)
    if !isabspath(dir)
        dir = abspath(dir)
    end
    job.local_dir = dir
    for i in inputs(job)
        setdir!(i, dir)
    end
    return job
end


#-------------- Basic Interaction with DFInputs inside the DFJob ---------------#
setname!(job::DFJob, oldn, newn) = (input(job, oldn).name = newn)
Base.insert!(job::DFJob, index::Int, input::DFInput) = insert!(job.inputs, index, input)
Base.push!(job::DFJob, input::DFInput) = push!(job.inputs, input)

"""Access an input inside the job using it's name. E.g `job["scf"]`"""
function Base.getindex(job::DFJob, id::String)
    tmp = getfirst(x -> name(x)==id, inputs(job))
    if tmp != nothing
        return tmp
    else
        error("No Input with name $id")
    end
end


"""Searches through the inputs for the requested flag.
If a flag was found the input and value of the flag will be added to the returned Dict."""
function Base.getindex(job::DFJob, flg::Symbol)
    outdict = Dict()
    for i in inputs(job)
        tfl = flag(i, flg)
        if tfl != nothing
            outdict[name(i)] = tfl
        end
    end
    return outdict
end

"Set one flag in all the appropriate inputs. E.g `job[:ecutwfc] = 23.0`"
function Base.setindex!(job::DFJob, dat, key::Symbol)
    for input in inputs(job)
        input[key] = dat
    end
end

"Fuzzily search inputs in the job whose name contain the fuzzy."
searchinputs(job::DFJob, fuzzy::AbstractString) = inputs(job, fuzzy, true)

"Fuzzily search the first input in the job whose name contains the fuzzy."
searchinput(job::DFJob,  fuzzy::AbstractString) = input(job, fuzzy, true)

"""
    setflags!(job::DFJob, inputs::Vector{<:DFInput}, flags...; print=true)

Sets the flags in the names to the flags specified.
This only happens if the specified flags are valid for the names.
If necessary the correct control block will be added to the calculation (e.g. for QEInputs).

The values that are supplied will be checked whether they are valid.
"""
function setflags!(job::DFJob, inputs::Vector{<:DFInput}, flags...; print=true)
    found_keys = Symbol[]

    for calc in inputs
        t_, = setflags!(calc, flags..., print=print)
        push!(found_keys, t_...)
    end
    nfound = setdiff([k for (k, v) in flags], found_keys)
    if print && length(nfound) > 0
        f = length(nfound) == 1 ? "flag" : "flags"
        dfprintln("$f '$(join(":" .* String.(setdiff(flagkeys, found_keys)),", "))' were not found in the allowed input variables of the specified inputs!")
    end
    return job
end
setflags!(job::DFJob, flags...;kwargs...) =
    setflags!(job, inputs(job), flags...;kwargs...)
setflags!(job::DFJob, name::String, flags...; fuzzy=true, kwargs...) =
    setflags!(job, inputs(job, name, fuzzy), flags...; kwargs...)

""" data(job::DFJob, name::String, dataname::Symbol)

Looks through the calculation filenames and returns the data with the specified symbol.
"""
data(job::DFJob, name::String, dataname::Symbol) =
    data(input(job, name), dataname)

"""
    setdata!(job::DFJob, inputs::Vector{<:DFInput}, dataname::Symbol, data; option=nothing)

Looks through the calculation filenames and sets the data of the datablock with `data_block_name` to `new_block_data`.
if option is specified it will set the block option to it.
"""
function setdata!(job::DFJob, inputs::Vector{<:DFInput}, dataname::Symbol, data; kwargs...)
    setdata!.(inputs, dataname, data; kwargs...)
    return job
end
setdata!(job::DFJob, name::String, dataname::Symbol, data; fuzzy=true, kwargs...) =
    setdata!(job, inputs(job, name, fuzzy), dataname, data; kwargs...)

"""
    setdataoption!(job::DFJob, names::Vector{String}, dataname::Symbol, option::Symbol)

sets the option of specified data in the specified inputs.
"""
function setdataoption!(job::DFJob, names::Vector{String}, dataname::Symbol, option::Symbol; kwargs...)
    setdataoption!.(inputs(job, names), dataname, option; kwargs...)
    return job
end
setdataoption!(job::DFJob, n::String, name::Symbol, option::Symbol; kw...) =
    setdataoption!(job, [n], name, option; kw...)

"""
    setdataoption!(job::DFJob, name::Symbol, option::Symbol)

sets the option of specified data block in all calculations that have the block.
"""
setdataoption!(job::DFJob, n::Symbol, option::Symbol; kw...) =
    setdataoption!(job, name.(inputs(job)), n, option; kw...)

"""
    rmflags!(job::DFJob, inputs::Vector{<:DFInput}, flags...)

Looks through the input names and removes the specified flags.
"""
function rmflags!(job::DFJob, inputs::Vector{<:DFInput}, flags...; kwargs...)
    rmflags!.(inputs, flags...; kwargs...)
    return job
end
rmflags!(job::DFJob, name::String, flags...; fuzzy=true, kwargs...) =
    rmflags!(job, inputs(job, name, fuzzy), flags...; kwargs...)
rmflags!(job::DFJob, flags...; kwargs...) =
    rmflags!(job, inputs(job), flags...; kwargs...)

"Returns the executables attached to a given input."
execs(job::DFJob, name) =
    execs(input(job, name))

"""
    setexecflags!(job::DFJob, exec, flags...)

Goes through the calculations of the job and if the name contains any of the `inputnames` it sets the exec flags to the specified ones.
"""
setexecflags!(job::DFJob, exec, flags...) =
    setexecflags!.(job.inputs, (exec, flags)...)
rmexecflags!(job::DFJob, exec, flags...) =
    rmexecflags!.(job.inputs, (exec, flags)...)

"Sets the directory of the specified executable."
setexecdir!(job::DFJob, exec, dir) =
    setexecdir!.(job.inputs, exec, dir)


"Finds the output files for each of the inputs of a job, and groups all found data into a dictionary."
function outputdata(job::DFJob, inputs::Vector{DFInput}; print=true, onlynew=false)
    datadict = Dict()
    stime = starttime(job)
    for input in inputs
        newout = hasnewout(input, stime)
        if onlynew && !newout
            continue
        end
        tout = outputdata(input; print=print, overwrite=newout)
        if !isempty(tout)
            datadict[name(input)] = tout
        end
    end
    datadict
end
outputdata(job::DFJob; kwargs...) = outputdata(job, inputs(job); kwargs...)
outputdata(job::DFJob, names::String...; kwargs...) =
    outputdata(job, inputs(job, names); kwargs...)
function outputdata(job::DFJob, n::String; fuzzy=true, kwargs...)
    dat = outputdata(job, inputs(job, n, fuzzy); kwargs...)
    if dat != nothing && haskey(dat, name(input(job, n)))
        return dat[name(input(job, n))]
    end
end

#------------ Specialized Interaction with DFInputs inside DFJob --------------#
"""
    setkpoints!(job::DFJob, n, k_points)

sets the data in the k point `DataBlock` inside the specified inputs.
"""
function setkpoints!(job::DFJob, n, k_points; print=true)
    for calc in inputs(job, n)
        setkpoints!(calc, k_points, print=print)
    end
    return job
end


"Reads throught the pseudo files and tries to figure out the correct cutoffs"
function setcutoffs!(job::DFJob)
    @assert job.server == "localhost" "Cutoffs can only be automatically set if the pseudo files live on the local machine."
    pseudofiles = filter(!isempty, [pseudo(at) for at in atoms(job)])
    pseudodirs  = String[]
    for i in inputs(job)
        if package(i) == QE
            dr = pseudodir(i)
            if dr != nothing && ispath(dr) #absolute paths only allowed in QE
                push!(pseudodirs, dr)
            end
        end
    end
    @assert !isempty(pseudofiles) "No atoms with pseudo files found."
    @assert !isempty(pseudodirs) "No valid pseudo directories found in the inputs."
    maxecutwfc = 0.0
    maxecutrho = 0.0
    for d in pseudodirs
        for f in pseudofiles
            pth = joinpath(d, f)
            if ispath(pth)
                ecutwfc, ecutrho = read_cutoffs_from_pseudofile(pth)
                if ecutwfc != nothing && ecutrho != nothing
                    maxecutwfc = ecutwfc > maxecutwfc ? ecutwfc : maxecutwfc
                    maxecutrho = ecutrho > maxecutrho ? ecutrho : maxecutrho
                end
            end
        end
    end
    setcutoffs!.(inputs(job), maxecutwfc, maxecutrho)
end

"""
    addwancalc!(job::DFJob, nscf::DFInput{QE}, Emin::Real, projections;
                     Emin=-5.0,
                     Epad=5.0,
                     wanflags=SymAnyDict(),
                     pw2wanexec=Exec("pw2wannier90.x", nscf.execs[2].dir, nscf.execs[2].flags),
                     wanexec=Exec("wannier90.x", nscf.execs[2].dir),
                     bands=readbands(nscf))

Adds a wannier calculation to a job. For now only works with QE.
"""
function addwancalc!(job::DFJob, nscf::DFInput{QE}, Emin::Real, projections_...;
                     Epad=5.0,
                     wanflags=SymAnyDict(),
                     pw2wanexec=Exec("pw2wannier90.x", nscf.execs[2].dir),
                     wanexec=Exec("wannier90.x", nscf.execs[2].dir),
                     bands=readbands(nscf),
                     print=true)

    spin = isspincalc(nscf)
    if spin
        pw2wannames = ["pw2wan_up", "pw2wan_dn"]
        wannames = ["wanup", "wandn"]
        print && (@info "Spin polarized calculation found (inferred from nscf input).")
    else
        pw2wannames = ["pw2wan"]
        wannames = ["wan"]
    end

    @assert flag(nscf, :calculation) == "nscf" error("Please provide a valid 'nscf' calculation.")
    if flag(nscf, :nosym) != true
        print && (@info "'nosym' flag was not set in the nscf calculation.\n
                         If this was not intended please set it and rerun the nscf calculation.\n
                         This generally gives errors because of omitted kpoints, needed for pw2wannier90.x")
    end

    setprojections!(job, projections_...)
    nbnd = nprojections(job.structure)
    print && (@info "num_bands=$nbnd (inferred from provided projections).")

    wanflags = SymAnyDict(wanflags)
    wanflags[:dis_win_min], wanflags[:dis_froz_min], wanflags[:dis_froz_max], wanflags[:dis_win_max] = wanenergyranges(Emin, nbnd, bands, Epad)

    wanflags[:num_bands] = length(bands)
    wanflags[:num_wann]  = nbnd
    kpoints = data(nscf, :k_points).data
    wanflags[:mp_grid] = kakbkc(kpoints)
    wanflags[:preprocess] = true
    print && (@info "mp_grid=$(join(wanflags[:mp_grid]," ")) (inferred from nscf input).")

    kdata = InputData(:kpoints, :none, [k[1:3] for k in kpoints])

    for (pw2wanfil, wanfil) in zip(pw2wannames, wannames)
        push!(job, DFInput{Wannier90}(wanfil, job.local_dir, copy(wanflags), [kdata], [Exec(), wanexec], true))
    end

    setfls!(job, name, flags...) = setflags!(job, name, flags..., print=false)
    if spin
        setfls!(job, "wanup", :spin => "up")
        setfls!(job, "wandn", :spin => "down")
    end
    return job
end

"""
    addwancalc!(job::DFJob, nscf::DFInput, projwfc::DFInput, threshold::Real, projections...; kwargs...)

Adds a wannier calculation to the job, but instead of passing Emin manually, the output of a projwfc.x run
can be used together with a `threshold` to determine the minimum energy such that the contribution of the
projections to the DOS is above the `threshold`.
"""
function addwancalc!(job::DFJob, nscf::DFInput, projwfc::DFInput, threshold::Real, projections::Pair...; kwargs...)
    @assert hasoutfile(projwfc) @error "Please provide a projwfc Input that has an output file."
    Emin = Emin_from_projwfc(job, outpath(projwfc), threshold, projections...)
    addwancalc!(job, nscf, Emin, projections...; kwargs...)
end

addwancalc!(job::DFJob, nscf_name::String, Emin::Real, projections::Pair...; kwargs...) =
    addwancalc!(job, input(job, nscf_name), Emin, projections...; kwargs...)

addwancalc!(job::DFJob, nscf_name::String, projwfc_name::String, threshold::Real, projections::Pair...; kwargs...) =
    addwancalc!(job, input(job, nscf_name), input(job, projwfc_name), threshold, projections...; kwargs...)


"Automatically calculates and sets the wannier energies. This uses the projections, `Emin` and the bands to infer the other limits.\n`Epad` allows one to specify the padding around the inner and outer energy windows"
function setwanenergies!(job::DFJob, bands, Emin::Real; Epad=5.0, print=true)
    wancalcs = filter(x -> package(x) == Wannier90, job.inputs)
    @assert length(wancalcs) != 0 error("Job ($(job.name)) has no Wannier90 calculations, nothing todo.")
    nbnd = sum([sum(orbsize.(t)) for  t in projections(job)])
    print && (@info "num_bands=$nbnd (inferred from provided projections).")
    winmin, frozmin, frozmax, winmax = wanenergyranges(Emin, nbnd, bands, Epad)
    map(x->setflags!(x, :dis_win_min => winmin, :dis_froz_min => frozmin, :dis_froz_max => frozmax, :dis_win_max => winmax, :num_wann => nbnd, :num_bands=>length(bands); print=false), wancalcs)
    return job
end

#--------------- Interacting with the Structure inside the DFJob ---------------#
"Returns the ith atom with id `atsym`."
atom(job::DFJob, atsym::Symbol, i=1) = filter(x -> x.id == atsym, atoms(job))[i]

"""
    atoms(job::DFJob)

Returns a list the atoms in the structure.
"""
atoms(job::DFJob) = atoms(job.structure)

"""
    setatoms!(job::DFJob, atoms::Dict{Symbol,<:Array{<:Point3,1}}, pseudo_setname=nothing, pseudospecifier=nothing, option=:angstrom)

Sets the data data with atomic positions to the new one. This is done for all calculations in the job that have that data.
If default pseudopotentials are defined, a set can be specified, together with a fuzzy that distinguishes between the possible multiple pseudo strings in the pseudo set.
These pseudospotentials are then set in all the calculations that need it.
All flags which specify the number of atoms inside the calculation also gets set to the correct value.
"""
function setatoms!(job::DFJob, atoms::Vector{<:AbstractAtom}; pseudoset=nothing, pseudospecifier="")
    job.structure.atoms = atoms
    pseudoset!=nothing && setpseudos!(job, pseudoset, pseudospecifier)
    return job
end

#automatically sets the cell parameters for the entire job, implement others
"""
    setcell!(job::DFJob, cell_::Mat3)

sets the cell parameters of the structure in the job.
"""
function setcell!(job::DFJob, cell_::Mat3)
    job.structure.cell = cell_
    return job
end


"sets the pseudopotentials to the specified one in the default pseudoset."
function setpseudos!(job::DFJob, set, specifier="")
    setpseudos!(job.structure, set, specifier)
    dir = getdefault_pseudodir(set)
    dir != nothing && setflags!(job, :pseudo_dir => "$dir", print=false)
    return job
end

"sets the pseudopotentials to the specified one in the default pseudoset."
function setpseudos!(job::DFJob, pseudodir, at_pseudos::Pair{Symbol, String}...)
    setpseudos!(job.structure, at_pseudos...)
    setflags!(job, :pseudo_dir => "$pseudodir", print=false)
    return job
end

"Returns the projections inside the job for the specified `i`th atom in the job with id `atsym`."
projections(job::DFJob, atsym::Symbol, i=1) = projections(atom(job, atsym, i))
"Returns all the projections inside the job."
projections(job::DFJob) = projections.(atoms(job))

"""
sets the projections of the specified atoms inside the job structure.
"""
setprojections!(job::DFJob, projections...) =
    setprojections!(job.structure, projections...)
