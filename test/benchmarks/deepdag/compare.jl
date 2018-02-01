function runcompare()
    println("Running deep dag comparison")
    J = joinpath(JULIA_HOME, "julia")
    D = dirname(@__FILE__)
    F = map(x->joinpath(D,x), ("dagger.jl", "dagscheduler.jl", "dagscheduler_2node.jl"))
    #F = map(x->joinpath(D,x), ("dagger.jl", "dagscheduler_2node.jl"))

    for f in F
        command = `$J $f`
        println("- $(basename(f))")
        run(command)
    end
end

runcompare()
