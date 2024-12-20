"""
A `Virtual` (component) is a component that does not exist in the model, but one that a user might expect to exist.
These are "components" that refer to a template. If a user creates a component "my_storage_foo", of type "Battery", they
might expect (and want) to be able to interact with "my_storage_foo". Since the template is flattened into explicit
`CoreComponent`s in the back, "my_storage_foo" does not actually exist - a problem that these `Virtual`s solve.
"""
@kwdef struct Virtual <: _CoreComponent
    # [Core] ===========================================================================================================
    model::JuMP.Model

    # [Mandatory] ======================================================================================================
    name::_String
    type::_String  # The actual type of the component, e.g., "Battery".

    # [Optional] =======================================================================================================
    config::Dict{String, Any} = Dict()

    # [Internal] =======================================================================================================
    _parameters = Dict{String, Any}()
    _finalizers::Vector{Function} = Function[]
    _template::CoreTemplate

    # [External] =======================================================================================================
    # -

    # [Optimization Container] =========================================================================================
    _ccoc = _CoreComponentOptContainer()

    # `_ccoc` is kept as container, since that allows attaching stuff directly to the `Virtual`, e.g., in addons.
end

_result_fields(::Virtual) = (:name, :type)

_check(::Virtual) = true
_prepare!(::Virtual) = true
_isvalid(::Virtual) = true
_setup!(::Virtual) = true

_build_priority(::Virtual) = -1  # This means that `Virtual`s are not built.

@recompile_invalidations begin
    function Base.getproperty(virtual::Virtual, field::Symbol)
        try
            (field == :var) && (return getfield(virtual, :_ccoc).variables)
            (field == :con) && (return getfield(virtual, :_ccoc).constraints)
            (field == :exp) && (return getfield(virtual, :_ccoc).expressions)
            (field == :obj) && (return getfield(virtual, :_ccoc).objectives)

            parameters = getfield(virtual, :_parameters)
            model = getfield(virtual, :model)

            # Helper functions for "object-oriented" calling inside templates.
            (field == :get) && (return (p, args...) -> _get_parameter_safe(p, parameters, args...))
            (field == :set) && (return (p::String, v::Any) -> _set_parameter_safe(p, v, parameters))
            (field == :get_ts) && (return (p, args...) -> _get_timeseries_safe(p, parameters, model))
            (field == :set_ts) && (return (p::String, v::Any) -> _set_timeseries_safe(p, v, parameters, model))

            # See if we may be trying to find a component that is "inside" this Virtual?
            cname = "$(getfield(virtual, :name)).$field"
            haskey(internal(model).model.components, cname) && return get_component(model, cname)

            return getfield(virtual, field)
        catch e
            @error "Field not found in Virtual" e
            return nothing
        end
    end

    function Base.setproperty!(virtual::Virtual, field::Symbol, value)
        if field in [:get, :set, :get_ts, :set_ts]
            @error "Field name is reserved for internal use of Virtual" name = virtual.name field
            return nothing
        end

        return setfield!(virtual, field, value)
    end

    function Base.propertynames(virtual::Virtual)
        prefix = "$(getfield(virtual, :name))."
        sub_components = Symbol[]
        for cname in keys(internal(virtual.model).model.components)
            startswith(cname, prefix) || continue
            push!(sub_components, Symbol(split(cname, prefix)[2]))
        end

        return (:model, :name, :type, :exp, :var, :con, :obj, sub_components...)
    end
end
