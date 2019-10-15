
abstract type AbstractStructure{T, LT} end

mutable struct Structure{T <: AbstractFloat, AA<:AbstractAtom{T}, LT <: Length{T}} <: AbstractStructure{T, LT}
    name ::AbstractString
    cell ::Mat3{LT}
    atoms::Vector{AA}
    data ::Dict{Symbol, Any}
end
Structure() =
	Structure("NoName", eye(3), Atom[], Dict{Symbol, Any}())

Structure(name, cell::Mat3{LT}, atoms::Vector{Atom{T, LT}}) where {T<:AbstractFloat,LT<:Length{T}} =
	Structure{T, Atom{T, LT}, LT}(name, cell, atoms, Dict{Symbol, Any}())

Structure(str::AbstractStructure{T}, atoms::Vector{AT}) where {T<:AbstractFloat, AT<:AbstractAtom{T}} =
	Structure{T, AT}(name(str), cell(str), atoms, data(str))

Structure(cell::Matrix{LT}, atoms::Vector{Atom{T, LT}}) where {T<:AbstractFloat,LT<:Length{T}} =
	Structure{T, Atom{T, LT}, LT}("NoName", cell, atoms, Dict{Symbol, Any}())

Structure(cif_file::String; name="NoName") =
	cif2structure(cif_file, structure_name = name)

structure(str::Structure) = str
"""
Returns all the atoms inside the structure with the specified symbol
"""
function atoms(str::AbstractStructure, atsym::Symbol)
    out = AbstractAtom[]
    for at in str.atoms
        name(at) == atsym && push!(out, at)
    end
    return out
end
atoms(str::AbstractStructure) = structure(str).atoms
name(str::AbstractStructure) = structure(str).name
data(str::AbstractStructure) = structure(str).data

Base.length(str::AbstractStructure) = length(atoms(str))
cell(str::AbstractStructure) = structure(str).cell

projections(str::AbstractStructure) = projections.(atoms(str))
hasprojections(str::AbstractStructure) = !all(isempty, projections(str))
hasprojections_assert(str::AbstractStructure) =
    @assert hasprojections(str) "No projections found in structure $(str.name).
    Please set the projections for the atoms inside the structure first using `setprojections!`."

reciprocal(cell::AbstractMatrix) = inv(cell)

"""
    setprojections!(str::Structure, projs::Pair...)

Sets the projections of the specified atoms. `projs` has to be of form `:atsym => [:proj]`,
where proj = :s, :p, :d, :f, etc.
"""
function setprojections!(str::Structure, projs::Pair...)
    projdict = Dict(projs)
    for at in unique(str.atoms)
        if !haskey(projdict, name(at))
            projdict[name(at)] = [proj.orb for proj in projections(at)]
        end
    end
    emptyprojections!(str)
    addprojections!(projdict, str.atoms)
end

function emptyprojections!(str::Structure)
    for at in str.atoms
        empty!(projections(at))
    end
end

function nprojections(structure)
    n = 0
    for at in atoms(structure)
        projs = projections(at)
        if !isempty(projs)
            n += sum(orbsize.(projs))
        end
    end
    return n
end

#TODO extend base.merge
"Takes a vector of structures and merges all the attributes of the atoms."
function mergestructures(structures::Vector{<:AbstractStructure})
    nonvoid = filter(x -> x != nothing, structures)
    out = nonvoid[1]
    for structure in nonvoid[2:end]
        for at1 in atoms(out), at2 in atoms(structure)
            if at1 == at2
                for fname in fieldnames(typeof(at1))
                    if fname in [:name, :element, :position_cart, :position_cryst]
                        continue
                    end
                    field = getfield(at2, fname)
                    if field == nothing || isdefault(field)
                        continue
                    else
                        setfield!(at1, fname, field)
                    end
                end
            end
        end
    end
    return out
end

"Uses cif2cell to Meta.parse a cif file, then returns the parsed structure."
function cif2structure(cif_file::String; structure_name="NoName")
    tmpdir = dirname(cif_file)
    tmpfile = joinpath(tmpdir, "tmp.in")
    @assert splitext(cif_file)[2] == ".cif" error("Please specify a valid cif input file")
    run(`$pythonpath $cif2cellpath $cif_file -p quantum-espresso -o $tmpfile`)

    bla, structure = qe_read_input(tmpfile, structure_name = structure_name)
    rm(tmpfile)
    return structure
end

function setpseudos!(structure::AbstractStructure, atoms::Vector{<:AbstractAtom}, set::Symbol, specifier::String=""; kwargs...)
	dir = getdefault_pseudodir(set)
	if dir == nothing
		@warn "No pseudos found for set $set."
		return
	end
    for (i, at) in enumerate(atoms)
        pseudo = getdefault_pseudo(name(at), set, specifier=specifier)
        if pseudo == nothing
            @warn "Pseudo for $(name(at)) at index $i not found in set $set."
        else
            setpseudo!(at, pseudo; kwargs...)
        end
    end
end

setpseudos!(structure::AbstractStructure, atname::Symbol, set::Symbol, specifier::String=""; kwargs...) =
	setpseudos!(structure, atoms(structure, atname), set, specifier; kwargs...)

setpseudos!(structure::AbstractStructure, set::Symbol, specifier::String=""; kwargs...) =
	setpseudos!(structure, atoms(structure), set, specifier; kwargs...)

function setpseudos!(structure::AbstractStructure, at_pseudos::Pair{Symbol, Pseudo}...; kwargs...)
    for (atsym, pseudo) in at_pseudos
        for at in atoms(structure, atsym)
            setpseudo!(at, pseudo; kwargs...)
        end
    end
end

"""
    create_supercell(structure::AbstractStructure, na::Int, nb::Int, nc::Int)

Takes a structure and creates a supercell from it with the given amount of extra cells (`na, nb, nc`) along the a, b, c direction.
"""
function create_supercell(structure::AbstractStructure, na::Int, nb::Int, nc::Int)
    orig_ats   = atoms(structure)
    orig_cell  = cell(structure)
    scale_mat  = diagm(0 => 1 .+ [na, nb, nc])
    new_cell   = orig_cell * scale_mat
    new_atoms  = eltype(orig_ats)[]
    for ia=0:na, ib=0:nb, ic=0:nc
        # if all((ia, ib, ic) .== 0)
        #     continue
        # end
        transl_vec = orig_cell * [ia, ib, ic]
        for at in orig_ats
	        cart_pos = position_cart(at) + transl_vec
	        cryst_pos = inv(new_cell) * cart_pos
            push!(new_atoms, Atom(at, cart_pos, Point3(cryst_pos)))
        end
    end
    return Structure(name(structure), Mat3(new_cell), new_atoms, data(structure))
end

"Rescales the cell of the structure."
function scale_cell!(structure::Structure, v)
	scalemat = [v 0 0; 0 v 0; 0 0 v]
	structure.cell *= scalemat
	for at in atoms(structure)
		at.position_cart = structure.cell * at.position_cryst
	end
	structure.cell
end

function set_magnetization!(str::Structure, atsym_mag::Pair{Symbol, <:AbstractVector}...)
	for (atsym, mag) in atsym_mag
		for at in atoms(str, atsym)
			set_magnetization!(at, mag)
		end
	end
end

"""
    volume(cell::Mat3)
	volume(str::Structure)

Calculates the volume for the unit cell.
"""
volume(cell::Mat3) = det(cell)
   
volume(str::Structure) = cell(str)

const DEFAULT_TOLERANCE = 1e-5

struct SPGStructure
    lattice::Matrix{Cdouble}
    positions::Matrix{Cdouble}
    species_indices::Vector{Cint}
end

function SPGStructure(s::Structure)
    clattice = convert(Matrix{Cdouble}, ustrip.(cell(s)'))
    cpositions = convert(Matrix{Cdouble}, hcat(position_cryst.(atoms(s))...))
    uats         = unique(atoms(s))
    species_indices = Cint[findfirst(x -> isequal_species(x, at), uats) for at in atoms(s)]
    return SPGStructure(clattice, cpositions, species_indices)
end

function symmetry_operators(s::SPGStructure; maxsize=52, tolerance = DEFAULT_TOLERANCE)
    rotations    = Array{Cint}(undef, 3, 3, maxsize)
    translations = Array{Cdouble}(undef, 3, maxsize)

    num_ops = ccall((:spg_get_symmetry, SPGLIB), Cint,
      (Ptr{Cint}, Ptr{Cdouble}, Cint, Ptr{Cdouble}, Ptr{Cdouble}, Ptr{Cint}, Cint, Cdouble),
       rotations, translations, maxsize, s.lattice, s.positions, s.species_indices, length(s.species_indices), tolerance)
    return (rotations=[Mat3{Int}(rotations[:, :, i]) for i=1:num_ops], translations=[Vec3(translations[:, i]) for i=1:num_ops])
end

function international_symbol(s::SPGStructure; tolerance = DEFAULT_TOLERANCE)
    res = zeros(Cchar, 11)

    numops = ccall((:spg_get_international, SPGLIB), Cint,
                   (Ptr{Cchar}, Ptr{Cdouble}, Ptr{Cdouble}, Ptr{Cint}, Cint, Cdouble),
                   res, s.lattice, s.positions, s.species_indices, length(s.species_indices), tolerance)
    numops == 0 && error("Could not determine the international symbol.")

    return join(convert(Vector{Char}, res[1:findfirst(iszero, res) - 1]))
end

function niggli_reduce!(s::SPGStructure; tolerance = DEFAULT_TOLERANCE)

    numops = ccall((:spg_niggli_reduce, SPGLIB), Cint,
                   (Ptr{Cdouble}, Cdouble),
                   s.lattice, tolerance)
    numops == 0 && error("Could not determine the niggli reduced cell.")

    return Mat3(s.lattice)
end

symmetry_operators(s::Structure; kwargs...) = symmetry_operators(SPGStructure(s); kwargs...)
international_symbol(s::Structure; kwargs...) = international_symbol(SPGStructure(s); kwargs...)
niggli_reduce(s::Structure; kwargs...) = niggli_reduce!(SPGStructure(s); kwargs...).*unit(eltype(cell(s)))


"""
    cell_parameters(cell::Mat3)
    cell_parameters(str::Structure)

Parameters (a, b, c, α, β, γ) of the input cell returned in a named tuple.
"""
function cell_parameters(cell::Mat3)
    G = transpose(cell) * cell
    a, b, c = sqrt.(diag(G))
    α = acos(0.5(G[2, 3] + G[3, 2])/(c * b))
    β = acos(0.5(G[3, 1] + G[1, 3])/(a * c))
    γ = acos(0.5(G[1, 2] + G[2, 1])/(a * b))
    a, b, c, α, β, γ
end

cell_parameters(s::Structure) = cell_parameters(ustrip.(cell(s)))

function crystal_kind(s::Structure; tolerance=DEFAULT_TOLERANCE, nigglireduce=true)

    abcαβγ = nigglireduce ? cell_parameters(ustrip.(niggli_reduce(s))) : cell_parameters(s)
    a, b, c, α, β, γ = abcαβγ
    all_same_length = all(x->x - abcαβγ[1] < tolerance, abcαβγ[1:3])

    angles = abcαβγ[4:end]
    all_same_angles = all(x->x - angles[1] < tolerance, angles)

    all_angles_are = (a) -> maximum(abs.(angles .- a)) < tolerance
    if all_same_length && all_angles_are(π/2)
        return :cubic
    elseif all_same_length && all_angles_are(π/3)
        return :fcc
    elseif all_same_length && all_angles_are(acos(-1/3))
        return :bcc
    elseif abs(a-b) < tolerance && all_angles_are(π/2)
        return :tetragonal
    elseif all_angles_are(π/2)
        return :orthorhombic
    elseif abs(a-b) < tolerance &&
        (abs(γ - 2π/3) < tolerance || abs(γ - π/3) < tolerance && maximum(abs.(angles[1:2] .- π/2)) < tolerance)
        return :hexagonal
    elseif sum(abs.(angles .- π/2) .> tolerance) == 1
        return :monoclinic
    elseif all_same_length && all_same_angles && maximum(abs.(angles)) < π/2
        return :rhombohedral_type_1
    elseif all_same_length && all_same_angles && maximum(abs.(angles)) > π/2
        return :rhombohedral_type_2
    end
end
