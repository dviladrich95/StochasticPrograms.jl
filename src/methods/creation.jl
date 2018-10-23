# Creation macros #
# ========================== #
macro first_stage(args)
    @capture(args, model_Symbol = modeldef_) || error("Invalid syntax. Expected stochasticprogram = begin JuMPdef end")
    vardefs = Expr(:block)
    for line in modeldef.args
        (@capture(line, @constraint(m_Symbol,constdef__)) || @capture(line, @objective(m_Symbol,objdef__))) && continue
        push!(vardefs.args,line)
    end
    code = @q begin
        $(esc(model)).ext[:SP].generator[:stage_1_vars] = ($(esc(:model))::JuMP.Model,$(esc(:stage))) -> begin
            $(esc(vardefs))
	    return $(esc(:model))
        end
        $(esc(model)).ext[:SP].generator[:stage_1] = ($(esc(:model))::JuMP.Model,$(esc(:stage))) -> begin
            $(esc(modeldef))
	    return $(esc(:model))
        end
        generate_stage_one!($(esc(model)))
    end
    return code
end

macro second_stage(args)
    @capture(args, model_Symbol = modeldef_) || error("Invalid syntax. Expected stochasticprogram = begin JuMPdef end")
    def = postwalk(modeldef) do x
        @capture(x, @decision args__) || return x
        code = Expr(:block)
        for var in args
            varkey = Meta.quot(var)
            push!(code.args,:($var = parent.objDict[$varkey]))
        end
        return code
    end

    code = @q begin
        $(esc(model)).ext[:SP].generator[:stage_2] = ($(esc(:model))::JuMP.Model,$(esc(:stage)),$(esc(:scenario))::AbstractScenarioData,$(esc(:parent))::JuMP.Model) -> begin
            $(esc(def))
	    return $(esc(:model))
        end
        generate_stage_two!($(esc(model)))
        nothing
    end
    return prettify(code)
end

macro stage(stage,args)
    @capture(args, model_Symbol = modeldef_) || error("Invalid syntax. Expected stage, multistage = begin JuMPdef end")
    # Save variable definitions separately
    vardefs = Expr(:block)
    for line in modeldef.args
        (@capture(line, @constraint(m_Symbol,constdef__)) || @capture(line, @objective(m_Symbol,objdef__)) || @capture(line, @decision args__)) && continue
        push!(vardefs.args,line)
    end
    # Handle the first stage and the second stages differently
    code = if stage == 1
        code = @q begin
            $(esc(model)).ext[:MSSP].generator[:stage_1_vars] = ($(esc(:model))::JuMP.Model,$(esc(:stage))) -> begin
                $(esc(vardefs))
	        return $(esc(:model))
            end
            $(esc(model)).ext[:MSSP].generator[:stage_1] = ($(esc(:model))::JuMP.Model,$(esc(:stage))) -> begin
                $(esc(modeldef))
	        return $(esc(:model))
            end
            nothing
        end
        code
    else
        def = postwalk(modeldef) do x
            @capture(x, @decision args__) || return x
            code = Expr(:block)
            for var in args
                varkey = Meta.quot(var)
                push!(code.args,:($var = parent.objDict[$varkey]))
            end
            return code
        end
        # Create generator function
        code = @q begin
            $(esc(model)).ext[:MSSP].generator[Symbol(:stage_,$stage,:_vars)] = ($(esc(:model))::JuMP.Model,$(esc(:stage)),$(esc(:scenario))) -> begin
                $(esc(vardefs))
	        return $(esc(:model))
            end
            $(esc(model)).ext[:MSSP].generator[Symbol(:stage_,$stage)] = ($(esc(:model))::JuMP.Model,$(esc(:stage)),$(esc(:scenario))::AbstractScenarioData,$(esc(:parent))::JuMP.Model) -> begin
                $(esc(def))
	        return $(esc(:model))
            end
            nothing
        end
        code
    end
    # Return code
    return prettify(code)
end
# ========================== #