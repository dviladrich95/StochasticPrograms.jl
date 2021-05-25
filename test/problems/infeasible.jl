@stochastic_model infeasible begin
    @stage 1 begin
        @decision(infeasible, x₁ >= 0)
        @decision(infeasible, x₂ >= 0)
        @objective(infeasible, Min, 3*x₁ + 2*x₂)
    end
    @stage 2 begin
        @uncertain ξ₁ ξ₂
        @recourse(infeasible, 0.8*ξ₁ <= y₁ <= ξ₁)
        @recourse(infeasible, 0.8*ξ₂ <= y₂ <= ξ₂)
        @objective(infeasible, Min, -15*y₁ - 12*y₂)
        @constraint(infeasible, 3*y₁ + 2*y₂ <= x₁)
        @constraint(infeasible, 2*y₁ + 5*y₂ <= x₂)
    end
end

ξ₁ = @scenario ξ₁ = 6. ξ₂ = 8. probability = 0.5
ξ₂ = @scenario ξ₁ = 4. ξ₂ = 4. probability = 0.5

infeasible_res = SPResult([27.2,41.6], Dict(1 => [4.8, 6.4], 2 => [4., 4.]), 36.4, 9.2, 27.2, Inf, 9.2, Inf)
push!(problems, (infeasible, [ξ₁,ξ₂], infeasible_res, "Infeasible"))
