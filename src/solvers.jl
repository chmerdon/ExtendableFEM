function get_unknown_id(SC::SolverConfiguration, u::Unknown)
    return findfirst(==(u), SC.unknowns)
end


"""
````
function solve(
    PD::ProblemDescription,
    FES,
    SC = nothing;
    unknowns = PD.unknowns,
    kwargs...)
````

Returns a solution of the PDE as an FEVector for the provided FESpace(s) FES (to be used to discretised the unknowns of the PDEs).

This function extends the CommonSolve.solve interface and the PDEDescription takes the role of
the ProblemType and FES takes the role of the SolverType.

Keyword arguments:
$(_myprint(default_solver_kwargs()))

Depending on the detected/configured nonlinearities the whole system is
either solved directly in one step or via a fixed-point iteration.

"""
function CommonSolve.solve(PD::ProblemDescription, FES::Dict{<:Unknown}, SC = nothing; unknowns = PD.unknowns, kwargs...)
    return solve(PD, [FES[u] for u in unknowns], SC; unknowns = unknowns, kwargs...)
end

function CommonSolve.solve(PD::ProblemDescription, SC = nothing; init = nothing, unknowns = PD.unknowns, kwargs...)
    if init === nothing
        @error "need to know initial FEVector or finite element spaces for unknowns of problem"
    end
    return solve(PD, [init[u].FES for u in unknowns], SC; init = init, unknowns = unknowns, kwargs...)
end


function CommonSolve.solve(PD::ProblemDescription, FES::Array, SC = nothing; unknowns = PD.unknowns, kwargs...)
    if typeof(SC) <: SolverConfiguration
        _update_params!(SC.parameters, kwargs)
        if SC.parameters[:verbosity] > 0
            @info ".... reusing given solver configuration\n"
        end
        time = 0
        allocs = 0
    else
        time = @elapsed begin
            allocs = @allocated begin
                SC = SolverConfiguration(PD, unknowns, FES; kwargs...)
                if SC.parameters[:verbosity] > 0
                    @info ".... init solver configuration\n"
                end
            end
        end
    end
    if SC.parameters[:verbosity] > -1
        @info "SOLVING $(PD.name)
            unknowns = $([u.name for u in unknowns])
            fetypes = $(["$(get_FEType(FES[j]))" for j = 1 : length(unknowns)])
            ndofs = $([FES[j].ndofs for j = 1 : length(unknowns)])"
    end

    if SC.parameters[:verbosity] > 0 || SC.parameters[:show_config]
        @info "\n$(SC)"
    end

    A = SC.A
    b = SC.b
    sol = SC.sol
    residual = SC.res
    method_linear = SC.parameters[:method_linear]
    precon_linear = SC.parameters[:precon_linear]

    ## unpack solver parameters
    maxits = SC.parameters[:maxiterations]
    @assert maxits > -1
    nltol = SC.parameters[:target_residual]
    is_linear = SC.parameters[:is_linear]
    damping = SC.parameters[:damping]

    ## check if problem is (non)linear
    nonlinear = false
    for op in PD.operators
        nl_dependencies = depends_nonlinearly_on(op)
        for u in unknowns
            if u in nl_dependencies
                nonlinear = true
                break
            end
        end
    end
    if SC.parameters[:verbosity] > -1
        @info " nonlinear = $(nonlinear ? "true" : "false")\n" 
    end
    if is_linear == "auto"
        is_linear = !nonlinear
    end
    if is_linear && nonlinear
        @warn "problem seems nonlinear, but user set is_linear = true (results may be wrong)!!"
    end
    if is_linear
        maxits = 0
    end

    alloc_factor = 1024^2

    if SC.parameters[:verbosity] > -1
        @printf " #IT\t------- RESIDUALS -------\t---- DURATION (s) ----\t\t---- ALLOCATIONS (MiB) ----\n" 
        @printf "   \tNONLINEAR\tLINEAR\t\tASSEMB\tSOLVE\tTOTAL\t\tASSEMB\tSOLVE\tTOTAL\n" 
        @printf " INI\t\t\t\t\t\t\t%.2f\t\t\t\t%.2f\n" time allocs/alloc_factor
    end
    time_final = time
    allocs_final = allocs
    nlres = 1.1e30
    linres = 1.1e30
    linsolve = SC.linsolver
    reduced = false

    for j = 1 : maxits+1
        allocs_assembly = 0
        time_assembly = 0
        time_total = 0
        if is_linear && j == 2
            nlres = linres
        else
            time_total += @elapsed begin
                fill!(b.entries, 0)
                fill!(A.entries.cscmatrix.nzval,0)

                ## assemble operators
                time_assembly += @elapsed for op in PD.operators
                    allocs_assembly += @allocated assemble!(A, b, sol, op, SC; time = SC.parameters[:time], kwargs...)
                end
                flush!(A.entries)

                # ## remove inactive dofs
                # for u_off in SC.parameters[:inactive]
                #     j = get_unknown_id(SC, u_off) 
                #     if j > 0
                #         fill!(A[j,j],0)
                #         FES = sol[j].FES
                #         for dof in 1:FES.ndofs
                #             A[j,j][dof, dof] = 1e60
                #             b[j][dof] = 1e60*sol[j][dof]
                #         end
                #     else
                #         @warn "inactive unknown $(u_off) not part of unknowns, skipping this one..."
                #     end
                # end

                ## reduction steps
                time_assembly += @elapsed begin
                    if length(PD.reduction_operators) > 0 && j == 1
                        LP_reduced = SC.LP
                        reduced = true
                        for op in PD.reduction_operators
                            allocs_assembly += @allocated LP_reduced, A, b = apply!(LP_reduced, op, SC; kwargs...)
                        end    
                        residual = deepcopy(b)
                    end
                end

                ## show spy

                if SC.parameters[:show_matrix]
                    @show A
                elseif SC.parameters[:spy]
                    @info ".... spy plot of system matrix:\n$(UnicodePlots.spy(sparse(A.entries.cscmatrix)))"
                end

                ## init solver
                if linsolve === nothing
                    if SC.parameters[:verbosity] > 0
                        @info ".... initializing linear solver ($(method_linear))\n" 
                    end
                    abstol = SC.parameters[:abstol]
                    reltol = SC.parameters[:reltol]
                    LP = reduced ? LP_reduced : SC.LP
                    if precon_linear !== nothing
                        linsolve = init(LP, method_linear; Pl = precon_linear(A.entries.cscmatrix), abstol = abstol, reltol = reltol)
                    else
                        linsolve = init(LP, method_linear; abstol = abstol, reltol = reltol)
                    end
                    SC.linsolver = linsolve
                end


                ## compute nonlinear residual
                if !is_linear
                    fill!(residual.entries, 0)
                    for j = 1 : length(b), k = 1 : length(b)
                        addblock_matmul!(residual[j], A[j,k], sol[unknowns[k]])
                    end
                    residual.entries .-= b.entries
                    #res = A.entries * sol.entries - b.entries
                    for op in PD.operators
                        residual.entries[fixed_dofs(op)] .= 0
                    end
                    for u_off in SC.parameters[:inactive]
                        j = get_unknown_id(SC, u_off) 
                        if j > 0
                            fill!(residual[j],0)
                        end
                    end
                    nlres = norm(residual.entries)
                end
            end
            time_final += time_assembly
            allocs_final += allocs_assembly
        end
        if nlres < nltol
            if SC.parameters[:verbosity] > -1
                @printf " END\t"
                @printf "%.3e\t" nlres
                @printf "\t\t%.2f\t\t%.2f\t" time_assembly time_total
                @printf "\t%.2f\t\t%.2f\n" allocs_assembly/alloc_factor allocs_assembly/alloc_factor
                @printf "\tconverged"
                @printf "\t\t\t\tSUM -->\t%.2f" time_final
                @printf "\t\t\tSUM -->\t%.2f\n\n" allocs_final/alloc_factor
            end
            break
        elseif (j == maxits + 1) && !(is_linear)
            if SC.parameters[:verbosity] > -1
                @printf " END\t"
                @printf "\t\t%.3e\t" linres
                @printf "\t\t%.2f\t\t%.2f\t" time_assembly time_total
                @printf "\t%.2f\t\t%.2f\n" allocs_assembly/alloc_factor allocs_assembly/alloc_factor
                @printf "\tmaxiterations reached"
                @printf "\t\t\tSUM -->\t%.2f" time_final
                @printf "\t\t\tSUM -->\t%.2f\n\n" allocs_final/alloc_factor
            end
            break
        else
            if SC.parameters[:verbosity] > -1
                if is_linear
                    @printf " END\t"
                else
                    @printf "%4d\t" j
                end
                if !(is_linear)
                    @printf "%.3e\t" nlres
                else
                    @printf "---------\t"
                end
            end
        end

        time_solve = @elapsed begin
            allocs_solve = @allocated begin
                linsolve.A = A.entries.cscmatrix
                linsolve.b = b.entries

                ## solve
                x = LinearSolve.solve(linsolve)
                SC.linsolver = linsolve

                fill!(residual.entries, 0)
                mul!(residual.entries, A.entries.cscmatrix, x.u)
                residual.entries .-= b.entries
                for op in PD.operators
                    for dof in fixed_dofs(op)
                        if dof <= length(residual.entries)
                            residual.entries[dof] = 0
                        end
                    end
                end
                #@info residual.entries, norms(residual)
                linres = norm(residual.entries)
                offset = 0
                for u in unknowns
                    ndofs_u = length(view(sol[u]))
                    if damping > 0
                        view(sol[u]) .= damping * view(sol[u]) + (1-damping) * view(x.u, offset+1:offset+ndofs_u)
                    else
                        view(sol[u]) .= view(x.u, offset+1:offset+ndofs_u)
                    end
                    offset += ndofs_u
                end
            end
        end
        time_total += time_solve
        time_final += time_solve
        allocs_final += allocs_solve
        if SC.parameters[:verbosity] > -1
            @printf "%.3e\t" linres
            @printf "%.2f\t%.2f\t%.2f\t" time_assembly time_solve time_total
            @printf "\t%.2f\t%.2f\t%.2f\n" allocs_assembly/alloc_factor  allocs_solve/alloc_factor (allocs_assembly+allocs_solve)/alloc_factor
            if is_linear
                @printf "\tfinished"
                @printf "\t\t\t\tSUM -->\t%.2f" time_final
                @printf "\t\t\tSUM -->\t%.2f\n\n" allocs_final/alloc_factor
            end
        end
    end

    if SC.parameters[:return_config]
        return sol, SC
    else
        return sol
    end
end


function iterate_until_stationarity(PDs::Array{ProblemDescription,1}, FES = nothing; maxsteps = 1000, tolerance_change = 1e-10, init = nothing, unknowns = [PD.unknowns for PD in PDs], kwargs... )

    nPDs = length(PDs)
    SCs = Array{SolverConfiguration,1}(undef, nPDs)

    ## find FESpaces and generate solution vector
    if FES === nothing
        @assert init !== nothing "need init vector or FES (as a Vector{Vector{<:FESpace}})"
        @info ".... taking FESpaces from init vector \n"
        all_unknowns = init.tags
        for p = 1 : nPDs, u in unknowns[p]
            @assert u in all_unknowns "did not found unknown $u in init vector (tags missing?)"
        end
        FES = [[init[u].FES for u in unknowns[j]] for j = 1 : nPDs]
        sol = deepcopy(init)
        sol.tags .= init.tags
    else
        all_unknowns = []
        for p = 1 : nPDs, u in unknowns[p]
            if !(u in all_unknowns)
                push!(u, all_unknowns)
            end
        end
        sol = FEVector(FES; tags = all_unknowns)
    end


    ## init solver configurations
    time = @elapsed begin
        allocs = @allocated begin
            for p = 1 : nPDs
                SCs[p] = SolverConfiguration(PDs[p], unknowns[p], FES[p]; init = sol, kwargs...)
                if SCs[p].parameters[:verbosity] > 0
                    @info ".... init solver configurations \n"
                end
                if SCs[p].parameters[:show_config]
                    @info "\n$(SCs[p])"
                end
            end
        end
    end

    @info "SOLVING iteratively $([PD.name for PD in PDs])
            unknowns = $([[uj.name for uj in u] for u in unknowns])"
      #      fetypes = $(["$(get_FEType(FES[j]))" for j = 1 : length(unknowns)])
      #      ndofs = $([FES[j].ndofs for j = 1 : length(unknowns)])

    As = [SC.A for SC in SCs]
    bs = [SC.b for SC in SCs]
    residuals = [SC.res for SC in SCs]

    ## unpack solver parameters
    is_linear = zeros(Bool, nPDs)

    ## check if problems are (non)linear
    nonlinear = zeros(Bool, nPDs)
    for (j,PD) in enumerate(PDs)
        for op in PD.operators
            nl_dependencies = depends_nonlinearly_on(op)
            for u in unknowns
                if u in nl_dependencies
                    nonlinear[j] = true
                    break
                end
            end
        end
        if SCs[j].parameters[:verbosity] > -1
            @info "nonlinear = $(nonlinear[j] ? "true" : "false")\n" 
        end
        if SCs[j].parameters[:is_linear] == "auto"
            is_linear[j] = !nonlinear[j]
        end
        if is_linear[j] && nonlinear[j]
            @warn "problem $(PD.name) seems nonlinear, but user set is_linear = true (results may be wrong)!!"
        end
    end
    maxits = [is_linear[j] ? 1 : maxits[j] for j = 1 : nPDs]

    alloc_factor = 1024^2

    @printf " init time | allocs = %.2f s | %.2f MiB\n" time allocs/alloc_factor
    time_final = time
    allocs_final = allocs
    nlres = 1.1e30
    linres = 1.1e30
    converged = zeros(Bool, nPDs)
    it::Int = 0
    while (it < maxsteps) && (any(converged .== false))
        it += 1
        @printf "%5d\t" it
        copyto!(init.entries, sol.entries)
        allocs_assembly = 0
        time_assembly = 0
        time_total = 0
        for p = 1 : nPDs
            b = bs[p]
            A = As[p]
            PD = PDs[p]
            SC = SCs[p]
            residual = residuals[p]
            maxits = SC.parameters[:maxiterations]
            nltol = SC.parameters[:target_residual]
            damping = SC.parameters[:damping]
            for j = 1 : 1
                time_total += @elapsed begin
                    fill!(b.entries, 0)
                    fill!(A.entries.cscmatrix.nzval,0)

                    ## assemble operators
                    time_assembly += @elapsed for op in PD.operators
                        allocs_assembly += @allocated assemble!(A, b, sol, op, SC; time = SC.parameters[:time], kwargs...)
                    end
                    flush!(A.entries)

                    if SC.parameters[:verbosity] > 0
                        @printf " assembly time | allocs = %.2f s | %.2f MiB\n" time allocs/alloc_factor
                    end

                    ## show spy
                    if SC.parameters[:show_matrix]
                        @show A
                    elseif SC.parameters[:spy]
                        @info ".... spy plot of system matrix:\n$(UnicodePlots.spy(sparse(A.entries.cscmatrix)))"
                    end

                    ## init solver
                    linsolve = SC.linsolver
                    if linsolve === nothing
                        method_linear = SC.parameters[:method_linear]
                        precon_linear = SC.parameters[:precon_linear]
                        if SC.parameters[:verbosity] > 0
                            @info ".... initializing linear solver ($(method_linear))\n" 
                        end
                        abstol = SC.parameters[:abstol]
                        reltol = SC.parameters[:reltol]
                        LP = SC.LP
                        if precon_linear !== nothing
                            linsolve = LinearSolve.init(LP, method_linear; Pl = precon_linear(A.entries.cscmatrix), abstol = abstol, reltol = reltol)
                        else
                            linsolve = LinearSolve.init(LP, method_linear; abstol = abstol, reltol = reltol)
                        end
                        SC.linsolver = linsolve
                    end

                    ## compute nonlinear residual
                    fill!(residual.entries, 0)
                    for j = 1 : length(b), k = 1 : length(b)
                        addblock_matmul!(residual[j], A[j,k], sol[unknowns[p][k]])
                    end
                    residual.entries .-= b.entries
                    #res = A.entries * sol.entries - b.entries
                    for op in PD.operators
                        residual.entries[fixed_dofs(op)] .= 0
                    end
                    for u_off in SC.parameters[:inactive]
                        j = get_unknown_id(SC, u_off) 
                        if j > 0
                            fill!(residual[j],0)
                        end
                    end
                    nlres = norm(residual.entries)
                    @printf "\tres[%d] = %.2e" p nlres
                end
                time_final += time_assembly
                allocs_final += allocs_assembly

                if nlres < nltol
                    converged[p] = true
                else
                    converged[p] = false
                end

                time_solve = @elapsed begin
                    allocs_solve = @allocated begin
                        linsolve.A = A.entries.cscmatrix
                        linsolve.b = b.entries

                        ## solve
                        x = LinearSolve.solve(linsolve)
                        SC.linsolver = linsolve

                        fill!(residual.entries, 0)
                        mul!(residual.entries, A.entries.cscmatrix, x.u)
                        residual.entries .-= b.entries
                        for op in PD.operators
                            for dof in fixed_dofs(op)
                                if dof <= length(residual.entries)
                                    residual.entries[dof] = 0
                                end
                            end
                        end
                        #@info residual.entries, norms(residual)
                        linres = norm(residual.entries)
                        offset = 0
                        for u in unknowns[p]
                            ndofs_u = length(view(sol[u]))
                            if damping > 0
                                view(sol[u]) .= damping * view(sol[u]) + (1-damping) * view(x.u, offset+1:offset+ndofs_u)
                            else
                                view(sol[u]) .= view(x.u, offset+1:offset+ndofs_u)
                            end
                            offset += ndofs_u
                        end
                    end
                end
                time_total += time_solve
                time_final += time_solve
                allocs_final += allocs_solve
                if SC.parameters[:verbosity] > -1
                    @printf " (%.3e)" linres
                end
            end # nonlinear iterations subproblem
        end
        @printf "\n"
    end
    return sol
end