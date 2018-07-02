# Types #
# ========================== #
abstract type AbstractStructuredSolver end

mutable struct SPSolver
    solver::Union{MathProgBase.AbstractMathProgSolver,AbstractStructuredSolver}
end

abstract type AbstractScenarioData end
probability(sd::AbstractScenarioData) = sd.π
function expected(::Vector{SD}) where SD <: AbstractScenarioData
    error("Expected value operation not implemented for scenariodata type: ", SD)
end

abstract type AbstractSampler{SD <: AbstractScenarioData} end
struct NullSampler{SD <: AbstractScenarioData} <: AbstractSampler{SD} end

mutable struct Stage{D}
    stage::Int
    data::D

    function (::Type{StageData})(stage::Integer,data::D) where D
        return new{D}(stage,data)
    end
end

struct ScenarioProblems{D, SD <: AbstractScenarioData, S <: AbstractSampler{SD}}
    stage::Stage{D}
    scenariodata::Vector{SD}
    sampler::S
    problems::Vector{JuMP.Model}
    parent::JuMP.Model

    function (::Type{ScenarioProblems})(stage::Integer,stagedatas::Vector,::Type{SD}) where {D,SD <: AbstractScenarioData}
        D = typeof(stagedata)
        S = NullSampler{SD}
        this_stage = if length(stagedatas) == 1
            Stage(stage,shift!(stagedatas),true)
        elseif length(stagedatas) > 1

        else

        end
        return new{D,SD,S}(Stage(stage,stagedata),Vector{SD}(),NullSampler{SD}(),Vector{JuMP.Model}(),Model(solver=JuMP.UnsetSolver()))
    end

    function (::Type{ScenarioProblems})(stage::Integer,stagedata::D,scenariodata::Vector{<:AbstractScenarioData}) where D
        SD = eltype(scenariodata)
        S = NullSampler{SD}
        return new{D,SD,S}(Stage(stage,stagedata),scenariodata,NullSampler{SD}(),Vector{JuMP.Model}(),Model(solver=JuMP.UnsetSolver()))
    end

    function (::Type{ScenarioProblems})(stage::Integer,stagedata::D,sampler::AbstractSampler{SD}) where {D,SD <: AbstractScenarioData}
        S = typeof(sampler)
        return new{D,SD,S}(Stage(stage,stagedata),Vector{SD}(),sampler,Vector{JuMP.Model}(),Model(solver=JuMP.UnsetSolver()))
    end
end
DScenarioProblems{D,SD,S} = Vector{RemoteChannel{Channel{ScenarioProblems{D,SD,S}}}}

function ScenarioProblems(stage::Integer,stagedata::D,::Type{SD},procs::Vector{Int}) where {D,SD <: AbstractScenarioData}
    if (length(procs) == 1 || nworkers() == 1) && procs[1] == 1
        return ScenarioProblems(common,SD)
    else
        isempty(procs) && error("No requested procs.")
        length(procs) <= nworkers() || error("Not enough workers to satisfy requested number of procs. There are ", nworkers(), " workers, but ", length(procs), " were requested.")

        S = NullSampler{SD}
        scenarioproblems = DScenarioProblems{D,SD,S}(length(procs))

        finished_workers = Vector{Future}(length(procs))
        for p in procs
            scenarioproblems[p-1] = RemoteChannel(() -> Channel{ScenarioProblems{D,SD,S}}(1), p)
            finished_workers[p-1] = remotecall((sp,stage,stagedata,SD)->put!(sp,ScenarioProblems(stage,stagedata,SD)),p,scenarioproblems[p-1],stage,stagedata,SD)
        end
        map(wait,finished_workers)
        return scenarioproblems
    end
end

function ScenarioProblems(stage::Integer,stagedata::D,scenariodata::Vector{SD},procs::Vector{Int}) where {D,SD <: AbstractScenarioData}
    if (length(procs) == 1 || nworkers() == 1) && procs[1] == 1
        return ScenarioProblems(stage,stagedata,scenariodata)
    else
        isempty(procs) && error("No requested procs.")
        length(procs) <= nworkers() || error("Not enough workers to satisfy requested number of procs. There are ", nworkers(), " workers, but ", length(procs), " were requested.")

        S = NullSampler{SD}
        scenarioproblems = DScenarioProblems{D,SD,S}(length(procs))

        (nscen,extra) = divrem(length(scenariodata),length(procs))
        if extra > 0
            nscen += 1
        end
        start = 1
        stop = nscen
        finished_workers = Vector{Future}(length(procs))
        for p in procs
            scenarioproblems[p-1] = RemoteChannel(() -> Channel{ScenarioProblems{D,SD,S}}(1), p)
            finished_workers[p-1] = remotecall((sp,stage,stagedata,sdata)->put!(sp,ScenarioProblems(stage,stagedata,sdata)),p,scenarioproblems[p-1],stage,stagedata,scenariodata[start:stop])
            start += nscen
            stop += nscen
            stop = min(stop,length(scenariodata))
        end
        map(wait,finished_workers)
        return scenarioproblems
    end
end

function ScenarioProblems(stage::Integer,stagedata::D,sampler::AbstractSampler{SD},procs::Vector{Int}) where {D,SD <: AbstractScenarioData}
    if (length(procs) == 1 || nworkers() == 1) && procs[1] == 1
        return ScenarioProblems(stage,stagedata,sampler)
    else
        isempty(procs) && error("No requested procs.")
        length(procs) <= nworkers() || error("Not enough workers to satisfy requested number of procs. There are ", nworkers(), " workers, but ", length(procs), " were requested.")
        S = typeof(sampler)
        scenarioproblems = DScenarioProblems{D,SD,S}(length(procs))
        finished_workers = Vector{Future}(length(procs))
        for p in procs
            scenarioproblems[p-1] = RemoteChannel(() -> Channel{ScenarioProblems{D,SD,S}}(1), p)
            finished_workers[p-1] = remotecall((sp,stage,stagedata,sampler)->put!(sp,ScenarioProblems(stage,stagedata,sampler)),p,scenarioproblems[p-1],stage,stagedata,sampler)
        end
        map(wait,finished_workers)
        return scenarioproblems
    end
end

struct StochasticProgramData{D, SD <: AbstractScenarioData, S <: AbstractSampler{SD}, SP <: Union{ScenarioProblems{D,SD,S},
                                                                                                  DScenarioProblems{D,SD,S}}}
    stage::Stage{D}
    scenarioproblems::SP
    generator::Dict{Symbol,Function}
    problemcache::Dict{Symbol,JuMP.Model}
    spsolver::SPSolver

    function (::Type{StochasticProgramData})(stage::Integer,stagedatas::Vector,::Type{SD},procs::Vector{Int}) where {D,SD <: AbstractScenarioData}
        isempty(stagedatas) && error("No stage data provided")
        stagedata = shift!(stagedatas)
        S = NullSampler{SD}
        scenarioproblems = ScenarioProblems(stage+1,stagedatas,SD,procs)
        return new{D,SD,S,typeof(scenarioproblems)}(StageData(stage,stagedata),scenarioproblems,Dict{Symbol,Function}(),Dict{Symbol,JuMP.Model}(),SPSolver(JuMP.UnsetSolver())
    end

    function (::Type{StochasticProgramData})(common::D,scenariodata::Vector{<:AbstractScenarioData},procs::Vector{Int}) where D
        SD = eltype(scenariodata)
        S = NullSampler{SD}
        scenarioproblems = ScenarioProblems(common,scenariodata,procs)
        return new{D,SD,S,typeof(scenarioproblems)}(StageData(common),scenarioproblems,Dict{Symbol,Function}(),Dict{Symbol,JuMP.Model}(),SPSolver(JuMP.UnsetSolver())
    end

    function (::Type{StochasticProgramData})(common::D,sampler::AbstractSampler{SD},procs::Vector{Int}) where {D,SD <: AbstractScenarioData}
        S = typeof(sampler)
        scenarioproblems = ScenarioProblems(common,sampler,procs)
        return new{D,SD,S,typeof(scenarioproblems)}(StageData(common),scenarioproblems,Dict{Symbol,Function}(),Dict{Symbol,JuMP.Model}(),SPSolver(JuMP.UnsetSolver())
    end
end

StochasticProgram(::Type{SD}; solver = JuMP.UnsetSolver(), procs = workers()) where SD <: AbstractScenarioData = StochasticProgram(nothing,SD; solver = solver, procs = procs)
function StochasticProgram(common::Any,::Type{SD}; solver = JuMP.UnsetSolver(), procs = workers) where SD <: AbstractScenarioData
    stochasticprogram = JuMP.Model()
    stochasticprogram.ext[:SP] = StochasticProgramData(common,SD,procs)
    stochasticprogram.ext[:SP].spsolver.solver = solver
    # Set hooks
    JuMP.setsolvehook(stochasticprogram, _solve)
    JuMP.setprinthook(stochasticprogram, _printhook)
    # Return stochastic program
    return stochasticprogram
end
StochasticProgram(scenariodata::Vector{<:AbstractScenarioData}; solver = JuMP.UnsetSolver(), procs = workers()) = StochasticProgram(nothing,scenariodata; solver = solver, procs = procs)
function StochasticProgram(common::Any,scenariodata::Vector{<:AbstractScenarioData}; solver = JuMP.UnsetSolver(), procs = workers())
    stochasticprogram = JuMP.Model()
    stochasticprogram.ext[:SP] = StochasticProgramData(common,scenariodata,procs)
    stochasticprogram.ext[:SP].spsolver.solver = solver
    # Set hooks
    JuMP.setsolvehook(stochasticprogram, _solve)
    JuMP.setprinthook(stochasticprogram, _printhook)
    # Return stochastic program
    return stochasticprogram
end
StochasticProgram(sampler::AbstractSampler; solver = JuMP.UnsetSolver(), procs = workers()) = StochasticProgram(nothing,sampler; solver = solver, procs = procs)
function StochasticProgram(common::Any,sampler::AbstractSampler; solver = JuMP.UnsetSolver(), procs = workers())
    stochasticprogram = JuMP.Model()
    stochasticprogram.ext[:SP] = StochasticProgramData(common,sampler,procs)
    stochasticprogram.ext[:SP].spsolver.solver = solver
    # Set hooks
    JuMP.setsolvehook(stochasticprogram, _solve)
    JuMP.setprinthook(stochasticprogram, _printhook)
    # Return stochastic program
    return stochasticprogram
end

function _solve(stochasticprogram::JuMP.Model; suppress_warnings=false, solver = JuMP.UnsetSolver(), kwargs...)
    haskey(stochasticprogram.ext,:SP) || error("The given model is not a stochastic program.")
    if length(subproblems(stochasticprogram)) != length(scenarios(stochasticprogram))
        generate!(stochasticprogram)
    end
    # Prefer cached solver if available
    supplied_solver = pick_solver(stochasticprogram,solver)
    # Switch on solver type
    if supplied_solver isa MathProgBase.AbstractMathProgSolver
        # Standard mathprogbase solver. Fallback to solving DEP, relying on JuMP.
        dep = DEP(stochasticprogram,optimsolver(supplied_solver))
        status = solve(dep; kwargs...)
        fill_solution!(stochasticprogram)
        return status
    elseif supplied_solver isa AbstractStructuredSolver
        # Use structured solver
        structuredmodel = StructuredModel(supplied_solver,stochasticprogram; kwargs...)
        stochasticprogram.internalModel = structuredmodel
        stochasticprogram.internalModelLoaded = true
        status = optimize_structured!(structuredmodel)
        fill_solution!(structuredmodel,stochasticprogram)
        return status
    else
        error("Unknown solver object given. Aborting.")
    end
end

function _printhook(io::IO, stochasticprogram::JuMP.Model)
    print(io, "First-stage \n")
    print(io, "============== \n")
    print(io, stochasticprogram, ignore_print_hook=true)
    print(io, "\nSecond-stage \n")
    print(io, "============== \n")
    for (id, subproblem) in enumerate(subproblems(stochasticprogram))
        @printf(io, "Subproblem %d:\n", id)
        print(io, subproblem)
        print(io, "\n")
    end
end

function set_spsolver(stochasticprogram::JuMP.Model,spsolver::Union{MathProgBase.AbstractMathProgSolver,AbstractStructuredSolver})
    haskey(stochasticprogram.ext,:SP) || error("The given model is not a stochastic program.")
    stochasticprogram.ext[:SP].spsolver.solver = spsolver
    nothing
end

# ========================== #

# Getters #
# ========================== #
function stochastic(stochasticprogram::JuMP.Model)
    haskey(stochasticprogram.ext,:SP) || error("The given model is not a stochastic program.")
    return stochasticprogram.ext[:SP]
end
function scenarioproblems(stochasticprogram::JuMP.Model)
    haskey(stochasticprogram.ext,:SP) || error("The given model is not a stochastic program.")
    return stochasticprogram.ext[:SP].scenarioproblems
end
function stage(stochasticprogram::JuMP.Model,i::Integer)
    haskey(stochasticprogram.ext,:SP) || error("The given model is not a stochastic program.")
    return stochasticprogram.ext[:SP].stage.data
end
function common(scenarioproblems::ScenarioProblems)
    return scenarioproblems.commondata.data
end
function scenario(scenarioproblems::ScenarioProblems{D,SD,S},i::Integer) where {D, SD <: AbstractScenarioData, S <: AbstractSampler{SD}}
    return scenarioproblems.scenariodata[i]
end
function scenario(scenarioproblems::DScenarioProblems{D,SD,S},i::Integer) where {D, SD <: AbstractScenarioData, S <: AbstractSampler{SD}}
    j = 0
    for p in 1:length(scenarioproblems)
        n = remotecall_fetch((sp)->length(fetch(sp).scenariodata),p+1,scenarioproblems[p])
        if i <= n+j
            return remotecall_fetch((sp,i)->fetch(sp).scenariodata[i],p+1,scenarioproblems[p],i-j)
        end
        j += n
    end
    throw(BoundsError(scenarioproblems,i))
end
function scenario(stochasticprogram::JuMP.Model,i::Integer)
    haskey(stochasticprogram.ext,:SP) || error("The given model is not a stochastic program.")
    return scenario(scenarioproblems(stochasticprogram),i)
end
function scenarios(scenarioproblems::ScenarioProblems{D,SD,S}) where {D, SD <: AbstractScenarioData, S <: AbstractSampler{SD}}
    return scenarioproblems.scenariodata
end
function scenarios(scenarioproblems::DScenarioProblems{D,SD,S}) where {D, SD <: AbstractScenarioData, S <: AbstractSampler{SD}}
    scenarios = Vector{SD}()
    for p in 1:length(scenarioproblems)
        append!(scenarios,remotecall_fetch((sp)->fetch(sp).scenariodata,
                                           p+1,
                                           scenarioproblems[p]))
    end
    return scenarios
end
function scenarios(stochasticprogram::JuMP.Model)
    haskey(stochasticprogram.ext,:SP) || error("The given model is not a stochastic program.")
    return scenarios(scenarioproblems(stochasticprogram))
end
function probability(stochasticprogram::JuMP.Model,i::Integer)
    haskey(stochasticprogram.ext,:SP) || error("The given model is not a stochastic program.")
    return probability(scenario(stochasticprogram,i))
end
function has_generator(stochasticprogram::JuMP.Model,key::Symbol)
    haskey(stochasticprogram.ext,:SP) || error("The given model is not a stochastic program.")
    return haskey(stochasticprogram.ext[:SP].generator,key)
end
function generator(stochasticprogram::JuMP.Model,key::Symbol)
    haskey(stochasticprogram.ext,:SP) || error("The given model is not a stochastic program.")
    return stochasticprogram.ext[:SP].generator[key]
end
function subproblem(scenarioproblems::ScenarioProblems{D,SD,S},i::Integer) where {D, SD <: AbstractScenarioData, S <: AbstractSampler{SD}}
    return scenarioproblems.problems[i]
end
function subproblem(scenarioproblems::DScenarioProblems{D,SD,S},i::Integer) where {D, SD <: AbstractScenarioData, S <: AbstractSampler{SD}}
    j = 0
    for p in 1:length(scenarioproblems)
        n = remotecall_fetch((sp)->length(fetch(sp).scenariodata),p+1,scenarioproblems[p])
        if i <= n+j
            return remotecall_fetch((sp,i)->fetch(sp).problems[i],p+1,scenarioproblems[p],i-j)
        end
        j += n
    end
    throw(BoundsError(scenarioproblems,i))
end
function subproblem(stochasticprogram::JuMP.Model,i::Integer)
    haskey(stochasticprogram.ext,:SP) || error("The given model is not a stochastic program.")
    return subproblem(scenarioproblems(stochasticprogram),i)
end
function subproblems(scenarioproblems::ScenarioProblems{D,SD,S}) where {D, SD <: AbstractScenarioData, S <: AbstractSampler{SD}}
    return scenarioproblems.problems
end
function subproblems(scenarioproblems::DScenarioProblems{D,SD,S}) where {D, SD <: AbstractScenarioData, S <: AbstractSampler{SD}}
    subproblems = Vector{JuMP.Model}()
    for p in 1:length(scenarioproblems)
        append!(subproblems,remotecall_fetch((sp)->fetch(sp).problems,
                                             p+1,
                                             scenarioproblems[p]))
    end
    return subproblems
end
function subproblems(stochasticprogram::JuMP.Model)
    haskey(stochasticprogram.ext,:SP) || error("The given model is not a stochastic program.")
    return subproblems(scenarioproblems(stochasticprogram))
end
function parentmodel(scenarioproblems::ScenarioProblems)
    return scenarioproblems.parent
end
function parentmodel(scenarioproblems::DScenarioProblems)
    length(scenarioproblems) > 0 || error("No remote scenario problems.")
    return fetch(scenarioproblems[1]).parent
end
function masterterms(stochasticprogram::JuMP.Model,i::Integer)
    haskey(stochasticprogram.ext,:SP) || error("The given model is not a stochastic program.")
    return subproblems(scenarioproblems(stochasticprogram),i)
end
function nscenarios(scenarioproblems::ScenarioProblems{D,SD,S}) where {D, SD <: AbstractScenarioData, S <: AbstractSampler{SD}}
    return length(scenarioproblems.problems)
end
function nscenarios(scenarioproblems::DScenarioProblems{D,SD,S}) where {D, SD <: AbstractScenarioData, S <: AbstractSampler{SD}}
    return sum([remotecall_fetch((sp) -> length(fetch(sp).problems),
                                 p+1,
                                 scenarioproblems[p]) for p in 1:length(scenarioproblems)])
end
function nscenarios(stochasticprogram::JuMP.Model)
    haskey(stochasticprogram.ext,:SP) || error("The given model is not a stochastic program.")
    return nscenarios(scenarioproblems(stochasticprogram))
end
problemcache(stochasticprogram::JuMP.Model) = stochasticprogram.ext[:SP].problemcache
function spsolver(stochasticprogram::JuMP.Model)
    haskey(stochasticprogram.ext,:SP) || error("The given model is not a stochastic program.")
    return stochasticprogram.ext[:SP].spsolver.solver
end
function optimal_decision(stochasticprogram::JuMP.Model)
    haskey(stochasticprogram.ext,:SP) || error("The given model is not a stochastic program.")
    decision = stochasticprogram.colVal
    if any(isnan.(decision))
        warn("Optimal decision not defined. Check that the model was properly solved.")
    end
    return decision
end
function optimal_decision(stochasticprogram::JuMP.Model,i::Integer)
    haskey(stochasticprogram.ext,:SP) || error("The given model is not a stochastic program.")
    submodel = subproblem(stochasticprogram,i)
    decision = submodel.colVal
    if any(isnan.(decision))
        warn("Optimal decision not defined in subproblem $i. Check that the model was properly solved.")
    end
    return decision
end
function optimal_decision(stochasticprogram::JuMP.Model,var::Symbol)
    haskey(stochasticprogram.ext,:SP) || error("The given model is not a stochastic program.")
    return getvalue(stochasticprogram.objDict[var])
end
function optimal_value(stochasticprogram::JuMP.Model)
    haskey(stochasticprogram.ext,:SP) || error("The given model is not a stochastic program.")
    return stochasticprogram.objVal
end
# ========================== #

# Base overloads
# ========================== #
function Base.push!(sp::ScenarioProblems{D,SD},sdata::SD) where {D,SD <: AbstractScenarioData}
    push!(sp.scenariodata,sdata)
end
function Base.push!(sp::DScenarioProblems{D,SD},sdata::SD) where {D,SD <: AbstractScenarioData}
    p = rand(1:length(sp))
    remotecall_fetch((sp,sdata) -> push!(fetch(sp).scenariodata,sdata),
                     p+1,
                     sp[p],
                     sdata)
end
function Base.push!(stochasticprogram::JuMP.Model,sdata::AbstractScenarioData)
    haskey(stochasticprogram.ext,:SP) || error("The given model is not a stochastic program.")

    push!(stochastic(stochasticprogram).scenarioproblems,sdata)
    invalidate_cache!(stochasticprogram)
    return stochasticprogram
end
function Base.append!(sp::ScenarioProblems{D,SD},sdata::Vector{SD}) where {D,SD <: AbstractScenarioData}
    append!(sp.scenariodata,sdata)
end
function Base.append!(sp::DScenarioProblems{D,SD},sdata::Vector{SD}) where {D,SD <: AbstractScenarioData}
    p = rand(1:length(sp))
    remotecall_fetch((sp,sdata) -> append!(fetch(sp).scenariodata,sdata),
                     p+1,
                     sp[p],
                     sdata)
end
function Base.append!(stochasticprogram::JuMP.Model,sdata::Vector{<:AbstractScenarioData})
    haskey(stochasticprogram.ext,:SP) || error("The given model is not a stochastic program.")

    append!(stochastic(stochasticprogram).scenarioproblems,sdata)
    invalidate_cache!(stochasticprogram)
    return stochasticprogram
end
# ========================== #
