module DFControl
using CondaPkg
const DFC = DFControl
export DFC

const DEPS_DIR = joinpath(dirname(@__DIR__), "deps")
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
