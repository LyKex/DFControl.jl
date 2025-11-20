module DFControl
using CondaPkg
const DFC = DFControl
export DFControl, DFC

const DEPS_DIR = joinpath(dirname(@__DIR__), "deps")
if any(x -> !ispath(joinpath(DEPS_DIR, x)),
       ("wannier90flags.jl", "qeflags.jl", "abinitflags.jl", "elkflags.jl",
        "qe7.2flags.jl"))
    include(joinpath(DEPS_DIR, "build.jl"))
end

using LinearAlgebra
using Reexport
using Printf

@reexport using StaticArrays

using Parameters, StructTypes, Dates
include("types.jl")
export Point, Point3, Vec3, Mat3, Mat4

include("utils.jl")

include("Structures/Structures.jl")
include("Calculations/Calculations.jl")
include("Jobs/Jobs.jl")
include("FileIO/FileIO.jl")
include("Client/Client.jl")
include("Display/Display.jl")

@reexport using .Client

end
