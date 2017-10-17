#TODO this can easily be generalized!!!
#Incomplete this only reads .tt files!!
"""
    load_qe_job(job_name::String,df_job_dir::String,T=Float32;inputs=nothing,new_homedir=nothing,server="",server_dir="")

Loads a Quantum Espresso job from a directory. If no specific input filenames are supplied it will try to find them from a file with name "job".
"""
function load_qe_job(job_name::String, df_job_dir::String, T=Float32; inputs=nothing, new_homedir=nothing, server="", server_dir="")
  df_job_dir = form_directory(df_job_dir)
  if inputs==nothing
    inputs = read_qe_inputs_from_job_file(df_job_dir*search_dir(df_job_dir,".tt")[1])
  end

  t_calcs = Array{Tuple{String,DFInput},1}()
  flow = Array{Tuple{String,String},1}()
  for (run_command,file) in inputs
    filename = split(file,"_")[end][1:end-3]
    push!(t_calcs,(filename,read_qe_input(df_job_dir*file,T)))
    push!(flow,(run_command,filename))
  end
  if new_homedir!=nothing
    return DFJob(job_name,t_calcs,flow,new_homedir,server,server_dir)
  else
    return DFJob(job_name,t_calcs,flow,df_job_dir,server,server_dir)
  end
end

"""
    load_qe_server_job(job_name::String,server::String,server_dir::String,local_dir::String,args...;inputs=nothing)

Pulls and loads a Quantum Espresso job.
"""
function load_qe_server_job(job_name::String, server::String, server_dir::String, local_dir::String, args...; inputs=nothing)
  pull_job(server,server_dir,local_dir,inputs=inputs)
  return load_qe_job(job_name,local_dir,args...;inputs=inputs,server=server,server_dir=server_dir)
end

#---------------------------------END QUANTUM ESPRESSO SECTION ------------------#

#---------------------------------BEGINNING GENERAL SECTION ---------------------#

function pull_file(server::String,server_dir::String,local_dir::String,filename::String)
  run(`scp $(server*":"*server_dir*filename) $local_dir`)
end
#should we call this load local job?
function load_job(job_name::String, job_dir::String, T=Float32; inputs=nothing, job_ext = ".tt", new_homedir=nothing, server="",server_dir="")
  job_dir = form_directory(job_dir)
  if inputs == nothing
    inputs = read_inputs_from_job_file(job_dir*search_dir(job_dir,job_ext)[1])
  end

  t_calcs = Array{Tuple{String,DFInput},1}()
  # flow    = Array{Tuple{String,String},1}()
  #we whould probably make an automatic filereader or something
  for (run_command,file) in inputs
    filename = split(split(file,"_")[end],".")[1]
    if contains(run_command,"wan") && !contains(run_command,"pw2wannier90")
      push!(t_calcs,(run_command,read_wannier_input(job_dir*file,T)))
    else
      push!(t_calcs,(run_command,read_qe_input(job_dir*file,T)))
    end
  end
  if new_homedir != nothing
    return DFJob(job_name,t_calcs,new_homedir,server,server_dir)
  else
    return DFJob(job_name,t_calcs,job_dir,server,server_dir)
  end
end

#TODO should we also create a config file for each job with stuff like server etc? and other config things,
#      which if not supplied could contain the default stuff?
"""
    pull_job(server::String, server_dir::String, local_dir::String; job_fuzzy="*job*")
Pulls job from server. If no specific inputs are supplied it pulls all .in and .tt files.
"""
# Input:  server::String, -> in host@servername format!
#         server_dir::String,
#         local_dir::String, -> will create the dir if necessary.
# Kwargs: inputs=nothing -> specific input filenames.
function pull_job(server::String, server_dir::String, local_dir::String; job_fuzzy="*job*")
  server_dir = form_directory(server_dir)
  local_dir  = form_directory(local_dir)
  if !ispath(local_dir)
    mkdir(local_dir)
  end
  pull_server_file(filename) = pull_file(server,server_dir,local_dir,filename)
  pull_server_file(job_fuzzy)
  job_file = search_dir(local_dir,strip(job_fuzzy,'*'))[1]
  if job_file != nothing
    inputs = read_inputs_from_job_file(local_dir*job_file)
    for (calculation,file) in inputs
      pull_server_file(file)
    end
  end
end

"""
    load_server_job(job_name::String,server::String,server_dir::String,local_dir::String;job_fuzzy="*job*")

Pulls a server job to local directory and then loads it. A fuzzy search for the job file will be performed and the found input files will be pulled.
"""
function load_server_job(job_name::String, server::String, server_dir::String, local_dir::String; job_fuzzy="*job*")
  pull_job(server,server_dir,local_dir)
  return load_job(job_name,local_dir,server=server,server_dir=server_dir)
end

"""
    save_job(df_job::DFJob)

Saves a DFJob, it's job file and all it's input files.
"""
function save_job(df_job::DFJob)
  if df_job.home_dir == ""
    error("Please specify a valid home_dir!")
  end
  df_job.home_dir = form_directory(df_job.home_dir)
  if !ispath(df_job.home_dir)
    mkpath(df_job.home_dir)
  end
  write_job_files(df_job)
end

#Incomplete everything is hardcoded for now still!!!! make it configurable
"""
    push_job(df_job::DFJob)

Pushes a DFJob from it's local directory to its server side directory.
"""
function push_job(df_job::DFJob)
  if !ispath(df_job.home_dir)
    error("Please save the job locally first using save_job(job)!")
  else
    calculations = read_inputs_from_job_file(df_job.home_dir*"job.tt")
    for (calc,file) in calculations
      run(`scp $(df_job.home_dir*file) $(df_job.server*":"*df_job.server_dir)`)
    end
    run(`scp $(df_job.home_dir*"job.tt") $(df_job.server*":"*df_job.server_dir)`)
  end
end

#TODO only uses qsub for now. how to make it more general?
"""
    submit_job(df_job::DFJob)

Submit a DFJob. First saves it locally, pushes it to the server then runs the job file on the server.
"""
function submit_job(df_job::DFJob)
  if df_job.server == ""
    error("Please specify a valid server address first!")
  elseif df_job.server_dir == ""
    error("Please specify a valid server directory first!")
  end
  save_job(df_job)
  push_job(df_job)
  run(`ssh -t $(df_job.server) cd $(df_job.server_dir) '&&' qsub job.tt`)
end

"""
    check_job_data(df_job,data::Array{Symbol,1})

Check the values of certain flags in a given job if they exist.
"""
function check_job_data(df_job,data_keys)
  out_dict = Dict{Symbol,Any}()
  for s in data_keys
    for (meh,calc) in df_job.calculations
      for name in fieldnames(calc)[2:end]
        data_dict = getfield(calc,name)
        if name == :control_blocks
          for (key,block) in data_dict
            for (flag,value) in block
              if flag == s
                out_dict[s] = value
              end
            end
          end
        else
          for (key,value) in data_dict
            if key == s
              out_dict[s] = value
            end
          end
        end
      end
    end
  end
  return out_dict
end

"""
    change_job_data!(df_job::DFJob,new_data::Dict{Symbol,<:Any})

Mutatatively change data that is tied to a DFJob. This means that it will run through all the DFInputs and their fieldnames and their Dicts.
If it finds a Symbol in one of those that matches a symbol in the new data, it will replace the value of the first symbol with the new value.
"""
function change_job_data!(df_job::DFJob,new_data::Dict{Symbol,<:Any})
  found_keys = Symbol[]
  for (key,calculation) in df_job.calculations
    for name in fieldnames(calculation)[2:end]
      data_dict = getfield(calculation,name)
      if name == :control_blocks
        for (block_key,block) in data_dict
          for (flag,value) in block
            if haskey(new_data,flag)
              old_data = value
              if !(flag in found_keys) push!(found_keys,flag) end
              if typeof(old_data) == typeof(new_data[flag])
                block[flag] = new_data[flag]
                println("$key:\n -> $block_key:\n  -> $flag:\n      $old_data changed to: $(new_data[flag])")
              else
                println("$key:\n -> $block_key:\n  -> $flag:\n    type mismatch old:$old_data ($(typeof(old_data))), new: $(new_data[flag]) ($(typeof(new_data[flag])))\n    Change not applied.")
              end
            end
          end
        end
      else
        for (data_key,data_val) in new_data
          if haskey(data_dict,data_key)
          if !(data_key in found_keys) push!(found_keys,data_key) end
            old_data            = data_dict[data_key]
            if typeof(old_data) == typeof(data_val)
              data_dict[data_key] = data_val
              println("$key:\n -> $name:\n  -> $data_key:\n      $old_data changed to $(data_dict[data_key])")
            else
              println("$key:\n -> $name:\n  -> $data_key:\n    type mismatch old:$old_data ($(typeof(old_data))), new: $data_val ($(typeof(data_val)))\n    Change not applied.")
            end
          end
        end
      end
    end
  end
  for key in found_keys
    pop!(new_data,key)
  end
  if 1 < length(keys(new_data))
    println("flags $(String.(collect(keys(new_data)))) were not found in any input file, please set them first!")
  elseif length(keys(new_data)) == 1
    println("flag '$(String(collect(keys(new_data))[1]))' was not found in any input file, please set it first!")
  end
end

#Incomplete this now assumes that there is only one calculation, would be better to interface with the flow of the DFJob
"""
    set_job_data!(df_job::DFJob,calculation::Int,block_symbol::Symbol,data)

Sets mutatatively the job data in a calculation block of a DFJob. It will merge the supplied data with the previously present one in the block,
changing all previous values to the new ones and adding non-existent ones.
"""
# Input: df_job::DFJob,
#        calculation::String, -> calculation in the DFJob.
#        block_symbol::Symbol, -> Symbol of the datablock inside the calculation's input file.
#        data::Dict{Symbol,Any} -> flags and values to be set.
#Incomplete possibly change calculation to a string rather than an integer but for now it's fine
function set_job_data!(df_job::DFJob, calculation::Int, block_symbol::Symbol, data)
  t_calc = df_job.calculations[calculation][2]
  if block_symbol == :control_blocks
    for (block_key,block_dict) in data
      t_calc.control_blocks[block_key] = merge(t_calc.control_blocks[block_key],data[block_key])
      println("New input of block '$(String(block_key))' in '$(String(block_symbol))' of calculation '$calculation' is now:")
      display(t_calc.control_blocks[block_key])
      println("\n")
    end
  else
    setfield!(t_calc,block_symbol,merge(getfield(t_calc,block_symbol),data))
    println("New input of '$block_symbol' in calculation '$calculation' is:\n")
    display(getfield(t_calc,block_symbol))
    println("\n")
  end
end

"""
    set_job_data!(df_job,calculations::Array,block_symbol,data)

Same as above but for multiple calculations.
"""
function set_job_data!(df_job,calculations::Array,block_symbol,data)
  for calculation in calculations
    set_job_data!(df_job,calculation,block_symbol,data)
  end
end
#---------------------------------END GENERAL SECTION ------------------#
