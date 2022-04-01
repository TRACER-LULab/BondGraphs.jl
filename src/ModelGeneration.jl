"""

Remove Algebraic Constraint Equations Generated by ModelingToolkit

"""
function remove_algebraic(BG::AbstractBondGraph, model)
    ## Remove Algebraic Constraint Equation
    # model = structural_simplify(model)
    filter(eq -> eq.lhs isa Int64, full_equations(model))
    eqns = full_equations(model)
    subs_dict = Dict{Term, Any}()
    obs_eqns = Equation[]
    while length(filter(eq -> eq.lhs isa Int64, eqns)) > 0
        state_var_nodes = filter_vertices(BG.graph, (g, v) -> has_prop(g, v, :state_var)) |> collect
        state_vars = vcat(map(v -> get_prop(BG.graph, v, :state_var), state_var_nodes)...)
        for eqn_index ∈ eachindex(eqns)
            eqn = eqns[eqn_index]
            if (eqn.lhs == 0) isa Bool
                vars = get_variables(eqn)
                terms = filter(x -> isa(x, Term), vars)
                # find the extra variables, not a state variable
                for term_index ∈ eachindex(terms)
                    is_state = false
                    for sv ∈ state_vars
                        if isa(sv - terms[term_index] == 0, Bool)
                            is_state = true
                            break
                        end
                    end
                    if !is_state
                        eqn = flatten_fractions(expand(eqn.rhs))
                        if hasfield(typeof(eqn), :den)
                            eqn = 0 ~ eqn.num
                        else
                            eqn = 0 ~ eqn
                        end
                        res = Symbolics.solve_for(eqn, terms[term_index])
                        subs_dict[terms[term_index]] = res
                        # Apply to full_equations
                        push!(obs_eqns, terms[term_index] ~ res)
                        popat!(eqns, eqn_index)
                        eqns = map(eqn -> substitute(eqn, subs_dict), eqns)
                        eqns = simplify_fractions.(expand.(eqns))
                        # Remove algebraic equation
                        # Update subs_dict
                        for (k, v) in pairs(subs_dict)
                            subs_dict[k] = simplify_fractions(substitute(v, subs_dict))
                        end
                        break
                    end
                end
                break
            end
        end
    end
    state_vars = vcat(get_variables.(getfield.(eqns, :lhs))...)
    ode_model = ODESystem(eqns, model.iv, name = model.name)
    return ode_model, obs_eqns
end

"""

Traverse the BondGraph Structure to create an ODESystem

"""
function graph_to_model(BG::AbstractBondGraph)
    # Find all One Junction Nodes
    @named model = ODESystem([], BG.model.iv)
    one_junctions = filter_vertices(BG.graph, (g, v) -> get_prop(g, v, :type) ∈ [:J1])
    eqns = Equation[]
    for J1 ∈ one_junctions
        out_nodes = outneighbors(BG.graph, J1)
        in_nodes = inneighbors(BG.graph, J1)
        if !isempty(out_nodes)
            out_sum = sum(x -> BG[x].e, out_nodes)
        else
            out_sum = 0
        end
        if !isempty(in_nodes)
            in_sum = sum(x -> BG[x].e, in_nodes)
        else
            in_sum = 0
        end
        push!(eqns, 0 ~ in_sum - out_sum)
        nodes = [out_nodes; in_nodes]
        for i ∈ 2:length(nodes)
            push!(eqns, BG[nodes[i-1]].f ~ BG[nodes[i]].f)
        end
    end
    # Find all Zero Junction Nodes
    zero_junctions = filter_vertices(BG.graph, (g, v) -> get_prop(g, v, :type) ∈ [:J0])
    for J0 ∈ zero_junctions
        out_nodes = outneighbors(BG.graph, J0)
        in_nodes = inneighbors(BG.graph, J0)
        if !isempty(out_nodes)
            out_sum = sum(x -> BG[x].f, out_nodes)
        else
            out_sum = 0
        end
        if !isempty(in_nodes)
            in_sum = sum(x -> BG[x].f, in_nodes)
        else
            in_sum = 0
        end
        push!(eqns, 0 ~ in_sum - out_sum)
        nodes = [out_nodes; in_nodes]
        for i ∈ 2:length(nodes)
            push!(eqns, BG[nodes[i-1]].e ~ BG[nodes[i]].e)
        end
    end
    @named junc_sys = ODESystem(eqns, model.iv, [], [])
    model = extend(model, junc_sys)

    two_ports = filter_vertices(BG.graph, (g, v) -> get_prop(g, v, :type) ∈ [:Re, :TF, :GY, :MTF, :MGY])
    two_ports_sys = map(v -> get_prop(BG.graph, v, :sys), two_ports)
    for sys ∈ two_ports_sys
        model = compose(model, sys)
    end

    element_verts = filter_vertices(BG.graph, (g, v) -> get_prop(g, v, :type) ∈ [:B, :R, :C, :I, :M, :Ce, :Se, :Sf, :MPC, :MPI, :MPR])
    element_sys = map(v -> get_prop(BG.graph, v, :sys), element_verts)
    model = compose(model, element_sys...)
    model = extend(BG.model, model)

    IP_verts = filter_vertices(BG.graph, (g, v) -> get_prop(g, v, :type) ∈ [:IP])
    eqns = equations(model)
    substitutions = vcat(map(v->get_prop(BG.graph, v, :subs), IP_verts)...)
    display(substitutions)
    eqns = substitute.(eqns, (Dict(substitutions), ))
    model = ODESystem(eqns, model.iv, name = model.name)
end

"""

Generate an ODE System from the BondGraph Structure

"""
function generate_model!(BG::AbstractBondGraph)
    BG.model = generate_model(BG)
end

function generate_model(BG::AbstractBondGraph)
    model = graph_to_model(BG)
end

function generate_model(BG::BioBondGraph)
    model = graph_to_model(BG)
    model = structural_simplify(model)
    RW = SymbolicUtils.Rewriters
    r1 = @acrule log(~x) + log(~y) => log((~x) * (~y))
    r2 = @rule log(~x) - log(~y) => log((~x) / (~y))
    r3 = @rule (~x) * log(~y) => log((~y)^(~x))
    r4 = @rule exp(log(~x)) => ~x
    r5 = @acrule exp((~x) + (~y)) => exp(~x) * exp(~y)
    rw1 = RW.Fixpoint(RW.Chain([r1, r2, r3, r4, r5]))
    rw2 = RW.Prewalk(RW.Chain([r1, r2, r3, r4, r5]))
    rw3 = RW.Postwalk(RW.Chain([r1, r2, r3, r4, r5]))
    eqns = full_equations(model)
    for i ∈ eachindex(eqns)
        eqns[i] = eqns[i].lhs ~ eqns[i].rhs |> rw3 |> rw2 |> rw1 |> expand
    end
    defaults = model.defaults
    model = ODESystem(eqns, model.iv, states(model), parameters(model), name = nameof(model), observed = observed(model), defaults = defaults)
    return structural_simplify(model)
end

function generate_model!(BG::BioBondGraph)
    BG.model = generate_model(BG)
end