using CondaPkg

config_path(args...) = joinpath(abspath(first(DEPOT_PATH), "config", "DFControl"), args...)

@info "installing cif2cell"
CondaPkg.update()

include("asset_init.jl")
