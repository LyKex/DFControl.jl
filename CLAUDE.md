# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

DFControl.jl is a Julia package for managing DFT (Density Functional Theory) calculations. It wraps Quantum-Espresso (QE), Wannier90, ABINIT, and ELK, providing a unified API for job creation, submission, and output parsing. Jobs run on remote HPC systems via **RemoteHPC.jl**, which handles server communication, SSH tunnels, and job state management.

## Commands

```bash
# Run all tests
julia --project -t 4 -e 'using Pkg; Pkg.test()'

# Run a single test file
julia --project -e 'include("test/jobfromcif_tests.jl")'

# Build (regenerates deps/*flags.jl if missing)
julia --project -e 'using Pkg; Pkg.build()'

# REPL development
julia --project
```

The `deps/` directory holds generated flag definition files (`qeflags.jl`, `qe7.2flags.jl`, `wannier90flags.jl`, `abinitflags.jl`, `elkflags.jl`). These are created by `deps/build.jl` and should be committed when regenerated (currently untracked).

## Architecture

The package is organized into five internal modules loaded by `src/DFControl.jl`:

```
Structures  →  atomic structure, atoms, pseudopotentials, symmetry (spglib)
Calculations →  per-code input generation and flag validation
Jobs         →  workflow: ordered list of Calculations on a Structure
FileIO       →  output parsing (qe.jl is the largest file at ~90KB)
Client       →  high-level user-facing API; re-exports RemoteHPC symbols
```

### Central data model

```
Job
├── structure :: Structure          # unit cell + atoms
├── calculations :: Vector{Calculation{P}}   # P ∈ {QE, QE7_2, Wannier90, Abinit, Elk}
├── server :: String                # RemoteHPC server name
└── environment :: String           # job environment (MPI directives, modules, etc.)

Calculation{P}
├── flags :: Dict{Symbol,Any}       # DFT code input flags (validated against deps/*flags.jl)
├── data  :: Vector{InputData}      # structured blocks (k-points, etc.)
└── exec  :: Exec                   # from RemoteHPC: executable + mpi runner

Structure
├── cell  :: Mat3{<:Unitful}        # lattice vectors as columns
└── atoms :: Vector{Atom}           # positions, element, pseudo, DFTU, projections
```

### RemoteHPC integration

`Client/Client.jl` re-exports core RemoteHPC symbols: `submit`, `save`, `load`, `state`, `abort`, `Server`, `Exec`, `Environment`, `local_server`, `configure`. DFControl wraps these to add job versioning, registry tracking, and pseudopotential management. When reading client-side job control code, expect the actual RPC calls to originate in RemoteHPC.

### Flag validation

`deps/*flags.jl` define `FlagInfo` structs (name, type, description, allowed values) for every supported input keyword. `Calculation` uses these at set-time to catch typos and coerce types. When adding support for new DFT code keywords, the flag files must be extended.

### Job versioning

Jobs store history in a `.versions/` subdirectory within the job directory. `versioning.jl` manages `switch_version!`, `rm_version!`, and `versions()`. Versions are created on `save()`.

### Output parsing

`FileIO/qe.jl` is the largest and most complex file. It parses QE stdout into structured Julia types (bands, Fermi energy, forces, stresses, geometry optimization trajectories, etc.). Entry point is `outputdata(calc)`.

## Key conventions

- `Calculation` behaves like a `Dict` for flag access: `calc[:ecutwfc] = 60.0`
- `Job` also supports flag access that propagates to all calculations: `job[:ecutwfc] = 60.0`
- Helper constructors like `gencalc_scf`, `gencalc_bands`, `gencalc_nscf` create pre-configured `Calculation` objects
- `set_pseudos!(structure, :pbesol)` assigns pseudopotentials by set name
- `set_flow!(job, "scf" => true, "nscf" => false)` controls which calculations actually run
- StaticArrays (`Vec3`, `Mat3`) are used throughout for performance; atomic units via `UnitfulAtomic`
