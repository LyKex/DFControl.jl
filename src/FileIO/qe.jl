import Base: parse
import ..Structures: hubbard_type, element
import .FileIO: NeedleType
import Printf: @sprintf

function readoutput(c::Calculation{<:AbstractQE}, files...; kwargs...)
    return qe_parse_output(c, files...; kwargs...)
end

#this is all pretty hacky with regards to the new structure and atom api. can for sure be a lot better!
"Quantum espresso card option parser"
function cardoption(line)
    sline = split(line)
    if length(sline) < 2 && lowercase(sline[1]) == "k_points"
        return :tpiba
    else
        return Symbol(match(r"((?:[a-z][a-z0-9_-]*))", sline[2]).match)
    end
end

function qe_parse_time(str::AbstractString)
    s = findfirst(isequal('s'), str)
    ms = findfirst(isequal('.'), str)
    m = findfirst(isequal('m'), str)
    m = m === nothing ? 0 : m
    h = findfirst(isequal('h'), str)
    h = h === nothing ? 0 : h
    t = Millisecond(0)
    if s !== nothing
        t += Second(parse(Int, str[m+1:ms-1])) + Millisecond(parse(Int, str[ms+1:s-1]))
    end
    if m != 0
        t += Minute(parse(Int, str[h+1:m-1]))
    end
    if h != 0
        t += Hour(parse(Int, str[1:h-1]))
    end
    return t
end

function qe_parse_output(c::Calculation{<:AbstractQE}, files...; kwargs...)
    if Calculations.isprojwfc(c)
        return qe_parse_projwfc_output(files...)
    elseif Calculations.ishp(c)
        return qe_parse_hp_output(files...; kwargs...)
    elseif Calculations.ismd(c)
        return qe_parse_pwmd_output(files[1]; kwargs...)
    elseif Calculations.ispw(c)
        return qe_parse_pw_output(files[1]; kwargs...)
    end
end

function qe_parse_Hubbard(out, line, f)
    hub_block = parse_Hubbard_block(f)
    # for some reason Calculation{QE7_2} needs specification of the type compared to QE
    HubbardStateTuple = @NamedTuple{id::Int64,
                                    trace::@NamedTuple{up::Float64,down::Float64,
                                                       total::Float64},
                                    eigvals::@NamedTuple{up::Vector{Float64},
                                                         down::Vector{Float64}},
                                    eigvecs::@NamedTuple{up::Matrix{Float64},
                                                         down::Matrix{Float64}},
                                    occupations::@NamedTuple{up::Matrix{Float64},
                                                             down::Matrix{Float64}},
                                    magmom::Float64}
    if eltype(hub_block) != HubbardStateTuple
        @warn "Converting out[:Hubbard] to correct type", eltype(hub_block)
        hub_block = HubbardStateTuple.(hub_block)
        @warn "Converted", eltype(hub_block)
    end

    if !haskey(out, :Hubbard)
        out[:Hubbard] = [hub_block]
    else
        push!(out[:Hubbard], hub_block)
    end
end

function parse_Hubbard_block(f)
    # Each of these will have n Hubbard typ elements at the end
    ids = Int[]
    traces = []
    eigvals = []
    eigvec = []
    occupations = []
    magmoms = []
    line = readline(f)
    # We start with signalling it's noncolin, then if the first spin 1 is found
    # we change it to :up or :down. Otherwise we know it is just noncolin.
    cur_spin = :noncolin
    curid = 0
    while !isempty(line) && strip(line) != "--- exit write_ns ---"
        line = readline(f)
        if occursin("Tr[ns", line)
            line = replace(line, "-" => " -")
            curid += 1
            sline = split(line)
            push!(ids, curid)
            if occursin("up, down, total", line)
                push!(traces,
                      NamedTuple{(:up, :down, :total)}(parse.(Float64,
                                                              (sline[end-2], sline[end-1],
                                                               sline[end]))))
            else
                push!(traces, (total = parse(Float64, sline[end]),))
            end
        elseif occursin("moment", line)
            push!(magmoms, parse(Float64, split(line)[end]))
        elseif occursin("atomic mx, my, mz", line)
            push!(magmoms, parse.(Float64, split(line)[end-2:end]))
        elseif occursin("spin", lowercase(line))
            if parse(Int, line[end]) == 1
                cur_spin = :up
            else
                cur_spin = :down
            end
        elseif occursin("eigenvalues", line)
            if cur_spin == :up  # means first spin
                t = parse.(Float64, split(readline(f)))
                vs = (up = t, down = zeros(length(t)))
                push!(eigvals, vs)
                push!(eigvec,
                      (up = zeros(length(t), length(t)),
                       down = zeros(length(t), length(t))))
                push!(occupations,
                      (up = zeros(length(t), length(t)),
                       down = zeros(length(t), length(t))))
            elseif cur_spin == :down
                eigvals[curid].down .= parse.(Float64, split(readline(f)))
            else
                vs = parse.(Float64, split(readline(f)))
                push!(eigvals, vs)
                l = length(vs)
                push!(eigvec, zeros(l, l))
                push!(occupations, zeros(l, l))
            end
        elseif occursin("eigenvectors", line)
            v = cur_spin == :noncolin ? eigvec[curid] : eigvec[curid][cur_spin]
            for i in 1:size(v, 1)
                v[i, :] .= parse.(Float64, split(readline(f)))
            end
        elseif occursin("occupation matrix", line)
            v = cur_spin == :noncolin ? occupations[curid] : occupations[curid][cur_spin]
            for i in 1:size(v, 1)
                v[i, :] .= parse.(Float64, split(readline(f)))
            end
        end
    end
    if isempty(magmoms) && !isempty(occupations)
        magmoms = [0.0 for i in 1:length(occupations)]
    end
    return [(id = i, trace = t, eigvals = val,
             eigvecs = vec,
             occupations = occ, magmom = m)
            for (i, t, val, vec, occ, m) in
                zip(ids, traces, eigvals, eigvec, occupations, magmoms)]
end

function qe_parse_polarization(out, line, f)
    s_line = split(line)
    P      = parse(Float64, s_line[3])
    mod    = parse(Float64, s_line[5][1:end-1])
    readline(f)
    s_line             = parse.(Float64, split(readline(f))[6:2:10])
    out[:polarization] = Point3{Float64}(P * s_line[1], P * s_line[2], P * s_line[3])
    return out[:pol_mod] = mod
end

function qe_parse_lattice_parameter(out, line, f)
    out[:in_alat] = ustrip(uconvert(Ang, parse(Float64, split(line)[5]) * 1bohr))
    return out[:alat] = :crystal
end

function qe_parse_n_KS(out, line, f)
    return out[:n_KS_states] = parse(Int, split(line)[5])
end
function qe_parse_n_electrons(out, line, f)
    return out[:n_electrons] = round(Int, parse(Float64, split(line)[5]))
end

function qe_parse_crystal_axes(out, line, f)
    m = Mat3(reshape([parse.(Float64, split(readline(f))[4:6]);
                      parse.(Float64, split(readline(f))[4:6]);
                      parse.(Float64, split(readline(f))[4:6])], (3, 3))')
    out[:cell_parameters] = copy(m)
    return out[:in_cell] = m
end

function qe_parse_reciprocal_axes(out, line, f)
    cell_1 = parse.(Float64, split(readline(f))[4:6]) .* 2π / out[:in_alat]
    cell_2 = parse.(Float64, split(readline(f))[4:6]) .* 2π / out[:in_alat]
    cell_3 = parse.(Float64, split(readline(f))[4:6]) .* 2π / out[:in_alat]
    return out[:in_recip_cell] = Mat3([cell_1 cell_2 cell_3])
end
function qe_parse_atomic_species(out, line, f)
    if !haskey(out, :atsyms)
        line = readline(f)
        out[:atsyms] = Symbol[]
        while !isempty(line)
            push!(out[:atsyms], Symbol(strip_split(line)[1]))
            line = readline(f)
        end
    end
end

function qe_parse_nat(out, line, f)
    return out[:nat] = parse(Int, split(line)[end])
end

function qe_parse_crystal_positions(out, line, f)
    readline(f)
    readline(f)
    out[:in_cryst_positions] = Tuple{Symbol,Point3{Float64}}[] # in crystal coord
    for i in 1:out[:nat]
        sline = split(readline(f))
        push!(out[:in_cryst_positions],
              (Symbol(sline[2]),
               Point3(parse(Float64, sline[7]), parse(Float64, sline[8]),
                      parse(Float64, sline[9]))))
    end
end

function qe_parse_cart_positions(out, line, f)
    readline(f)
    readline(f)
    out[:in_cart_positions] = Tuple{Symbol,Point3{Float64}}[] # in crystal coord
    for i in 1:out[:nat]
        sline = split(readline(f))
        push!(out[:in_cart_positions],
              (Symbol(sline[2]),
               Point3(parse(Float64, sline[7]), parse(Float64, sline[8]),
                      parse(Float64, sline[9]))))
    end
end

function qe_parse_pseudo(out, line, f)
    !haskey(out, :pseudos) && (out[:pseudos] = Dict{Symbol,Pseudo}())
    pseudopath = readline(f) |> strip
    return out[:pseudos][Symbol(split(line)[5])] = Pseudo("", pseudopath, "")
end

function qe_parse_fermi(out, line, f)
    sline = split(line)
    if occursin("energy is", line)
        out[:fermi] = parse(Float64, sline[5])
    elseif occursin("up/dw", line)
        sline            = split(line)
        out[:fermi_up]   = parse(Float64, sline[7])
        out[:fermi_down] = parse(Float64, sline[8])
        out[:fermi]      = min(out[:fermi_down], out[:fermi_up])
    end
end

function qe_parse_highest_lowest(out, line, f)
    sline = split(line)
    if occursin("lowest", line)
        high = parse(Float64, sline[7])
        low = parse(Float64, sline[8])
        out[:fermi] = high
        out[:highest_occupied] = high
        out[:lowest_unoccupied] = low
    else
        out[:fermi] = parse(Float64, sline[5])
        out[:highest_occupied] = out[:fermi]
    end
end

function qe_parse_total_energy(out, line, f)
    if haskey(out, :total_energy)
        push!(out[:total_energy], parse(Float64, split(line)[end-1]))
    else
        out[:total_energy] = [parse(Float64, split(line)[end-1])]
    end
end

function qe_parse_constraint_energy(out, line, f)
    e = parse(Float64, split(line)[end-1])
    return push!(out, :constraint_energy, e)
end

function parse_k_line(line)
    line = replace(replace(line, ")" => " "), "(" => " ")
    splt = split(line)
    k1   = parse(Float64, splt[4])
    k2   = parse(Float64, splt[5])
    k3   = parse(Float64, splt[6])
    w    = parse(Float64, splt[end])
    return (v = Vec3(k1, k2, k3), w = w)
end

function qe_parse_k_cryst(out, line, f)
    if length(split(line)) == 2
        out[:k_cryst] = (v = Vec3{Float64}[], w = Float64[])
        line = readline(f)
        while line != "" && !occursin("--------", line)
            parsed = parse_k_line(line)
            push!(out[:k_cryst].v, parsed.v)
            push!(out[:k_cryst].w, parsed.w)
            line = readline(f)
        end
    end
end

function qe_parse_k_cart(out, line, f)
    if length(split(line)) == 5
        line = readline(f)
        alat = out[:in_alat]
        out[:k_cart] = (v = Vec3{typeof(2π / alat)}[], w = Float64[])
        while line != "" && !occursin("--------", line)
            tparse = parse_k_line(line)
            push!(out[:k_cart].v, tparse.v .* 2π / alat)
            push!(out[:k_cart].w, tparse.w)
            line = readline(f)
        end
    end
end

function qe_parse_k_eigvals(out, line, f)
    tmp = Float64[]
    readline(f)
    line = readline(f)
    while line != "" && !occursin("--------", line)
        reg = r"\d-\d"
        m = match(reg, line)
        if m !== nothing
            line = replace(line, "-" => " -")
        end
        append!(tmp, parse_line(Float64, line))
        line = readline(f)
    end
    if haskey(out, :k_eigvals)
        push!(out[:k_eigvals], tmp)
    else
        out[:k_eigvals] = [tmp]
    end
end

#! format: off
function qe_parse_cell_parameters(out, line, f)
    out[:alat]            = occursin("angstrom", line) ? :angstrom : parse(Float64, split(line)[end][1:end-1])
    out[:cell_parameters] = Mat3(reshape([parse.(Float64, split(readline(f)));
                                          parse.(Float64, split(readline(f)));
                                          parse.(Float64, split(readline(f)))], (3, 3))')
end
#! format: on

function qe_parse_atomic_positions(out, line, f)
    out[:pos_option] = cardoption(line)
    line = readline(f)
    atoms = Tuple{Symbol,Point3{Float64}}[]
    while length(atoms) < out[:nat]
        s_line = split(line)
        key    = Symbol(s_line[1])
        push!(atoms, (key, Point3(parse.(Float64, s_line[2:end])...)))
        line = readline(f)
    end
    return out[:atomic_positions] = atoms
end

function qe_parse_total_force(out, line, f)
    sline = split(line)
    force = parse(Float64, sline[4])
    scf_contrib = parse(Float64, sline[end])
    if !haskey(out, :total_force)
        out[:total_force] = [force]
    else
        push!(out[:total_force], force)
    end
    if !haskey(out, :scf_correction)
        out[:scf_correction] = [scf_contrib]
    else
        push!(out[:scf_correction], scf_contrib)
    end
end

function qe_parse_atomic_force(out, line, f)
    sline = split(line)
    out[:force_axes] = sline[5][2:end]
    readline(f)
    forces = Vec3{Float64}[]

    for i in 1:out[:nat]
        sline = split(readline(f))
        push!(forces, Vec3(parse.(Float64, sline[end-2:end])))
    end
    return out[:forces] = forces
end

function qe_parse_scf_iteration(out, line, f)
    sline = split(line)
    it = length(sline[2]) == 1 ? parse(Int, sline[3]) :
         sline[2][2:end] == "***" ? out[:scf_iteration][end] + 1 :
         parse(Int, sline[2][2:end])
    if !haskey(out, :scf_iteration)
        out[:scf_iteration] = [it]
    else
        push!(out[:scf_iteration], it)
    end
    if it == 1
        out[:scf_converged] = false
        haskey(out, :scf_steps) ? out[:scf_steps] += 1 : out[:scf_steps] = 1
    end
end

function qe_parse_colin_magmoms(out, line, f)
    key = :colin_mag_moments
    out[key] = Float64[]
    line = readline(f)
    while !isempty(line)
        push!(out[key], parse.(Float64, split(line)[end]))
        line = readline(f)
    end
end

function qe_parse_scf_accuracy(out, line, f)
    key = :accuracy
    acc = parse(Float64, split(line)[5])
    if haskey(out, key)
        push!(out[key], acc)
    else
        out[key] = [acc]
    end
end

function qe_parse_total_magnetization(out, line, f)
    key = :total_magnetization
    mag = parse(Float64, split(line)[end-2])
    if haskey(out, key)
        push!(out[key], mag)
    else
        out[key] = [mag]
    end
end

function qe_parse_magnetization(out, line, f)
    if !haskey(out, :magnetization)
        out[:magnetization] = Vec3{Float64}[]
    end
    atom_number = parse(Int, split(line)[3])
    readline(f)
    if length(out[:magnetization]) < atom_number
        push!(out[:magnetization], parse(Vec3{Float64}, split(readline(f))[3:5]))
    else
        out[:magnetization][atom_number] = parse(Vec3{Float64}, split(readline(f))[3:5])
    end
end

function qe_parse_timing(out, line, f)
    # Timing information is printed with a tree structure, thus
    # parent timing data should already be created when parsing
    # its children, except for "*** rountines"
    out[:timing] = TimingData[]
    curparent = ""
    egterg_prefix = ""
    while !occursin("PWSCF", line)
        isempty(line) && (line = strip(readline(f)); continue)
        sline = split(line)
        if line[end] == ':' # descent into call case
            curparent = String(sline[end][1:end-1])
        elseif sline[end] == "routines" # descent into call case
            curparent = sline[1] * " routines"
            # data will be filled during cleanup
            td = TimingData(curparent, Dates.CompoundPeriod(),
                            Dates.CompoundPeriod(), 0, TimingData[])
            push!(out[:timing], td)
        elseif length(sline) == 9 # normal call
            td = TimingData(String(sline[1]), qe_parse_time(sline[3]),
                            qe_parse_time(sline[5]), parse(Int, sline[8]),
                            TimingData[])
            push!(out[:timing], td)
            if !isempty(curparent) # Child case
                if curparent[1] == '*'
                    if isempty(egterg_prefix)
                        egterg_prefix = td.name[1]
                    end
                    curparent = replace(curparent, '*' => egterg_prefix)
                    parent = getfirst(x -> x.name == curparent, out[:timing])
                    curparent = replace(curparent, egterg_prefix => '*')
                else
                    parent = getfirst(x -> x.name == curparent, out[:timing])
                end
                push!(parent.children, td)
            end
        end
        line = strip(readline(f))
    end
    sline = split(line)
    push!(out[:timing],
          TimingData("PWSCF", qe_parse_time(sline[3]), qe_parse_time(sline[5]),
                     1, TimingData[]))
    # cleanup
    for td in out[:timing]
        id = findfirst(x -> x == ':', td.name)
        td.name = id !== nothing ? td.name[id+1:end] : td.name
        if isempty(td.cpu.periods) && !isempty(td.children)
            td.cpu = sum(c -> c.cpu, td.children)
            td.wall = sum(c -> c.wall, td.children)
            td.calls = sum(c -> c.calls, td.children)
        end
    end
end

function qe_parse_starting_magnetization(out, line, f)
    readline(f)
    out[:starting_magnetization] = Dict{Symbol,Vec3}()
    line = readline(f)
    while !isempty(line)
        sline = split(line)
        atsym = Symbol(sline[1])
        mag = parse.(Float64, sline[2:end])
        out[:starting_magnetization][atsym] = length(mag) == 1 ? Vec3(0.0, 0.0, mag[1]) :
                                              Vec3(mag...)
        line = readline(f)
    end
end

function qe_parse_starting_simplified_dftu(out, line, f)
    # Simplified LDA+U calculation (l_max = 2) with parameters (eV):
    #  atomic species    L          U    alpha       J0     beta
    #     Ni             2     4.0000   0.0000   0.0000   0.0000
    #     Ni1            2     4.0000   0.0000   0.0000   0.0000
    # assumes default hubbard manifold in pre qe7.2
    @warn "Parsing Hubbard parameters from pre qe7.2 output!"
    readline(f)
    out[:starting_simplified_dftu] = Dict{Symbol,DFTU}()
    line = readline(f)
    while !isempty(line)
        sline = split(line)
        atsym = Symbol(sline[1])
        L = parse(Int, sline[2])
        u, alpha, j0, beta = parse.(Float64, sline[3:6])
        int2l = ["s", "p", "d", "f", "g"]
        m = "$atsym-$(L+1)$(int2l[L+1])"
        if iszero(j0)
            types = ["U"]
            manifolds = [m]
            values = [u]
        else
            types = ["U", "J0"]
            manifolds = fill(m, 2)
            values = [u, j0]
        end
        dftu = DFTU(; l = L,
                    types = types,
                    values = values,
                    manifolds = manifolds,
                    α = alpha,
                    beta = beta)
        out[:starting_simplified_dftu][atsym] = dftu

        line = readline(f)
    end
end

function qe_parse_Hubbard_energy(out, line, f)
    sline = split(line)
    val = sline[3] == "=" ? parse(Float64, sline[4]) : parse(Float64, sline[3])
    if !haskey(out, :Hubbard_energy)
        out[:Hubbard_energy] = [val]
    else
        push!(out[:Hubbard_energy], val)
    end
end

"""
    parsing Hubbard values from output
"""
function qe_parse_Hubbard_values(out, line, f)
    # to properly parse this block, need to understand how the supercell is
    # constructed in qe to match atom id with atom labels
    # TODO: for now parsing only U
    hubbard_values = Dict{Int,Tuple{String,Float64}}()
    line = readline(f)
    while !(isempty(line) || eof(f))
        sline = split(line)
        isempty(sline) && break
        atom_id = parse(Int, sline[1])
        value = parse(Float64, sline[6])
        if sline[1] == sline[2] && value != 0.0
            hubbard_values[atom_id] = ("U", value)
        end
        line = readline(f)
    end
    return out[:Hubbard_values] = hubbard_values
end

function qe_parse_Hubbard_values_new(out, line, f)
    @warn "Preliminary implementation of Hubbard values parsing from pw output"
    #  Hubbard projectors: ortho-atomic
    #  Hubbard parameters of DFT+U (Dudarev formulation) in eV:
    #  U(Ni-3d)  =  4.0000
    #  U(Ni1-3d) =  4.0000
    for i in 1:2
        line = strip(readline(f))
    end
    dftus = Dict{Symbol,DFTU}()
    rx = r"(\w)\((.+)\)\s*=\s*(\d+\.\d+)"
    lsyms = Dict{Char,Int}('s' => 0, 'p' => 1, 'd' => 2, 'f' => 3, 'g' => 4)
    while !isempty(line)
        @debug "pasrsing hubbard: $line"
        m = match(rx, line)
        type, manifold, value = m.captures
        atsym = Symbol(split(manifold, "-")[1])
        l = lsyms[manifold[end]]
        dftu = DFTU(; l = l, types = [type],
                    values = [parse(Float64, value)],
                    manifolds = [manifold])
        dftus[atsym] = dftu
        line = strip(readline(f))
    end

    return out[:hubbard_block] = dftus
end

const QE_PW_PARSE_FUNCTIONS::Vector{Pair{NeedleType,Any}} = ["C/m^2" => qe_parse_polarization,
                                                             "lattice parameter" => qe_parse_lattice_parameter,
                                                             "number of Kohn-Sham states" => qe_parse_n_KS,
                                                             "number of electrons" => qe_parse_n_electrons,
                                                             "crystal axes" => qe_parse_crystal_axes,
                                                             "EXX-fraction" => (x, y, z) -> x[:hybrid] = true,
                                                             "EXX self-consistency reached" => (x, y, z) -> x[:hybrid_converged] = true,
                                                             "reciprocal axes" => qe_parse_reciprocal_axes,
                                                             "atomic species   valence    mass" => qe_parse_atomic_species,
                                                             "number of atoms/cell" => qe_parse_nat,
                                                             "Crystallographic axes" => qe_parse_crystal_positions,
                                                             "Cartesian axes" => qe_parse_cart_positions,
                                                             "PseudoPot" => qe_parse_pseudo,
                                                             "the Fermi energy is" => qe_parse_fermi,
                                                             "highest occupied" => qe_parse_highest_lowest,
                                                             "total energy  " => qe_parse_total_energy,
                                                             "SPIN UP" => (x, y, z) -> x[:colincalc] = true,
                                                             "cryst." => qe_parse_k_cryst,
                                                             "cart." => qe_parse_k_cart,
                                                             "bands (ev)" => qe_parse_k_eigvals,
                                                             "End of self-consistent" => (x, y, z) -> haskey(x,
                                                                                                             :k_eigvals) &&
                                                                 empty!(x[:k_eigvals]),
                                                             "End of band structure" => (x, y, z) -> haskey(x,
                                                                                                            :k_eigvals) &&
                                                                 empty!(x[:k_eigvals]),
                                                             "CELL_PARAMETERS (" => qe_parse_cell_parameters,
                                                             "ATOMIC_POSITIONS (" => qe_parse_atomic_positions,
                                                             "Total force" => qe_parse_total_force,
                                                             "Forces acting on atoms" => qe_parse_atomic_force,
                                                             "iteration #" => qe_parse_scf_iteration,
                                                             "Magnetic moment per site" => qe_parse_colin_magmoms,
                                                             "estimated scf accuracy" => qe_parse_scf_accuracy,
                                                             "total magnetization" => qe_parse_total_magnetization,
                                                             "convergence has been" => (x, y, z) -> x[:scf_converged] = true,
                                                             "Begin final coordinates" => (x, y, z) -> x[:converged] = true,
                                                             "atom number" => qe_parse_magnetization,
                                                             "--- enter write_ns ---" => qe_parse_Hubbard,
                                                             "=== HUBBARD OCCUPATIONS ===" => qe_parse_Hubbard,
                                                             "Hubbard energy" => qe_parse_Hubbard_energy,
                                                             "HUBBARD ENERGY" => qe_parse_Hubbard_energy,
                                                             "stan-stan stan-bac" => qe_parse_Hubbard_values,
                                                             "Hubbard projectors:" => qe_parse_Hubbard_values_new,
                                                             "init_run" => qe_parse_timing,
                                                             "Starting magnetic structure" => qe_parse_starting_magnetization,
                                                             "Simplified LDA+U calculation" => qe_parse_starting_simplified_dftu,
                                                             "JOB DONE." => (x, y, z) -> x[:finished] = true,
                                                             "CONSTRAINTS ENERGY" => qe_parse_constraint_energy]

"""
    qe_parse_pw_output(str::String; parse_funcs::Vector{Pair{String}}=Pair{String,<:Function}[])

Reads a pw quantum espresso calculation, returns a dictionary with all found data in the file.
The additional `parse_funcs` should be of the form:
`func(out_dict, line, f)` with `f` the file. 
"""
function qe_parse_pw_output(str;
                            parse_funcs::Vector{<:Pair} = Pair{String}[])
    out = parse_file(str, QE_PW_PARSE_FUNCTIONS; extra_parse_funcs = parse_funcs)
    if !haskey(out, :finished)
        out[:finished] = false
    end
    if haskey(out, :in_alat) &&
       haskey(out, :in_cell) &&
       (haskey(out, :in_cart_positions) || haskey(out, :in_cryst_positions))
        cell_data = InputData(:cell_parameters, :alat, pop!(out, :in_cell))
        if haskey(out, :in_cryst_positions)
            atoms_data = InputData(:atomic_positions, :crystal,
                                   pop!(out, :in_cryst_positions))
        else
            atoms_data = InputData(:atomic_positions, :alat, pop!(out, :in_cart_positions))
        end
        pseudo_data = InputData(:atomic_species, :none, out[:pseudos])
        tmp_flags = Dict{Symbol,Any}(:ibrav => 0)
        tmp_flags[:A] = out[:in_alat]
        if haskey(out, :Hubbard_values)
            tmp_flags[:Hubbard_values] = out[:Hubbard_values]
        end
        # TODO: parsing Hubbard block
        hubbard_block = get!(out, :hubbard_block, nothing)
        out[:initial_structure] = extract_structure!(tmp_flags, cell_data,
                                                     out[:atsyms], atoms_data, pseudo_data,
                                                     hubbard_block)
        # Add starting mag and DFTU
        if haskey(out, :starting_magnetization)
            for (atsym, mag) in out[:starting_magnetization]
                for a in out[:initial_structure][atsym]
                    a.magnetization = mag
                end
            end
        end
        if haskey(out, :starting_simplified_dftu)
            dftus = out[:starting_simplified_dftu]
            for (atsym, dftu) in dftus
                for a in out[:initial_structure][atsym]
                    a.dftu = dftu
                end
            end
        end
    end

    # Process final Structure
    if haskey(out, :pos_option) && haskey(out, :alat) && haskey(out, :cell_parameters)
        pseudo_data = InputData(:atomic_species, :none, out[:pseudos])
        tmp_flags = Dict{Symbol,Any}(:ibrav => 0)
        if haskey(out, :alat)
            tmp_flags[:A] = out[:alat] == :angstrom ? 1.0 :
                            (out[:alat] == :crystal ? out[:in_alat] :
                             uconvert(Ang, out[:alat] * 1bohr))
        else
            tmp_flags[:A] = 1.0
        end
        cell_data = InputData(:cell_parameters, :alat, out[:cell_parameters])
        atoms_data = InputData(:atomic_positions, out[:pos_option], out[:atomic_positions])
        #TODO: Hubbard
        if haskey(out, :Hubbard_values)
            tmp_flags[:Hubbard_values] = out[:Hubbard_values]
        end
        hubbard_block = get!(out, :hubbard_block, nothing)
        out[:final_structure] = extract_structure!(tmp_flags, cell_data,
                                                   out[:atsyms], atoms_data, pseudo_data,
                                                   hubbard_block)
        # Add starting mag and DFTU
        if haskey(out, :starting_magnetization)
            for (atsym, mag) in out[:starting_magnetization]
                for a in out[:initial_structure][atsym]
                    a.magnetization = mag
                end
            end
        end
        if haskey(out, :starting_simplified_dftu)
            dftus = out[:starting_simplified_dftu]
            for (atsym, dftu) in dftus
                for a in out[:initial_structure][atsym]
                    a.dftu = dftu
                end
            end
        end
    end

    #process bands
    if haskey(out, :k_eigvals) &&
       !isempty(out[:k_eigvals]) &&
       haskey(out, :k_cart) &&
       haskey(out, :in_recip_cell)
        if !haskey(out, :k_cryst) && haskey(out, :in_recip_cell) && haskey(out, :k_cart)
            out[:k_cryst] = (v = (out[:in_recip_cell]^-1,) .* out[:k_cart].v,
                             w = out[:k_cart].w)
        end
        if get(out, :colincalc, false)
            out[:bands] = (up = [Band(out[:k_cart].v, out[:k_cryst].v,
                                      zeros(length(out[:k_cart].v)))
                                 for i in 1:length(out[:k_eigvals][1])],
                           down = [Band(out[:k_cart].v, out[:k_cryst].v,
                                        zeros(length(out[:k_cart].v)))
                                   for i in 1:length(out[:k_eigvals][1])])
        else
            out[:bands] = [Band(out[:k_cart].v, out[:k_cryst].v,
                                zeros(length(out[:k_cart].v)))
                           for i in 1:length(out[:k_eigvals][1])]
        end
        for i in 1:length(out[:k_eigvals])
            for i1 in 1:length(out[:k_eigvals][i])
                if get(out, :colincalc, false)
                    if i <= length(out[:k_cart].v)
                        out[:bands].up[i1].eigvals[i] = out[:k_eigvals][i][i1]
                    else
                        out[:bands].down[i1].eigvals[i-length(out[:k_cart].v)] = out[:k_eigvals][i][i1]
                    end
                else
                    out[:bands][i1].eigvals[i] = out[:k_eigvals][i][i1]
                end
            end
        end
    end
    if haskey(out, :hybrid)
        out[:converged] = get(out, :hybrid_converged, false)
    elseif get(out, :converged, false)
        out[:converged] = true
    else
        out[:converged] = get(out, :scf_converged, false) &&
                          length(get(out, :total_force, Float64[])) < 2
    end
    if haskey(out, :scf_iteration)
        out[:n_scf] = length(findall(i -> out[:scf_iteration][i+1] < out[:scf_iteration][i],
                                     1:length(out[:scf_iteration])-1))
    end
    for f in
        (:in_cart_positions, :in_alat, :in_cryst_positions, :alat, :pos_option, :pseudos,
         :cell_parameters, :in_recip_cell, :scf_converged, :atsyms, :nat, :k_eigvals,
         :k_cryst, :k_cart, :starting_simplified_dftu, :starting_magnetization)
        pop!(out, f, nothing)
    end

    # #  If the main `:Hubbard` vector is `Vector{Any}`, re-construct it to enforce type
    # if eltype(out[:Hubbard]) == Any
    #     @warn "Converting main :Hubbard vector to correct type"
    #     out[:Hubbard] = convert(Vector{Vector{HubbardStateTuple}}, out[:Hubbard])
    # end

    return out
end

########################################
#          parsing pw md               #
########################################
function Base.push!(out::Dict, k::Symbol, v)
    if haskey(out, k)
        push!(out[k], v)
    else
        out[k] = [v]
    end
end

# function qe_md_parse_total_energy(out, line, f)
#     sline = split(line)
#     e = parse(Float64, sline[5])
#     # TODO what happens if one time step does not converge?
#     # will pw continue?
#     # if yes, then this func needs consider that and take the last
#     # total energy from scf; if not, the out[:scf_steps] and out[:scf_converged]
#     # is kind of unnecessary
#     push!(out, :total_energy, e)
# end

function qe_md_parse_total_energy(out, line, f)
    step = out[:step]
    if haskey(out[:total_energy], step)
        push!(out[:total_energy][step], parse(Float64, split(line)[end-1]))
    else
        out[:total_energy][step] = [parse(Float64, split(line)[end-1])]
    end
end

function qe_md_parse_step(out, line, f)
    cur_step = parse(Int, split(line)[end])
    prev_step = get!(out, :step, 0)
    if cur_step > prev_step
        out[:step] = cur_step
    else
        error("md iteration parsing error")
    end
end

function qe_md_parse_convergence(out, line, f)
    return push!(out, :scf_convergence, parse(Float64, split(line)[end-1]))
end

function qe_md_parse_kinetic(out, line, f)
    push!(out, :kinetic, parse(Float64, split(line)[end-1]))

    line = readline(f)
    push!(out, :temperature, parse(Float64, split(line)[end-1]))

    line = readline(f)
    return push!(out, :md_total_energy, parse(Float64, split(line)[end-1]))
end

function qe_md_parse_atomic_positions(out, line, f)
    out[:pos_option] = cardoption(line)
    line = readline(f)
    atoms = Tuple{Symbol,Point3{Float64}}[]
    while length(atoms) < out[:nat]
        s_line = split(line)
        key    = Symbol(s_line[1])
        push!(atoms, (key, Point3(parse.(Float64, s_line[2:end])...)))
        line = readline(f)
    end
    return push!(out, :atomic_positions, atoms)
end

function qe_md_parse_highest_lowest(out, line, f)
    sline = split(line)
    high = parse(Float64, sline[end-1])
    low = parse(Float64, sline[end])
    push!(out, :fermi, high)
    push!(out, :highest_occupied, high)
    return push!(out, :lowest_occupied, low)
end

function qe_md_parse_atomic_force(out, line, f)
    sline = split(line)
    out[:force_axes] = sline[5][2:end]

    readline(f)
    forces = Vec3{Float64}[]

    for i in 1:out[:nat]
        sline = split(readline(f))
        push!(forces, Vec3(parse.(Float64, sline[end-2:end])))
    end
    return push!(out, :forces, forces)
end

function qe_md_parse_total_magnetization(out, line, f)
    for i in 1:3
        line = readline(f)
    end
    return push!(out, :total_magnetization, parse(Float64, split(line)[end-2]))
end

function qe_md_parse_timestep(out, line, f)
    return out[:time_step] = parse(Float64, split(line)[end-1])
end

"""
    Parse scf iterations required for each time step, store in `out[:scf_steps]`.
    Note that not scf may not converge.
"""
function qe_md_parse_iteration(out, line, f)
    sline = split(line)
    it = length(sline[2]) == 1 ? parse(Int, sline[3]) :
         sline[2][2:end] == "***" ? out[:scf_iteration][end] + 1 :
         parse(Int, sline[2][2:end])
    if it == 1
        # not first time step
        if haskey(out, :scf_iteration)
            push!(out, :scf_steps, out[:scf_iteration])
        end
        push!(out, :scf_converged, false) # => will be set to true if convergence
    end
    return out[:scf_iteration] = it
end

function qe_md_parse_finish(out, line, f)
    # push scf steps for last time step
    push!(out[:scf_steps], out[:scf_iteration])
    # delete temperary value
    return delete!(out, :scf_iteration)
end

function qe_md_parse_converge(out, line, f)
    # final total mag
    qe_md_parse_total_magnetization(out, line, f)
    # final total energy
    qe_md_parse_total_energy(out, line, f)
    # convergence
    return out[:scf_converged][end] = true
end

const QE_MD_PARSE_FUNCTIONS::Vector{Pair{NeedleType,Any}} = ["Entering Dynamics" => qe_md_parse_step,
                                                             "Time step"         => qe_md_parse_timestep,
                                                             # "convergence has been"                  => qe_md_parse_convergence,
                                                             "kinetic energy"                   => qe_md_parse_kinetic,
                                                             "ATOMIC_POSITIONS"                 => qe_md_parse_atomic_positions,
                                                             "JOB DONE."                        => (x, y, z) -> x[:finished] = true,
                                                             "lattice parameter"                => qe_parse_lattice_parameter,
                                                             "number of Kohn-Sham states"       => qe_parse_n_KS,
                                                             "number of electrons"              => qe_parse_n_electrons,
                                                             "crystal axes"                     => qe_parse_crystal_axes,
                                                             "reciprocal axes"                  => qe_parse_reciprocal_axes,
                                                             "atomic species   valence    mass" => qe_parse_atomic_species,
                                                             "number of atoms/cell"             => qe_parse_nat,
                                                             "Crystallographic axes"            => qe_parse_crystal_positions,
                                                             "Cartesian axes"                   => qe_parse_cart_positions,
                                                             "cryst."                           => qe_parse_k_cryst,
                                                             "cart."                            => qe_parse_k_cart,
                                                             "PseudoPot"                        => qe_parse_pseudo,
                                                             # "the Fermi energy is"                 => qe_md_parse_fermi, # TODO list of Fermi level?
                                                             "highest occupied, lowest unoccupied " => qe_md_parse_highest_lowest,
                                                             "SPIN UP"                              => (x, y, z) -> x[:colincalc] = true,
                                                             "Forces acting on atoms"               => qe_md_parse_atomic_force,
                                                             "!    total energy"                    => qe_md_parse_converge,
                                                             # "bands (ev)"                          => qe_parse_k_eigvals,
                                                             # "End of self-consistent"              => (x, y, z) -> haskey(x,:k_eigvals) && empty!(x[:k_eigvals]),
                                                             # "End of band structure"               => (x, y, z) -> haskey(x, :k_eigvals) && empty!(x[:k_eigvals]),
                                                             # "CELL_PARAMETERS ("                   => qe_parse_cell_parameters,  # TODO check vc-relax
                                                             # "Total force"                         => qe_parse_total_force,
                                                             "iteration #"                           => qe_md_parse_iteration,
                                                             "End of molecular dynamics calculation" => qe_md_parse_finish,
                                                             # "Magnetic moment per site"            => qe_parse_colin_magmoms,
                                                             "estimated scf accuracy" => qe_parse_scf_accuracy,
                                                             # "Begin final coordinates"             => (x, y, z) -> x[:converged] = true,
                                                             # "atom number"                         => qe_parse_magnetization,
                                                             "--- enter write_ns ---" => qe_parse_Hubbard,
                                                             "== HUBBARD OCCUPATIONS ==" => qe_parse_Hubbard,
                                                             "Hubbard energy" => qe_parse_Hubbard_energy,
                                                             "HUBBARD ENERGY" => qe_parse_Hubbard_energy,
                                                             # pre qe7.2
                                                             "stan-stan stan-bac" => qe_parse_Hubbard_values,
                                                             # post qe7.2
                                                             "Hubbard projectors" => qe_parse_Hubbard_values_new,
                                                             "init_run" => qe_parse_timing,
                                                             "Starting magnetic structure" => qe_parse_starting_magnetization,
                                                             "Simplified LDA+U calculation" => qe_parse_starting_simplified_dftu]

"""
    qe_parse_pwmd_output(str::String; parse_funcs::Vector{Pair{String}}=Pair{String,<:Function}[])

Reads a pw quantum espresso md output file, returns a dictionary with parsed data.
Default parsing functions are defined in QE_MD_PARSE_FUNCTIONS, additional `parse_funcs` should be
of the form: `func(out_dict, line, f)` with `f` the file and `line` is the line in file matched by
given needle.
Entries in the output dictionary includes,
`finished`: `true` if the job terminates normally, `false` otherwise
`time_step`: MD time step in fs
`forces`: forces for each MD step in Ry/au using cartesian axes
`atomic_positions`: atomic positions of each MD step
"""
function qe_parse_pwmd_output(str; parse_funcs::Vector{<:Pair} = Pair{String,Function}[])
    out = Dict{Symbol,Any}(:step => 0)
    out = parse_file(str, QE_MD_PARSE_FUNCTIONS; extra_parse_funcs = parse_funcs)
    if !haskey(out, :finished)
        out[:finished] = false
    end
    return out
end

"""
    qe_parse_kpdos(file,column=1;fermi=0)

Reads the k_resolved partial density of states from a Quantum Espresso projwfc output file.
Only use this if the flag kresolveddos=true in the projwfc calculation file!! The returned matrix can be readily plotted using heatmap() from Plots.jl!
Optional calculation: column = 1 (column of the output, 1 = first column after ik and E)
fermi  = 0 (possible fermi offset of the read energy values)
Return:         Array{Float64,2}(length(k_points),length(energies)) ,
(ytickvals,yticks)
"""
function qe_parse_kpdos(file, column = 1; fermi = 0)
    read_tmp = readdlm(file, Float64; comments = true)
    zmat     = zeros(typeof(read_tmp[1]), Int64(read_tmp[end, 1]), div(size(read_tmp)[1], Int64(read_tmp[end, 1])))
    for i1 in 1:size(zmat)[1]
        for i2 in 1:size(zmat)[2]
            zmat[i1, i2] = read_tmp[size(zmat)[2]*(i1-1)+i2, 2+column]
        end
    end

    yticks    = collect(Int(div(read_tmp[1, 2] - fermi, 1)):1:Int(div(read_tmp[end, 2] - fermi, 1)))
    ytickvals = [findfirst(x -> norm(yticks[1] + fermi - x) <= 0.1, read_tmp[:, 2])]
    for (i, tick) in enumerate(yticks[2:end])
        push!(ytickvals,
              findnext(x -> norm(tick + fermi - x) <= 0.1, read_tmp[:, 2], ytickvals[i]))
    end

    return unique(read_tmp[:, 2]), zmat', ytickvals, yticks
end

"""
    qe_parse_pdos(file)

Reads partial dos file.
"""
function qe_parse_pdos(file)
    try
        read_tmp = readdlm(file; skipstart = 1)
        energies = read_tmp[:, 1]
        values   = read_tmp[:, 2:end]

        return energies, values
    catch
        @warn "Pdos file was empty: $file"
        return Float64[], Matrix{Float64}(undef, 0, 0)
    end
end

function qe_parse_projwfc_output(files...)
    out = Dict{Symbol,Any}()
    kresolved = occursin("ik", readline(files[1]))
    out[:states], out[:bands] = qe_parse_projwfc(files[1])
    tp = pdos(files[2:end], kresolved)
    if tp !== nothing
        out[:energies], out[:pdos] = tp
    end
    out[:finished] = !haskey(out, :enegies) || isempty(out[:energies]) ? false : true
    return out
end

function pdos(files, kresolved = false)
    dir = splitdir(files[1])[1]
    atfiles = filter(x -> occursin("atm", x), files)

    atsyms = Symbol.(unique(map(x -> x[findfirst("(", x)[1]+1:findfirst(")", x)[1]-1],
                                atfiles)))
    magnetic = (x -> occursin("ldosup", x) && occursin("ldosdw", x))(readline(files[1]))
    soc = occursin(".5", files[1])
    files = joinpath.((dir,), files)
    energies, = kresolved ? qe_parse_kpdos(files[1]) : qe_parse_pdos(files[1])
    if !isempty(energies)
        totdos = Dict{Symbol,Dict{Structures.Orbital,Array}}()
        for atsym in atsyms
            totdos[atsym] = Dict{Structures.Orbital,Array}()
            if kresolved
                for f in filter(x -> occursin("(" * string(atsym) * ")", x), files)
                    id1 = findlast("(", f) + 1
                    orb = soc ? Structures.orbital(f[id1, findnext("_", f, id1 + 1)-1]) :
                          Structures.orbital(f[id1, findnext(")", f, id1 + 1)-1])
                    if !haskey(totdos[atsym], orb)
                        totdos[atsym][orb] = magnetic && !soc ?
                                             zeros(size(energies, 1), 2) :
                                             zeros(size(energies, 1))
                    end
                    atdos = totdos[atsym][orb]
                    if magnetic && !occursin(".5", f)
                        tu = qe_parse_kpdos(f, 2)[2]
                        td = qe_parse_kpdos(f, 3)[2]
                        atdos[:, 1] .+= reduce(+, tu; dims = 2) ./ size(tu, 2)
                        atdos[:, 2] .+= reduce(+, td; dims = 2) ./ size(tu, 2)
                    else
                        t = qe_parse_kpdos(f, 1)[2]
                        atdos .+= (reshape(reduce(+, t; dims = 2), size(atdos, 1)) ./
                                   size(t, 2))
                    end
                end
            else
                for f in filter(x -> occursin("(" * string(atsym) * ")", x), files)
                    id1 = findlast("(", f)[1] + 1
                    orb = soc ? Structures.orbital(f[id1:findnext("_", f, id1 + 1)[1]-1]) :
                          Structures.orbital(f[id1:findnext(")", f, id1 + 1)[1]-1])
                    if !haskey(totdos[atsym], orb)
                        totdos[atsym][orb] = magnetic && !soc ?
                                             zeros(size(energies, 1), 2) :
                                             zeros(size(energies, 1))
                    end
                    atdos = totdos[atsym][orb]
                    if magnetic && !occursin(".5", f)
                        atdos .+= qe_parse_pdos(f)[2][:, 1:2]
                    else
                        atdos .+= qe_parse_pdos(f)[2][:, 1]
                    end
                end
            end
        end
        return (energies = energies, pdos = totdos)
    end
end

"""
    qe_parse_projwfc(filename::String)

Reads the output file of a projwfc.x calculation.
Each kpoint will have as many energy dos values as there are bands in the scf/nscf calculation that
generated the density upon which the projwfc.x was called.
Returns:
    states: [(:atom_id, :wfc_id, :j, :l, :m),...] where each j==0 for a non spin polarized calculation.
    kpdos : kpoint => [(:e, :ψ, :ψ²), ...] where ψ is the coefficient vector in terms of the states.
"""
function qe_parse_projwfc(filename)
    lines = readlines(filename) .|> strip

    i_prob_sizes = findfirst(x -> !isempty(x) && x[1:4] == "Prob", lines)

    natomwfc = 0
    nx       = 0
    nbnd     = 0
    nkstot   = 0
    npwx     = 0
    nkb      = 0
    if i_prob_sizes === nothing
        error("Version of QE too low, cannot parse projwfc output")
    end
    istart = findfirst(x -> x == "Atomic states used for projection", lines) + 2
    for i in i_prob_sizes+1:istart-3
        l = lines[i]
        if isempty(l)
            break
        end
        sline = split(l)
        v = parse(Int, sline[3])
        if sline[1] == "natomwfc"
            natomwfc = v
        elseif sline[1] == "nx"
            nx = v
        elseif sline[1] == "nbnd"
            nbnd = v
        elseif sline[1] == "nkstot"
            nkstot = v
        elseif sline[1] == "npwx"
            npwx = v
        elseif sline[1] == "nkb"
            nkb = v
        end
    end

    state_tuple = NamedTuple{(:atom_id, :wfc_id, :l, :j, :m),
                             Tuple{Int,Int,Float64,Float64,Float64}}
    states = state_tuple[]
    for i in 1:natomwfc
        l = replace_multiple(lines[i+istart], "(" => " ", ")" => " ", "," => "", "=" => " ",
                             ":" => "", "#" => " ") |> split
        if length(l) == 11 #spinpolarized
            push!(states,
                  state_tuple((parse.(Int, (l[4], l[7]))..., parse(Float64, l[9]), 0.0,
                               parse(Float64, l[11]))))
        else #not spin polarized
            push!(states,
                  state_tuple((parse.(Int, (l[4], l[7]))...,
                               parse.(Float64, (l[9], l[11], l[13]))...)))
        end
    end
    ETuple = NamedTuple{(:e, :ψ, :ψ²),Tuple{Float64,Vector{Float64},Float64}}
    kdos = Pair{Vec3{Float64},Vector{ETuple}}[]
    while length(kdos) < nkstot
        istart   = findnext(x -> occursin("k = ", x), lines, istart + 1)
        k        = Vec3(parse.(Float64, split(lines[istart])[3:end]))
        etuples  = ETuple[]
        istop_ψ  = istart - 1
        istart_ψ = istart
        while length(etuples) < nbnd
            eline    = replace_multiple(lines[istop_ψ+2], "=" => "", "(" => " ", ")" => " ")
            e        = parse(Float64, split(eline)[end-1])
            coeffs   = zeros(length(states))
            istart_ψ = findnext(x -> !isempty(x) && x[1:3] == "===", lines, istop_ψ + 1) + 1
            istop_ψ  = findnext(x -> !isempty(x) && x[2:4] == "psi", lines, istart_ψ) - 1
            for i in istart_ψ:istop_ψ
                l = replace_multiple(lines[i], "psi =" => " ", "*[#" => " ", "]+" => " ",
                                     "]" => " ") |>
                    strip |>
                    split
                for k in 1:2:length(l)
                    coeffs[parse(Int, l[k+1])] = parse(Float64, l[k])
                end
            end
            ψ² = parse(Float64, split(lines[istop_ψ+1])[end])
            push!(etuples, (e = e, ψ = coeffs, ψ² = ψ²))
        end
        push!(kdos, k => etuples)
    end
    nkstot = length(kdos)
    nbnd   = length(last(kdos[1]))
    bands  = [Band(fill(kdos[1][1], nkstot), fill(zero(Vec3{Float64}), nkstot), fill(0.0, nkstot), Dict{Symbol,Any}()) for i in 1:nbnd]
    for b in bands
        b.extra[:ψ]  = Vector{Vector{Float64}}(undef, nkstot)
        b.extra[:ψ²] = Vector{Float64}(undef, nkstot)
    end

    for (i, (k, energies)) in enumerate(kdos)
        for (ie, etuple) in enumerate(energies)
            bands[ie].k_points_cryst[i] = k
            bands[ie].k_points_cart[i]  = zero(Vec3{Float64})
            bands[ie].eigvals[i]        = etuple.e
            bands[ie].extra[:ψ][i]      = etuple.ψ
            bands[ie].extra[:ψ²][i]     = etuple.ψ²
        end
    end
    return states, bands
end

function qe_parse_pert_at(out, line, f)
    sline = split(line)
    if sline[1] == "Atom"
        nat = 1
    else
        nat = parse(Int, sline[3])
    end
    out[:pert_at] = []
    readline(f)
    for i in 1:nat
        sline = split(readline(f))
        push!(out[:pert_at],
              (name = Symbol(sline[2]),
               position = Point3(parse.(Float64, sline[end-3:end-1])...)))
    end
end

function qe_parse_Hubbard_U(out, line, f)
    out[:Hubbard_U] = []
    readline(f)
    readline(f)
    line = readline(f)
    while !isempty(line)
        sline = split(line)
        push!(out[:Hubbard_U],
              (orig_name = Symbol(sline[3]), new_name = Symbol(sline[6]),
               U = parse(Float64, sline[7])))
        line = readline(f)
    end
end

function qe_parse_HP_error(out, line, f)
    out[:error] = true
    while !occursin("E_Fermi", line)
        line = readline(f)
    end
    fermi_dos = parse(Float64, split(line)[end])
    return out[:fermi_dos] = fermi_dos
end

const QE_HP_PARSE_FUNCS = ["will be perturbed" => qe_parse_pert_at,
                           "Hubbard U parameters:" => qe_parse_Hubbard_U,
                           "WARNING: The Fermi energy shift is zero or too big!" => qe_parse_HP_error]

function qe_parse_hp_output(hp_file, hubbard_files...;
                            parse_funcs = Pair{String,<:Function}[])
    out = parse_file(hp_file, QE_HP_PARSE_FUNCS; extra_parse_funcs = parse_funcs)
    if !isempty(hubbard_files)
        parse_file(hubbard_files[1], QE_HP_PARSE_FUNCS; extra_parse_funcs = parse_funcs,
                   out = out)
    end
    return out
end

function alat(flags, pop = false)
    if haskey(flags, :A)
        a = pop ? pop!(flags, :A) : flags[:A]
        a *= 1Ang
    elseif haskey(flags, :celldm_1)
        a = pop ? pop!(flags, :celldm_1) : flags[:celldm_1]
        a *= 1bohr
    elseif haskey(flags, :celldm)
        a = pop ? pop!(flags, :celldm)[1] : flags[:celldm][1]
        a *= 1bohr
    else
        error("Cell option 'alat' was found, but no matching flag was set. \n
        The 'alat' has to  be specified through 'A' or 'celldm(1)'.")
    end
    return a
end

#TODO handle more fancy cells
function extract_cell!(flags, cell_block)
    @assert cell_block !== nothing
    a = 1.0 * Ang
    if cell_block.option == :alat
        a = alat(flags)
    elseif cell_block.option == :bohr
        a = 1 * bohr
    end
    return (a .* cell_block.data)'
end

"""
    parsing Hubbard U parameters prior to qe7.2 from qe input.
    To fully use Hubbard correction, use qe7.2 onwards where the input
    takes a dedicated Hubbard block.
"""
function maybe_parse_dftu(speciesid::Int, atsyms::AbstractVector{Symbol},
                          parsed_flags::Dict{Symbol,Any})
    @warn "Try parsing Hubbard U parameters using old syntax (prior to qe7.2)."
    if haskey(parsed_flags, :Hubbard_U) && !iszero(parsed_flags[:Hubbard_U][speciesid])
        @debug "Hubbard U for atom $speciesid: $(parsed_flags[:Hubbard_U][speciesid])"
        # TODO n and l is hardcoded according to default setting before qe7.2,
        # User can potential change manifolds by modifying source code which cannot be read from qe input
        # However, input file genereated from this will be correct since it is not used.
        el = atsyms[speciesid]
        el_pure = element(el).symbol
        manifold = "$el-$(ELEMENT_TO_N[el_pure])$(ELEMENT_TO_L[el_pure])"
        return DFTU(; types = ["U"], values = [parsed_flags[:Hubbard_U][speciesid]],
                    manifolds = [manifold])
    else
        return DFTU()
    end
end

degree2π(ang) = ang / 180 * π

function qe_magnetization(atid::Int, parsed_flags::Dict{Symbol,Any})
    θ = haskey(parsed_flags, :angle1) && length(parsed_flags[:angle1]) >= atid ?
        parsed_flags[:angle1][atid] : 0.0
    θ = degree2π(θ)
    ϕ = haskey(parsed_flags, :angle2) && length(parsed_flags[:angle2]) >= atid ?
        parsed_flags[:angle2][atid] : 0.0
    ϕ = degree2π(ϕ)

    start = haskey(parsed_flags, :starting_magnetization) &&
            length(parsed_flags[:starting_magnetization]) >= atid ?
            parsed_flags[:starting_magnetization][atid] : 0.0
    if start isa AbstractVector
        return Vec3{Float64}(start...)
    else
        return start * Vec3{Float64}(sin(θ) * cos(ϕ), sin(θ) * sin(ϕ), cos(θ))
    end
end

function extract_atoms!(parsed_flags, atsyms, atom_block, pseudo_block, hubbard_block,
                        cell::Mat3)
    atoms = Atom[]

    option = atom_block.option
    if option == :crystal || option == :crystal_sg
        primv = cell
        cell  = Mat3(Matrix(1.0I, 3, 3))
    elseif option == :alat
        primv = alat(parsed_flags, true) * Mat3(Matrix(1.0I, 3, 3))
    elseif option == :bohr
        primv = 1bohr .* Mat3(Matrix(1.0I, 3, 3))
    else
        primv = 1Ang .* Mat3(Matrix(1.0I, 3, 3))
    end
    for (atsym, pos) in atom_block.data
        if haskey(pseudo_block.data, atsym)
            pseudo = pseudo_block.data[atsym]
        else
            elkey = getfirst(x -> x != atsym &&
                                 Structures.element(x) == Structures.element(atsym),
                             keys(pseudo_block.data))
            pseudo = elkey !== nothing ? pseudo_block.data[elkey] : Pseudo("", "", "")
        end
        speciesid = findfirst(isequal(atsym), atsyms)

        push!(atoms,
              Atom(; name = atsym, element = Structures.element(atsym),
                   position_cart = primv * pos,
                   position_cryst = UnitfulAtomic.ustrip.(inv(cell) * pos),
                   pseudo = pseudo,
                   magnetization = qe_magnetization(speciesid, parsed_flags),
                   dftu = hubbard_block === nothing ?
                          maybe_parse_dftu(speciesid, atsyms, parsed_flags) :
                          hubbard_block[atsym]))
    end

    return atoms
end

function extract_structure!(parsed_flags, cell_block, atsyms, atom_block,
                            pseudo_block, hubbard_block)
    if atom_block === nothing
        return nothing
    end
    cell = extract_cell!(parsed_flags, cell_block)
    atoms = extract_atoms!(parsed_flags, atsyms, atom_block, pseudo_block, hubbard_block,
                           cell)
    return Structure(cell, atoms)
end

function separate(f, A::AbstractVector{T}) where {T}
    true_part = T[]
    false_part = T[]
    while length(A) > 0
        t = pop!(A)
        if f(t)
            push!(true_part, t)
        else
            push!(false_part, t)
        end
    end
    return reverse(true_part), reverse(false_part)
end

function qe_parse_flags(inflags, nat::Int = 0)
    flags = Dict{Symbol,Any}()

    for m_ in inflags
        sym = Symbol(m_.captures[1])
        m = m_.captures[2:end]
        if occursin("'", m[2])
            flags[sym] = strip(m[2], ''')
        else
            # normal flag
            v = replace(replace(replace(lowercase(m[2]), ".true." => "true"),
                                ".false." => "false"), "'" => "")

            if match(r"\d\.?d[-+]?\d", v) !== nothing # At least one number present
                v = replace(v, "d" => "e")
            end
            if match(r".\s+.", v) !== nothing # Multiple entries
                parsed_val = Meta.parse.(split(v))
            else
                tval = Meta.parse(v)
                parsed_val = tval isa Symbol ? string(tval) : tval
            end

            if m[1] === nothing
                flags[sym] = parsed_val
            else
                # Since arrays can be either ntyp or nat dimensionally, we
                # assume nat since that's the biggest, similarly we assume
                # 7,4,nat for the multidim arrays
                ids = parse.(Int, split(m[1], ","))
                if !haskey(flags, sym)
                    if length(ids) == 1
                        flags[sym] = length(parsed_val) == 1 ? zeros(nat) :
                                     fill(zeros(length(parsed_val)), nat)
                    elseif length(ids) == 2
                        flags[sym] = length(parsed_val) == 1 ? zeros(nat, nat) :
                                     fill(zeros(length(parsed_val)), nat, nat)
                    elseif length(ids) == 3
                        flags[sym] = zeros(7, 4, nat)
                    elseif length(ids) == 4
                        flags[sym] = zeros(7, 7, 4, nat)
                    end
                end
                for dim in 1:length(ids)
                    id = ids[dim]
                    if id > size(flags[sym], dim)
                        old = flags[sym]
                        dims = [size(old)...]
                        dims[dim] = id
                        new = zeros(dims...)
                        for d in CartesianIndices(old)
                            new[d] = old[d]
                        end
                        flags[sym] = new
                    end
                end
                flags[sym][ids...] = parsed_val
            end
        end
    end
    return flags
end

CARDS = Set(["cell_parameters",
             "occupations",
             "hubbard",
             "k_points",
             "solvents",
             "atomic_species",
             "atomic_positions",
             "additional_k_points",
             "atomic_forces",
             "constraints",
             "atomic_velocities"])

"""
    qe_parse_calculation(file)

Reads a Quantum Espresso calculation file. The `QE_EXEC` inside execs gets used to find which flags
are allowed in this calculation file, and convert the read values to the correct Types.
Returns a `Calculation{QE}` and the `Structure` that is found in the calculation.
"""
function qe_parse_calculation(file)
    @debug "parsing file: " file
    if file isa IO || !occursin("\n", file)
        contents = readlines(file)
    else
        contents = split(file, "\n")
    end

    pre_7_2 = true

    lines = map(contents) do l
        id = findfirst(isequal('!'), l)
        if id !== nothing
            l[1:id]
        else
            l
        end
    end |> x -> filter(!isempty, x)

    flagreg = r"([\w\d]+)(?:\(((?:\s*,*\d+\s*,*)*)\))?\s*=\s*([^!,\n]*)"
    unused_ids = Int[]
    flagmatches = Dict{Symbol,Vector{RegexMatch}}()
    curv = nothing
    blockreg = r"&([\w\d]+)"
    card_ids = Int[]
    for (i, l) in enumerate(lines)
        m = match(blockreg, l)
        if m !== nothing
            block = Symbol(lowercase(m.captures[1]))
            flagmatches[block] = RegexMatch[]
            curv = flagmatches[block]
            continue
        end
        m = match(flagreg, l)
        if m !== nothing
            push!(curv, m)
            continue
        end
        if lowercase(split(l)[1]) ∈ CARDS
            push!(card_ids, i)
        end

        push!(unused_ids, i)
    end
    sort!(card_ids)
    @debug "all flags: " keys(flagmatches)
    @debug "all cards: " [lines[i] for i in card_ids]

    function findcard(s)
        idid = findfirst(i -> occursin(s, lowercase(lines[i])), unused_ids)
        return idid !== nothing ? unused_ids[idid] : nothing
    end

    function nextcard(i)
        if isnothing(i)
            return length(lines) + 1
        end
        id = findfirst(j -> j > i, card_ids)
        return isnothing(id) ? length(lines) + 1 : card_ids[id]
    end

    used_lineids = Int[]

    allflags = Dict{Symbol,Dict{Symbol,Any}}()
    for (b, flgs) in flagmatches
        if b == :system
            continue
        end
        allflags[b] = qe_parse_flags(flgs)
    end
    @debug "parsing `system` section"
    if haskey(flagmatches, :system)
        sysblock = pop!(flagmatches, :system)
        nat = parse(Int, getfirst(x -> x.captures[1] == "nat", sysblock).captures[end])
        ntyp = parse(Int, getfirst(x -> x.captures[1] == "ntyp", sysblock).captures[end])
        ibrav = parse(Int, getfirst(x -> x.captures[1] == "ibrav", sysblock).captures[end])
        @assert ibrav == 0 || ibrav === nothing "ibrav different from 0 not allowed."
        i_species = findcard("atomic_species")
        i_cell = findcard("cell_parameters")
        i_positions = findcard("atomic_positions")
        push!(used_lineids, i_species)

        pseudos = Dict{Symbol,Pseudo}()
        pseudo_match = haskey(allflags, :control) ?
                       pop!(allflags[:control], :pseudo_dir, nothing) : nothing
        pseudo_dir = pseudo_match !== nothing ? pseudo_match : "."

        atsyms = Symbol[]
        for k in 1:ntyp
            push!(used_lineids, i_species + k)
            sline = strip_split(lines[i_species+k])
            atsym = Symbol(sline[1])
            ppath = pseudo_dir != "." ? joinpath(pseudo_dir, sline[end]) : sline[end]
            pseudos[atsym] = Pseudo("", ppath, "")
            push!(atsyms, atsym)
        end

        append!(used_lineids, [i_cell, i_cell + 1, i_cell + 2, i_cell + 3])
        cell_option = cardoption(lines[i_cell])
        cell = Mat3([parse(Float64, split(lines[i_cell+k])[j])
                     for k in 1:3, j in 1:3])
        atoms_option = cardoption(lines[i_positions])
        atoms = Tuple{Symbol,Point3{Float64}}[]
        for k in 1:nat
            push!(used_lineids, i_positions + k)
            sline = split(lines[i_positions+k])
            atsym = Symbol(sline[1])
            point = Point3(parse.(Float64, sline[2:4]))
            push!(atoms, (atsym, point))
        end

        sysflags = qe_parse_flags(sysblock, nat)

        i_hubbard = findcard("hubbard")
        i_hubnext = nextcard(i_hubbard)

        if i_hubbard !== nothing
            @debug "Parsing post qe7.2 Hubbard input"
            @debug "Hubbard card line" lines[i_hubbard]
            pre_7_2 = false
            projection_type = String(cardoption(lines[i_hubbard]))
            push!(used_lineids, i_hubbard)

            # go through Hubbard card
            @debug "parsing `Hubbard` section"
            @debug "current line: " lines[i_hubbard]
            dftus = Dict{Symbol,DFTU}()

            for k in i_hubbard+1:i_hubnext-1
                @debug "line $k: " lines
                push!(used_lineids, k)
                # if !checkbounds(Bool, lines, k)
                #     @warn "Attempted to access line $(k) which is out of bounds (file has $(length(lines)) lines). Skipping."
                #     atom_idx = k - i_hubbard
                #     missing_atom_type = atom_idx
                #     error("Expected a Hubbard card entry for atom type '$(missing_atom_type)', but found an empty line at line $(k).")
                #     continue # Skip to next iteration
                # end

                hubline = split(lines[k])
                hubtype = hubline[1]
                val = parse(Float64, hubline[end])
                manifolds = hubline[2:end-1]
                atsym = Symbol(split(manifolds[1], "-")[1])

                dftu = get!(dftus, atsym, DFTU())
                dftu.projection_type = projection_type

                push!(dftu.types, hubtype)
                push!(dftu.manifolds, join(manifolds, " "))
                push!(dftu.values, val)
            end
            # add empty DFTU object for atoms without Hubbard values
            map(atsyms) do atsym
                if atsym ∉ keys(dftus)
                    dftus[atsym] = DFTU()
                end
            end
            @debug "Hubbard card" dftus

            @debug "parsing structure"
            structure = extract_structure!(sysflags, (option = cell_option, data = cell),
                                           atsyms,
                                           (option = atoms_option, data = atoms),
                                           (data = pseudos,), dftus)

        else
            @debug "Parsing pre qe7.2 structure"
            structure = extract_structure!(sysflags, (option = cell_option, data = cell),
                                           atsyms,
                                           (option = atoms_option, data = atoms),
                                           (data = pseudos,), nothing)
        end

        delete!.((sysflags,), (:A, :celldm_1, :celldm, :ibrav, :nat, :ntyp))
        delete!.((sysflags,),
                 [:Hubbard_U, :Hubbard_J0, :Hubbard_alpha, :Hubbard_beta, :Hubbard_J])
        delete!.((sysflags,), [:starting_magnetization, :angle1, :angle2, :nspin]) #hubbard and magnetization flags
        allflags[:system] = sysflags
    else
        structure = nothing
    end

    @debug "parsing data section"
    datablocks = InputData[]
    i = findcard("k_points")
    if i !== nothing
        append!(used_lineids, [i, i + 1])
        k_option = cardoption(lines[i])
        @debug "k_option $k_option"
        # automatic
        if k_option == :automatic
            s_line = split(lines[i+1])
            k_data = parse.(Int, s_line)
        elseif i + 1 > length(lines)
            # gamma
            k_data = nothing
        else
            # tpiba(_b/_c) and crystal(_b/_c)
            nks    = parse(Int, lines[i+1])
            k_data = Vector{NTuple{4,Float64}}(undef, nks)
            for k in 1:nks
                push!(used_lineids, i + 1 + k)
                k_data[k] = (parse.(Float64, split(lines[i+1+k]))...,)
            end
        end
        push!(datablocks, InputData(:k_points, k_option, k_data))
    end
    return (flags = allflags, data = datablocks, structure = structure,
            package = pre_7_2 ? QE : QE7_2)
end

function qe_writeflag(f, flag, value)
    if isa(value, Vector)
        for i in 1:length(value)
            if !iszero(value[i])
                if length(value[i]) == 1
                    write(f, "  $flag($i) = $(value[i])\n")
                else
                    write(f, "  $flag($i) =")
                    for v in value[i]
                        write(f, " $v")
                    end
                    write(f, "\n")
                end
            end
        end
    elseif isa(value, AbstractArray)
        cids = findall(!iszero, value)
        for i in cids
            write(f, "  $(flag)$(Tuple(i)) = $(value[i])\n")
        end
    elseif isa(value, AbstractString)
        write(f, "  $flag = '$value'\n")
    else
        write(f, "  $flag = $value\n")
    end
end

# old qe
function qe_handle_hubbard_flags!(c::Calculation{QE}, str::Structure)
    u_ats = unique(str.atoms)
    isnc = Structures.isnoncolin(str)
    flags_to_set = []
    ishubbard = any(x -> x.dftu.U != 0 ||
                             x.dftu.J0 != 0.0 ||
                             sum(x.dftu.J) != 0 ||
                             sum(x.dftu.α) != 0, u_ats)
    if ishubbard
        Jmap = map(x -> copy(x.dftu.J), u_ats)
        Jdim = maximum(length.(Jmap))
        Jarr = zeros(Jdim, length(u_ats))
        for (i, J) in enumerate(Jmap)
            diff = Jdim - length(J)
            if diff > 0
                for d in 1:diff
                    push!(J, zero(eltype(J)))
                end
            end
            Jarr[:, i] .= J
        end
        append!(flags_to_set,
                [:Hubbard_U     => map(x -> x.dftu.U, u_ats),
                 :Hubbard_alpha => map(x -> x.dftu.α, u_ats),
                 :Hubbard_beta  => map(x -> x.dftu.β, u_ats),
                 :Hubbard_J     => Jarr,
                 :Hubbard_J0    => map(x -> x.dftu.J0, u_ats)])
    end
    if !isempty(flags_to_set) || haskey(c, :Hubbard_parameters)
        push!(flags_to_set, :lda_plus_u => true)
        if isnc
            push!(flags_to_set, :lda_plus_u_kind => 1)
        end
    end
    if !isempty(flags_to_set)
        set_flags!(c, flags_to_set...; print = false)
    else
        for f in
            (:lda_plus_u, :lda_plus_u_kind, :Hubbard_U, :Hubbard_alpha, :Hubbard_beta,
             :Hubbard_J, :Hubbard_J0, :U_projection_type)
            pop!(c, f, nothing)
        end
    end
    return ishubbard, isnc
end

# TODO nc case is not handled for QE7.2!
function qe_handle_hubbard_flags!(c::Calculation{QE7_2}, str::Structure)
    u_ats = unique(str.atoms)
    ishubbard = any(a -> !isempty(a.dftu.types), u_ats)
    isnc = Structures.isnoncolin(str)
    # set_flags!(c, :lda_plus_u => true; print = false)
    # if isnc
    #     set_flags!(c, :lda_plus_u_kind => 1; print = false)
    # end
    # needs to be poped anyway, as they are handled in write_structure
    for f in
        (:lda_plus_u, :lda_plus_u_kind, :Hubbard_U,
         # :Hubbard_alpha, :Hubbard_beta,
         :Hubbard_J, :Hubbard_J0, :U_projection_type)
        pop!(c, f, nothing)
    end
    return ishubbard, isnc
end

function qe_handle_magnetism_flags!(c::Calculation, str::Structure)
    u_ats = unique(str.atoms)
    isnc = Structures.isnoncolin(str)

    flags_to_set = []
    mags = map(x -> x.magnetization, u_ats)
    starts = Float64[]
    θs = Float64[]
    ϕs = Float64[]
    # spin polarization if 1) nonclinear 2) starting_magnetization != 0 3) tot_magnetization set
    ismagcalc = isnc ? true : (Structures.ismagnetic(str) || haskey(c, :tot_magnetization))
    if ismagcalc
        # noncolinear
        if isnc
            for m in mags
                tm = normalize(m)
                if norm(m) == 0
                    push!.((starts, θs, ϕs), 0.0)
                else
                    θ = acos(tm[3]) * 180 / π
                    ϕ = atan(tm[2], tm[1]) * 180 / π
                    start = norm(m)
                    push!(θs, θ)
                    push!(ϕs, ϕ)
                    push!(starts, start)
                end
            end
            push!(flags_to_set, :noncolin => true)
            # colinear
        else
            for m in mags
                push!.((θs, ϕs), 0.0)
                if norm(m) == 0
                    push!(starts, 0)
                else
                    push!(starts, sign(sum(m)) * norm(m))
                end
            end
        end
        append!(flags_to_set,
                [:starting_magnetization => starts, :angle1 => θs, :angle2 => ϕs,
                 :nspin => 2])
    end

    set_flags!(c, flags_to_set...; print = false)
    if isnc
        pop!(c, :nspin, nothing)
    end
end

"""
    write(f, calculation::Calculation{QE}, structure)

Writes a string represenation to `f`.
"""
function Base.write(f::IO, calculation::Calculation{T},
                    structure = nothing) where {T<:AbstractQE}
    cursize = f isa IOBuffer ? f.size : 0
    if Calculations.hasflag(calculation, :calculation)
        Calculations.set_flags!(calculation,
                                :calculation => replace(calculation[:calculation],
                                                        "_" => "-"); print = false)
    end

    if exec(calculation.exec) == "ph.x"
        write(f, "--\n")
    end
    if Calculations.ispw(calculation) && structure !== nothing
        ishubbard, isnc = qe_handle_hubbard_flags!(calculation, structure)
        qe_handle_magnetism_flags!(calculation, structure)
        if Calculations.isvcrelax(calculation)
            #this is to make sure &ions and &cell are there in the calculation 
            !haskey(calculation, :ion_dynamics) &&
                set_flags!(calculation, :ion_dynamics => "bfgs"; print = false)
            !haskey(calculation, :cell_dynamics) &&
                set_flags!(calculation, :cell_dynamics => "bfgs"; print = false)
        end
        #TODO add all the required flags
        @assert haskey(calculation, :calculation) "Please set the flag for calculation with name: $(calculation.name)"
        set_flags!(calculation, :pseudo_dir => "."; print = false)
    end

    writeflag(flag_data) = qe_writeflag(f, flag_data[1], flag_data[2])
    write_dat(data) = write_data(f, data)

    for name in
        unique([[:control, :system, :electrons, :ions, :cell]; keys(calculation.flags)...])
        if haskey(calculation.flags, name)
            flags = calculation.flags[name]
            write(f, "&$name\n")
            if name == :system
                nat  = length(structure.atoms)
                ntyp = length(unique(structure.atoms))
                # A     = 1.0
                ibrav = 0
                write(f, "  ibrav = $ibrav\n")
                # write(f,"  A = $A\n")
                write(f, "  nat = $nat\n")
                write(f, "  ntyp = $ntyp\n")
            end

            map(writeflag, [(flag, data) for (flag, data) in flags])
            write(f, "/\n\n")
        end
    end

    if exec(calculation.exec) == "pw.x"
        @assert structure !== nothing "Supply a structure to write pw.x input"
        write_structure(f, calculation, structure, ishubbard)
    end
    for dat in calculation.data
        if dat.name != :noname
            if dat.option != :none
                write(f, "$(uppercase(String(dat.name))) ($(dat.option))\n")
            else
                write(f, "$(uppercase(String(dat.name)))\n")
            end
        end
        if dat.data !== nothing
            if dat.name == :k_points && dat.option != :automatic
                write(f, "$(length(dat.data))\n")
                write_dat(dat.data)
            else
                write_dat(dat.data)
            end
            write(f, "\n")
        end
    end
    #TODO handle writing hubbard and magnetization better
    delete!.((calculation,),
             (:Hubbard_U, :Hubbard_J0, :Hubbard_J, :Hubbard_alpha, :Hubbard_beta,
              :starting_magnetization, :angle1, :angle2, :pseudo_dir))
    return f isa IOBuffer ? f.size - cursize : 0
end

function Base.write(f::AbstractString, c::Calculation{QE}, structure)
    open(f, "w") do file
        return write(file, c, structure)
    end
end

# write OSCDFT file
function Base.write(io::IO, data::OSCDFT_Struct)
        print("Inside func")
        write(io, " &OSCDFT\n")
        for (key, value) in data.parameters # Access parameters via data.parameters
            # Format values back to string, handling floats with appropriate precision
            value_str = if isa(value, Float64)
                string(value)
            else
                string(value)
            end
            write(io, " $(key) = $(value_str),\n") # Add comma and newline
        end
        write(io, "/\n")

        # Write TARGET_OCCUPATION_NUMBERS section
        write(io, "TARGET_OCCUPATION_NUMBERS\n")
        # Iterate through the 4D array using CartesianIndices to get all (idx1, idx2, idx3, idx4)
        # This naturally ensures the output order matches the input file's structure.
        # for I in CartesianIndices(data.occupation_numbers) # Access occupation_numbers via data.occupation_numbers
        #     idx1, idx2, idx3, idx4 = Tuple(I)
        #     value = data.occupation_numbers[I] # Access value using CartesianIndex

        #     # Format each number with appropriate spacing
        #     formatted_row = join([
        #         lpad(string(idx1), 2),
        #         lpad(string(idx2), 2),
        #         lpad(string(idx3), 2),
        #         lpad(string(idx4), 2),
        #         @sprintf("%8.3f", value)
        #     ], " ")
        #     write(io, " $(formatted_row)\n")
        # end
        for atom_idx in 1:length(data.occupation_numbers)

            if !isassigned(data.occupation_numbers, atom_idx)
                @warn "No occupation data found for atom index $atom_idx. Skipping during write."
                continue
            end

            
            # new version that can handle atom with different manifold size
            current_atom_tensor = data.occupation_numbers[atom_idx]
            # Iterate spin (next slowest), then orb1 (faster), then orb2 (fastest)
            # dimensions are [orb2, orb1, spin] and we want spin to be slower.

            # Let's use nested loops to guarantee the exact order: atom, spin, orb1, orb2
            # Dimensions: (max_orb2, max_orb1, max_spin)
            norb2_max, norb1_max, nspin_max = size(current_atom_tensor)

                for nspin_idx in 1:nspin_max # Iterate spin index
                    for norb1_idx in 1:norb1_max # Iterate orb1 index
                        for norb2_idx in 1:norb2_max # Iterate orb2 index
                            # Access the tensor using its internal order: [orb2, orb1, spin]
                            value = current_atom_tensor[norb2_idx, norb1_idx, nspin_idx]

                            # Output in the desired order: atom, spin, orb1, orb2
                            formatted_row = join([
                                lpad(string(atom_idx), 2),
                                lpad(string(nspin_idx), 2),
                                lpad(string(norb1_idx), 2),
                                lpad(string(norb2_idx), 2),
                                @sprintf("%8.3f", value)
                            ], " ")
                            write(io, " $(formatted_row)\n")
                        end
                    end
                end
        end
    return nothing
end


function Base.write(f::AbstractString, data::OSCDFT_Struct)
    open(f, "w") do file
        write(file, data)
    end
end



# TODO: this is a bit counter-intuitive maybe?
# Maybe tuple should be grouped into one line string
# and vector should be split into multiple lines
function write_data(f, data)
    if typeof(data) <: Matrix
        writedlm(f, data)
    elseif typeof(data) <: AbstractQE
        write(f, "$data\n")
    elseif typeof(data) <: Vector && length(data[1]) == 1
        write(f, join(string.(data), " "))
    else
        for x in data
            for y in x
                write(f, " $y")
            end
            write(f, "\n")
        end
    end
end

function write_positions_cell(f, calculation::Calculation{<:AbstractQE}, structure)
    unique_at = unique(structure.atoms)
    write(f, "ATOMIC_SPECIES\n")
    write(f,
          join(map(at -> "$(at.name) $(at.element.atomic_weight) $(at.element.symbol).UPF",
                   unique_at), "\n"))
    write(f, "\n\n")
    write(f, "CELL_PARAMETERS (angstrom)\n")
    writedlm(f, ustrip.(structure.cell'))
    write(f, "\n")

    write(f, "ATOMIC_POSITIONS (crystal) \n")
    write(f,
          join(map(at -> "$(at.name) $(join(at.position_cryst, " "))", structure.atoms),
               "\n"))
    return write(f, "\n\n")
end

function write_structure(f, calculation::Calculation{QE}, structure, ishubbard)
    return write_positions_cell(f, calculation, structure)
end
function write_structure(f, calculation::Calculation{QE7_2}, structure, ishubbard)
    write_positions_cell(f, calculation, structure)
    if ishubbard
        unique_at = unique(structure.atoms)
        u_proj = unique(map(x -> x.dftu.projection_type,
                            filter(y -> !isempty(y.dftu.types), unique_at)))
        if length(u_proj) > 1
            @warn "Found different U proj types for different atoms, this is not supported so we use the first one: $(u_proj[1])"
        end
        write(f, "HUBBARD ($(u_proj[1])) \n")
        for at in unique_at
            atsym = at.element.symbol
            # TODO: to fix
            for (i, t) in enumerate(at.dftu.types)
                if t == "U"
                    write(f,
                          "U  $(at.name)-$(ELEMENT_TO_N[atsym])$(ELEMENT_TO_L[atsym]) $(at.dftu.values[i])\n")
                elseif t == "J"
                    write(f,
                          "  $(at.name)-$(ELEMENT_TO_N[atsym])$(ELEMENT_TO_L[atsym]) $(at.dftu.values[i])\n")
                elseif t == "J0"
                    write(f,
                          "J0 $(at.name)-$(ELEMENT_TO_N[atsym])$(ELEMENT_TO_L[atsym]) $(at.dftu.values[i])\n")
                end
            end

            # if at.dftu.J[1] != 0.0
            #     write(f, "J $(at.name)-$(ELEMENT_TO_N[atsym])$(ELEMENT_TO_L[atsym]) $(at.dftu.J[1])\n")
            #     if length(at.dftu.J) == 2
            #         write(f, "B $(at.name)-$(ELEMENT_TO_N[atsym])$(ELEMENT_TO_L[atsym]) $(at.dftu.J[2])\n")
            #     else
            #         write(f, "E2 $(at.name)-$(ELEMENT_TO_N[atsym])$(ELEMENT_TO_L[atsym]) $(at.dftu.J[2])\n")
            #         write(f, "E3 $(at.name)-$(ELEMENT_TO_N[atsym])$(ELEMENT_TO_L[atsym]) $(at.dftu.J[3])\n")
            #     end
            # end
        end
        write(f, "\n")
    end
end

function qe_generate_pw2wancalculation(c::Calculation{Wannier90},
                                       nscf::Calculation{<:AbstractQE})
    flags = Dict()
    if haskey(nscf, :prefix)
        flags[:prefix] = nscf[:prefix]
    end
    flags[:seedname] = "$(c.name)"
    if haskey(nscf, :outdir)
        flags[:outdir] = nscf[:outdir]
    end
    flags[:wan_mode] = "standalone"
    flags[:write_mmn] = true
    flags[:write_amn] = true
    if haskey(c, :spin)
        flags[:spin_component] = c[:spin]
    end
    if haskey(c, :spinors)
        flags[:write_spn] = c[:spinors]
    end
    if haskey(c, :wannier_plot)
        flags[:write_unk] = c[:wannier_plot]
    end
    if any(get(c, :berry_task, []) .== ("morb"))
        flags[:write_uHu] = true
    end
    pw2wanexec = Exec(; path = joinpath(dirname(nscf.exec.path), "pw2wannier90.x"),
                      modules = nscf.exec.modules)
    run = get(c, :preprocess, false) && c.run
    name = "pw2wan_$(flags[:seedname])"
    out = Calculation(; name = name, data = InputData[],
                      exec = pw2wanexec, run = run, infile = name * ".in",
                      outfile = name * ".out")
    Calculations.set_flags!(out, flags...; print = false)
    return out
end

# This is to automatically set the hubbard manifold based on pre 7.2 QE.
# TODO: allow for multiple DFTU manifolds
const ELEMENT_TO_L = Dict(:H  => "s",
                          :K  => "s",
                          :C  => "p",
                          :N  => "p",
                          :O  => "p",
                          :As => "p",
                          :Sb => "p",
                          :Se => "p",
                          :Ti => "d",
                          :V  => "d",
                          :Cr => "d",
                          :Mn => "d",
                          :Fe => "d",
                          :Co => "d",
                          :Ni => "d",
                          :Cu => "d",
                          :Zn => "d",
                          :Zr => "d",
                          :Nb => "d",
                          :Mo => "d",
                          :Tc => "d",
                          :Ru => "d",
                          :Rh => "d",
                          :Pd => "d",
                          :Ag => "d",
                          :Cd => "d",
                          :Hf => "d",
                          :Ta => "d",
                          :W  => "d",
                          :Re => "d",
                          :Os => "d",
                          :Ir => "d",
                          :Pt => "d",
                          :Au => "d",
                          :Hg => "d",
                          :Sc => "d",
                          :Y  => "d",
                          :La => "d",
                          :Ga => "d",
                          :In => "d",
                          :Ce => "f",
                          :Pr => "f",
                          :Nd => "f",
                          :Pm => "f",
                          :Sm => "f",
                          :Eu => "f",
                          :Gd => "f",
                          :Tb => "f",
                          :Dy => "f",
                          :Ho => "f",
                          :Er => "f",
                          :Tm => "f",
                          :Yb => "f",
                          :Lu => "f",
                          :Th => "f",
                          :Pa => "f",
                          :U  => "f",
                          :Np => "f",
                          :Pu => "f",
                          :Am => "f",
                          :Cm => "f",
                          :Bk => "f",
                          :Cf => "f",
                          :Es => "f",
                          :Fm => "f",
                          :Md => "f",
                          :No => "f",
                          :Lr => "f")

const ELEMENT_TO_N = Dict(:H  => 1,
                          :C  => 2,
                          :N  => 2,
                          :O  => 2,
                          :Ti => 3,
                          :V  => 3,
                          :Cr => 3,
                          :Mn => 3,
                          :Fe => 3,
                          :Co => 3,
                          :Ni => 3,
                          :Cu => 3,
                          :Zn => 3,
                          :Sc => 3,
                          :Ga => 3,
                          :Se => 3,
                          :Zr => 4,
                          :Nb => 4,
                          :Mo => 4,
                          :Tc => 4,
                          :Ru => 4,
                          :Rh => 4,
                          :Pd => 4,
                          :Ag => 4,
                          :Cd => 4,
                          :K  => 4,
                          :Y  => 4,
                          :La => 4,
                          :Ce => 4,
                          :Pr => 4,
                          :Nd => 4,
                          :Pm => 4,
                          :Sm => 4,
                          :Eu => 4,
                          :Gd => 4,
                          :Tb => 4,
                          :Dy => 4,
                          :Ho => 4,
                          :Er => 4,
                          :Tm => 4,
                          :Yb => 4,
                          :Lu => 4,
                          :In => 4,
                          :As => 4,
                          :Sb => 4,
                          :Hf => 5,
                          :Ta => 5,
                          :W  => 5,
                          :Re => 5,
                          :Os => 5,
                          :Ir => 5,
                          :Pt => 5,
                          :Au => 5,
                          :Hg => 5,
                          :Th => 5,
                          :Pa => 5,
                          :U  => 5,
                          :Np => 5,
                          :Pu => 5,
                          :Am => 5,
                          :Cm => 5,
                          :Bk => 5,
                          :Cf => 5,
                          :Es => 5,
                          :Fm => 5,
                          :Md => 5,
                          :No => 5,
                          :Lr => 5)
