"""
    IESopt

A general purpose solver agnostic energy system optimization framework.
"""
module IESopt

using PrecompileTools: @setup_workload, @compile_workload, @recompile_invalidations

# See: https://discourse.julialang.org/t/base-docs-doc-failing-with-1-11-0/121187
# This is a workaround for an issue introduced by Julia 1.11.0, and seems to now be necessary to use `Base.Docs`
import REPL

# Setup `IESoptLib.jl` and `HiGHS.jl`.
import IESoptLib
const Library = IESoptLib
import HiGHS

# Constant paths that might be used somewhere.
const _dummy_path = normpath(@__DIR__, "utils", "dummy")
const _PATHS = Dict{Symbol, String}(
    :src => normpath(@__DIR__),
    :addons => isnothing(Library) ? _dummy_path : Library.get_path(:addons),
    :examples => isnothing(Library) ? _dummy_path : Library.get_path(:examples),
    :docs => normpath(@__DIR__, "..", "docs"),
    :test => normpath(@__DIR__, "..", "test"),
    :templates => isnothing(Library) ? _dummy_path : Library.get_path(:templates),
)

# Currently we have a proper automatic resolver for the following solver interfaces:
const _ALL_SOLVER_INTERFACES = ["HiGHS", "Gurobi", "Cbc", "GLPK", "CPLEX", "Ipopt", "SCIP"]

# Required for logging, validation, and suppressing unwanted output.
using Logging
import LoggingExtras
using Suppressor
import ArgCheck

# Used to "hotload" code (e.g., addons, Core Templates).
using RuntimeGeneratedFunctions

# Used to parse expressions from strings (over using `Meta.parse`).
import JuliaSyntax

# Required during the "build" step, showing progress.
using ProgressMeter

using OrderedCollections

# Required to generate dynamic docs of Core Components.
import Base.Docs
import Markdown

# Everything JuMP / optimization related.
import JuMP, JuMP.@variable, JuMP.@expression, JuMP.@constraint, JuMP.@objective
import MultiObjectiveAlgorithms as MOA
const MOI = JuMP.MOI

# File (and filesystem/git) and data format handling.
import YAML
import JSON
import SentinelArrays, InlineStrings, CSV  # NOTE: The first two only help with precompilation of CSV.
import DataFrames
import JLD2
import LibGit2
import ZipFile

# Used in Benders/Stochastic.
import Printf
import Dates

_is_precompiling() = ccall(:jl_generating_output, Cint, ()) == 1

include("utils/utils.jl")
include("config/config.jl")
include("core.jl")
include("parser.jl")
# include("opt/opt.jl")
include("results/results.jl")
include("validation/validation.jl")
include("templates/templates.jl")
# include("texify/texify.jl")

function _build_model!(model::JuMP.Model)
    if _iesopt_config(model).optimization.high_performance
        if model.set_string_names_on_creation
            @info "Overwriting `string_names_on_creation` to `false` since `high_performance` is set"
        end
        JuMP.set_string_names_on_creation(model, false)
    end

    # This specifies the order in which components are built. This ensures that model parts that are used later on, are
    # already initialized (e.g. constructing a constraint may use expressions and variables).
    build_order = [
        _setup!,
        _construct_expressions!,
        _after_construct_expressions!,
        _construct_variables!,
        _after_construct_variables!,
        _construct_constraints!,
        _after_construct_constraints!,
        _construct_objective!,
    ]::Vector{Function}

    # TODO: care about components/global addons returning false somewhere

    @info "Preparing components"

    # Sort components by their build priority.
    # For instance, Decisions with a default build priority of 1000 are built before all other components
    # with a default build priority of 0.
    # Components with a negative build priority are not built at all.
    corder = sort(collect(values(_iesopt(model).model.components)); by=_build_priority, rev=true)::Vector{<:_CoreComponent}

    @info "Start creating JuMP model"
    for f in build_order
        # for component in corder
        #     if _build_priority(component) >= 0
        #         _iesopt(model).debug = component.name
        #         f(component)
        #     end
        # end

        # Construct all components, building them in the necessary order.
        progress_map(
            corder;
            mapfun=foreach,
            progress=Progress(length(corder); enabled=_iesopt_config(model).progress::Bool, desc="$(Symbol(f)) ..."),
        ) do component
            if _build_priority(component) >= 0
                _iesopt(model).debug = component.name
                f(component)::Nothing
            end
        end

        # Call global addons
        if _has_addons(model)
            addon_fi = Symbol(string(f)[2:end])
            for (name, prop) in _iesopt(model).input.addons
                # Only execute a function if it exists.
                if addon_fi in names(prop.addon; all=true)
                    @info "Invoking addon" addon = name step = addon_fi
                    if !Base.invokelatest(getfield(prop.addon, addon_fi), model, prop.config)
                        @critical "Addon returned error" addon = name step = addon_fi
                    end
                end
            end
        end
    end

    @info "Finalizing Virtuals"
    for component in corder
        component isa Virtual || continue
        finalizers = component._finalizers::Vector{Function}
        for i in reverse(eachindex(finalizers))
            finalizers[i](component)
        end
    end

    # Construct relevant ETDF constraints.
    if !isempty(_iesopt(model).aux.etdf.groups)
        @error "ETDF constraints are currently not supported"
        # for (etdf_group, node_ids) in _iesopt(model).aux.etdf.groups
        #     _iesopt(model).aux.etdf.constr[etdf_group] = @constraint(
        #         model,
        #         [t = get_T(model) ],
        #         sum(_iesopt(model).model.components[id].exp.injection[t] for id in node_ids) == 0
        #     )
        # end
    end

    # Building the objective(s).
    for (name, obj) in _iesopt(model).model.objectives
        @info "Preparing objective" name

        # Add all terms that were added from within a component definition to the correct objective's terms.
        for term in _iesopt(model).aux._obj_terms[name]
            if term isa Number
                push!(obj.constants, term)
            else
                comp, proptype, prop = rsplit(term, "."; limit=3)
                field = getproperty(getproperty(get_component(model, comp), Symbol(proptype)), Symbol(prop))
                if field isa Vector
                    push!(obj.terms, sum(field))
                else
                    push!(obj.terms, field)
                end
            end
        end

        # todo: is there a faster way to sum up a set of expressions?
        @info "Building objective" name
        for term in obj.terms
            JuMP.add_to_expression!(obj.expr, term)
        end
        if !isempty(obj.constants)
            JuMP.add_to_expression!(obj.expr, sum(obj.constants))
        end
    end

    if !_is_multiobjective(model)
        current_objective = _iesopt_config(model).optimization.objective.current
        isnothing(current_objective) && @critical "Missing an active objective"
        @objective(model, Min, _iesopt(model).model.objectives[current_objective].expr)
    else
        @objective(
            model,
            Min,
            [
                _iesopt(model).model.objectives[obj].expr for
                obj in _iesopt_config(model).optimization.multiobjective.terms
            ]
        )
    end
end

function _prepare_model!(model::JuMP.Model)
    # Potentially remove components that are tagged `conditional`, and violate some of their conditions.
    failed_components = []
    for (cname, component) in _iesopt(model).model.components
        !_check(component) && push!(failed_components, cname)
    end
    if length(failed_components) > 0
        @warn "Some components are removed based on the `conditional` setting" n_components = length(failed_components)
        for cname in failed_components
            delete!(_iesopt(model).model.components, cname)
        end
    end

    # Init global addons before preparing components
    if _has_addons(model)
        for (name, prop) in _iesopt(model).input.addons
            if !Base.invokelatest(prop.addon.initialize!, model, prop.config)
                @critical "Addon failed to set up" name
            end
        end
    end

    # Fully prepare each component.
    all_components_ok = true
    for (id, component) in _iesopt(model).model.components
        all_components_ok &= _prepare!(component)
    end
    if !all_components_ok
        error("Some components did not pass the preparation step.")
    end
end

"""
    run(filename::String; verbosity=nothing, kwargs...)

Build, optimize, and return a model.

# Arguments

- `filename::String`: The path to the top-level configuration file.
- `verbosity`: The verbosity level to use. Supports `true` (= verbose mode), `"warning"` (= warnings and above), and
  `false` (suppressing logs).

If `verbosity = true`, the verbosity setting of the solver defaults to `true` as well, otherwise it defaults to `false`
(the verbosity setting of the solver can also be directly controled using the `verbosity_solve` setting in the top-level
config file).

# Keyword Arguments

Keyword arguments are passed to the [`generate!`](@ref) function.
"""
function run(filename::String; @nospecialize(verbosity=nothing), @nospecialize(kwargs...))
    model = generate!(filename; verbosity=verbosity, kwargs...)
    if haskey(model.ext, :_iesopt_failed_generate)
        @error "Errors in model generation; skipping optimization"
        delete!(model.ext, :_iesopt_failed_generate)
        return model
    end

    try
        optimize!(model)
    catch
        @error "Errors in model optimization"
    end

    return model
end

"""
    generate!(filename::String)

Builds and returns a model using the IESopt framework.

This loads the configuration file specified by `filename`. Requires full specification of the `solver` entry in config.
"""
function generate!(filename::String; @nospecialize(kwargs...))
    model = JuMP.Model()::JuMP.Model
    generate!(model, filename; kwargs...)
    return model::JuMP.Model
end

"""
    generate!(model::JuMP.Model, filename::String)

Builds a model using the IESopt framework, "into" the provided `model`.

This loads the configuration file specified by `filename`. Be careful when creating your `model` in any other way than
in the provided examples, as this can conflict with IESopt internals (especially for model/optimizer combinations
that do not support bridges). Returns the model for convenience, even though it is modified in place.
"""
function generate!(model::JuMP.Model, filename::String; @nospecialize(kwargs...))
    # local stats_parse, stats_build, stats_total
    # TODO: "re-enable" by refactoring to TimerOutputs

    try
        # Validate before parsing.
        # !validate(filename) && return nothing

        # Parse & build the model.
        parse!(model, filename; kwargs...) || return model
        with_logger(_iesopt_logger(model)) do
            if JuMP.mode(model) != JuMP.DIRECT && JuMP.MOIU.state(JuMP.backend(model)) == JuMP.MOIU.NO_OPTIMIZER
                _attach_optimizer(model)
            end

            build!(model)

            @info "Finished model generation"
        end

        model.ext[:_iesopt_failed_generate] = false

        # NOTE: See below for "timed" sections.
        # stats_total = @timed begin
        #     stats_parse = @timed parse!(model, filename; kwargs...)
        #     !stats_parse.value && return model
        #     if JuMP.mode(model) != JuMP.DIRECT && JuMP.MOIU.state(JuMP.backend(model)) == JuMP.MOIU.NO_OPTIMIZER
        #         with_logger(_iesopt_logger(model)) do
        #             return _attach_optimizer(model)
        #         end
        #     end
        #     stats_build = @timed with_logger(_iesopt_logger(model)) do
        #         return build!(model)
        #     end
        # end
    catch
        # Get debug information from model, if available.
        debug = haskey(model.ext, :iesopt) ? _iesopt(model).debug : "not available"
        debug = isnothing(debug) ? "not available" : debug

        # Get ALL current exceptions.
        curr_ex = current_exceptions()

        # These modules are automatically removed from the backtrace that is shown.
        remove_modules = [:VSCodeServer, :Base, :CoreLogging]

        # Prepare all exceptions.
        _exceptions = []
        for (exception, backtrace) in curr_ex
            trace = stacktrace(backtrace)

            # Debug log the full backtrace.
            @debug "Details on error #$(length(_exceptions) + 1)" error = (exception, trace)

            # Error log the backtrace, but remove modules that only clutter the trace.
            trace = [e for e in trace if !isnothing(parentmodule(e)) && !(nameof(parentmodule(e)) in remove_modules)]
            push!(
                _exceptions,
                Symbol(" = = = = = = = = = [ Error #$(length(_exceptions) + 1) ] = = = = = = = =") =>
                    (exception, trace),
            )
        end

        @error "Error(s) during model generation" debug number_of_errors = length(curr_ex) _exceptions...
        model.ext[:_iesopt_failed_generate] = true
    else
        # with_logger(_iesopt_logger(model)) do
        #     @info "Finished model generation" times =
        #         (parse=stats_parse.time, build=stats_build.time, total=stats_total.time)
        # end
    end

    return model
end

_setoptnow(model::JuMP.Model, ::Val{:none}, moa::Bool) = @critical "This code should never be reached"

function _attach_optimizer(model::JuMP.Model)
    @info "Setting up Optimizer"

    solver_name = _iesopt_config(model).optimization.solver.name
    solver = get(
        Dict{String, Symbol}(
            "highs" => :HiGHS,
            "gurobi" => :Gurobi,
            "cbc" => :Cbc,
            "glpk" => :GLPK,
            "cplex" => :CPLEX,
            "ipopt" => :Ipopt,
            "scip" => :SCIP,
        ),
        lowercase(solver_name),
        :unknown,
    )::Symbol

    if solver == :unknown
        @critical "Can't determine proper solver" solver_name
    end

    if _iesopt_config(model).optimization.solver.mode == "direct"
        @critical "Automatic direct mode is currently not supported"
    end

    if solver == :HiGHS
        if _is_multiobjective(model)
            JuMP.set_optimizer(model, () -> IESopt.MOA.Optimizer(HiGHS.Optimizer))
        else
            JuMP.set_optimizer(model, HiGHS.Optimizer)
        end
    else
        try
            @info "Trying to import solver interface" solver
            # Main.eval(Meta.parse("import $(solver)"))
            Base.require(@__MODULE__, solver)
        catch
            rethrow(ErrorException("Failed to setup solver interface; please install it manually"))
            # @info "Solver interface could not be imported; trying to install and precompile it" solver
            # try
            #     Pkg.add(solver)
            #     Pkg.resolve()
            #     @info "Trying to import solver interface" solver
            #     Main.eval(Meta.parse("import $(solver)"))
            # catch
            #     @critical "Failed to setup solver interface; please install it manually" solver
            # end
            # @error "Solver interface installed, but you need to manually reload; please execute your code again"
            # rethrow(ErrorException("Please execute your code again"))
        end

        Base.retry_load_extensions()
        Base.invokelatest(_setoptnow, model, Val{solver}(), false)
    end

    if _is_multiobjective(model)
        moa_mode = _iesopt_config(model).optimization.multiobjective.mode
        @info "Setting MOA mode" mode = moa_mode
        JuMP.set_attribute(model, MOA.Algorithm(), eval(Meta.parse("MOA.$moa_mode()")))
    end

    for (attr, value) in _iesopt_config(model).optimization.solver.attributes
        try
            @suppress JuMP.set_attribute(model, attr, value)
            @info "Setting attribute" attr value
        catch
            @error "Failed to set attribute" attr value
        end
    end

    if !isnothing(_iesopt_config(model).optimization.multiobjective)
        for (attr, value) in _iesopt_config(model).optimization.multiobjective.settings
            try
                if value isa Vector
                    for i in eachindex(value)
                        JuMP.set_attribute(model, eval(Meta.parse("$attr($i)")), value[i])
                    end
                else
                    JuMP.set_attribute(model, eval(Meta.parse("$attr()")), value)
                end
                @info "Setting attribute" attr value
            catch
                @error "Failed to set attribute" attr value
            end
        end
    end

    return nothing
end

function parse!(model::JuMP.Model, filename::String; @nospecialize(kwargs...))
    if !endswith(filename, ".iesopt.yaml")
        @critical "Model entry config files need to respect the `.iesopt.yaml` file extension" filename
    end

    # Get all parameters that were passed directly from the caller.
    global_parameters = Dict{String, Any}(string(k) => v for (k, v) in kwargs)

    # Extract IESopt-internal arguments from `kwargs`.
    model.ext[:_iesopt_verbosity] = pop!(global_parameters, "verbosity", nothing)
    model.ext[:_iesopt_force_reload] = pop!(global_parameters, "force_reload", true)

    # Load the model specified by `filename`.
    _parse_model!(model, filename, global_parameters) || (@critical "Error while parsing model" filename)

    return true
end

function build!(model::JuMP.Model)
    # Prepare the model, ensuring some conversions before consistency checks.
    _prepare_model!(model)

    # Perform conistency checks on all parsed components.
    all_components_ok = true::Bool
    for (id, component) in _iesopt(model).model.components
        all_components_ok &= _isvalid(component)::Bool
    end
    if !all_components_ok
        error("Some components did not pass the consistency check.")
    end

    # Build the model.
    _build_model!(model)

    @info "Profiling results after `build` [time, top 5]" _profiling_format_top(model, 5)...
end

"""
    optimize!(model::JuMP.Model; save_results::Bool=true, kwargs...)

Use `JuMP.optimize!` to optimize the given model, optionally serializing the model afterwards for later use.
"""
function optimize!(model::JuMP.Model; @nospecialize(kwargs...))
    with_logger(_iesopt_logger(model)) do
        return _optimize!(model; kwargs...)
    end
end

function _optimize!(model::JuMP.Model; @nospecialize(kwargs...))
    if !isempty(_iesopt(model).aux.constraint_safety_penalties)
        @info "Relaxing constraints based on constraint_safety"
        _iesopt(model).aux.constraint_safety_expressions = JuMP.relax_with_penalty!(
            model,
            Dict(k => v.penalty for (k, v) in _iesopt(model).aux.constraint_safety_penalties),
        )
    end

    # Enable or disable solver output
    if _iesopt_config(model).verbosity_solve
        JuMP.unset_silent(model)
    else
        JuMP.set_silent(model)
    end

    # Logging solver output.
    if _iesopt_config(model).optimization.solver.log
        # todo: replace this with a more general approach
        try
            log_file = abspath(_iesopt_config(model).paths.results, "$(_iesopt_config(model).names.scenario).solverlog")
            rm(log_file; force=true)
            if JuMP.solver_name(model) == "Gurobi"
                @info "Logging solver output" log_file
                JuMP.set_attribute(model, "LogFile", log_file)
            elseif JuMP.solver_name(model) == "HiGHS"
                @info "Logging solver output" log_file
                JuMP.set_attribute(model, "log_file", log_file)
            else
                # todo: support MOA here
                @error "Logging solver output is currently only supported for Gurobi and HiGHS"
            end
        catch
            @error "Failed to setup solver log file"
        end
    end

    @info "Starting optimize ..."
    JuMP.optimize!(model; kwargs...)

    # todo: make use of `is_solved_and_feasible`? if, make sure the version requirement of JuMP is correct

    if JuMP.result_count(model) == 1
        if JuMP.termination_status(model) == JuMP.MOI.OPTIMAL
            @info "Finished optimizing, solution optimal"
        else
            @error "Finished optimizing, solution non-optimal" status_code = JuMP.termination_status(model) solver_status =
                JuMP.raw_status(model)
        end
    elseif JuMP.result_count(model) == 0
        @error "No results returned after call to `optimize!`. This most likely indicates an infeasible or unbounded model. You can check with `IESopt.compute_IIS(model)` which constraints make your model infeasible. Note: this requires a solver that supports this (e.g. Gurobi)"
        return nothing
    else
        if !isnothing(_iesopt_config(model).optimization.multiobjective)
            if JuMP.termination_status(model) == JuMP.MOI.OPTIMAL
                @info "Finished optimizing, solution(s) optimal" result_count = JuMP.result_count(model)
            else
                @error "Finished optimizing, solution non-optimal" status_code = JuMP.termination_status(model) solver_status =
                    JuMP.raw_status(model)
            end
        else
            @warn "Unexpected result count after call to `optimize!`" result_count = JuMP.result_count(model) status_code =
                JuMP.termination_status(model) solver_status = JuMP.raw_status(model)
        end
    end

    # Analyse constraint safety results
    if !isempty(_iesopt(model).aux.constraint_safety_penalties)
        relaxed_components = Vector{String}()
        for (k, v) in _iesopt(model).aux.constraint_safety_penalties
            # Skip components that we already know about being relaxed.
            (v.component_name ∈ relaxed_components) && continue

            if JuMP.value(_iesopt(model).aux.constraint_safety_expressions[k]) > 0
                push!(relaxed_components, v.component_name)
            end
        end

        if !isempty(relaxed_components)
            @warn "The safety constraint feature triggered" n_components = length(relaxed_components) components = "[$(relaxed_components[1]), ...]"
            @info "You can further analyse the relaxed components by looking at the `constraint_safety_penalties` and `constraint_safety_expressions` entries in `model.ext`."
        end
    end

    if _iesopt_config(model).results.enabled
        if !JuMP.is_solved_and_feasible(model)
            @error "Extracting results is only possible for a solved and feasible model"
        else
            _extract_results(model)
            _save_results(model)
        end
    end

    @info "Profiling results after `optimize` [time, top 5]" _profiling_format_top(model, 5)...
    return nothing
end

"""
    function compute_IIS(model::JuMP.Model; filename::String = "")

Compute the IIS and print it. If `filename` is specified it will instead write all constraints to the given file. This
will fail if the solver does not support IIS computation.
"""
function compute_IIS(model::JuMP.Model; filename::String="")
    print = false
    if filename === ""
        print = true
    end

    JuMP.compute_conflict!(model)
    conflict_constraint_list = JuMP.ConstraintRef[]
    for (F, S) in JuMP.list_of_constraint_types(model)
        for con in JuMP.all_constraints(model, F, S)
            if JuMP.MOI.get(model, JuMP.MOI.ConstraintConflictStatus(), con) == JuMP.MOI.IN_CONFLICT
                if print
                    println(con)
                else
                    push!(conflict_constraint_list, con)
                end
            end
        end
    end

    if !print
        io = open(filename, "w") do io
            for con in conflict_constraint_list
                println(io, con)
            end
        end
    end

    return nothing
end

"""
    function get_component(model::JuMP.Model, component_name::String)

Get the component `component_name` from `model`.
"""
function get_component(model::JuMP.Model, @nospecialize(component_name::AbstractString))
    cn = string(component_name)
    if !haskey(_iesopt(model).model.components, cn)
        st = stacktrace()
        trigger = length(st) > 0 ? st[1] : nothing
        origin = length(st) > 1 ? st[2] : nothing
        inside = length(st) > 2 ? st[3] : nothing
        @critical "Trying to access unknown component" component_name = cn trigger origin inside debug = _iesopt_debug(model)
    end

    return _iesopt(model).model.components[cn]
end

function get_components(model::JuMP.Model; @nospecialize(tagged::Union{Nothing, String, Vector{String}}=nothing))
    !isnothing(tagged) && return _components_tagged(model, tagged)::Vector{<:_CoreComponent}

    return collect(values(_iesopt(model).model.components))::Vector{<:_CoreComponent}
end

function _components_tagged(model::JuMP.Model, tag::String)
    cnames = get(_iesopt(model).model.tags, tag, String[])
    isempty(cnames) && return _CoreComponent[]
    return get_component.(model, cnames)::Vector{<:_CoreComponent}
end

function _components_tagged(model::JuMP.Model, tags::Vector{String})
    cnames = [get(_iesopt(model).model.tags, tag, String[]) for tag in tags]
    cnames = intersect(cnames...)
    isempty(cnames) && return _CoreComponent[]
    return get_component.(model, cnames)::Vector{<:_CoreComponent}
end

function extract_result(model::JuMP.Model, component_name::String, field::String; mode::String)
    return _result(get_component(model, component_name), mode, field)[2]
end

"""
    function to_table(model::JuMP.Model; path::String = "./out")

Turn `model` into a set of CSV files containing all core components that represent the model.

This can be useful by running
```julia
IESopt.parse!(model, filename)
IESopt.to_table(model)
```
which will parse the model given by `filename`, without actually building it (which saves a lot of time), and will
output a complete "description" in core components (that are the resolved version of all non-core components).

If `write_to_file` is `false` it will instead return a dictionary of all DataFrames.
"""
function to_table(model::JuMP.Model; path::String="./out", write_to_file::Bool=true)
    tables = Dict(
        Connection => Vector{OrderedDict{Symbol, Any}}(),
        Decision => Vector{OrderedDict{Symbol, Any}}(),
        Node => Vector{OrderedDict{Symbol, Any}}(),
        Profile => Vector{OrderedDict{Symbol, Any}}(),
        Unit => Vector{OrderedDict{Symbol, Any}}(),
    )

    for (id, component) in _iesopt(model).model.components
        push!(tables[typeof(component)], _to_table(component))
    end

    if write_to_file
        for (type, table) in tables
            CSV.write(normpath(_iesopt_config(model).paths.main, path, "$type.csv"), DataFrames.DataFrame(table))
        end
        return nothing
    end

    return Dict{Type, DataFrames.DataFrame}(type => DataFrames.DataFrame(table) for (type, table) in tables)
end

# This is directly taken from JuMP.jl and exports all internal symbols that do not start with an underscore (roughly).
const _EXCLUDE_SYMBOLS = [Symbol(@__MODULE__), :eval, :include]
for sym in names(@__MODULE__; all=true)
    sym_string = string(sym)
    if sym in _EXCLUDE_SYMBOLS || startswith(sym_string, "_") || startswith(sym_string, "@_")
        continue
    end
    if !(Base.isidentifier(sym) || (startswith(sym_string, "@") && Base.isidentifier(sym_string[2:end])))
        continue
    end
    @eval export $sym
end

RuntimeGeneratedFunctions.init(@__MODULE__)

include("precompile/precompile_tools.jl")
# include("precompile/precompile_manual.jl")

end
