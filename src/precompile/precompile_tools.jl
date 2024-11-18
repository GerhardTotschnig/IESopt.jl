@setup_workload begin
    # list = [...]

    const __dir = Assets.get_path("examples")

    @compile_workload begin
        config = Dict("optimization.snapshots.count" => 3, "general.verbosity.core" => "error")
        fn = String(normpath(__dir, "01_basic_single_node.iesopt.yaml"))

        generate!(fn; config=Dict("general.verbosity.core" => "debug"))
        generate!(fn; config=Dict("general.verbosity.core" => "info"))
        generate!(fn; config=Dict("general.verbosity.core" => "warn"))
        model = generate!(
            fn;
            config=Dict(
                "optimization.snapshots.count" => 3,
                "results.memory_only" => true,
                "results.backend" => "duckdb",
            ),
        )
        optimize!(model)
        model = generate!(
            fn;
            config=Dict(
                "optimization.snapshots.count" => 3,
                "results.memory_only" => false,
                "results.backend" => "jld2",
            ),
        )
        optimize!(model)
        model = generate!(
            fn;
            config=Dict(
                "optimization.snapshots.count" => 3,
                "results.memory_only" => true,
                "results.backend" => "jld2",
            ),
        )
        optimize!(model)
        IESopt.run(fn; config)
        generate!(normpath(__dir, "02_advanced_single_node.iesopt.yaml"); config)
        # generate!(normpath(__dir, "03_basic_two_nodes.iesopt.yaml"); config)
        # generate!(normpath(__dir, "04_soft_constraints.iesopt.yaml"); config)
        # generate!(normpath(__dir, "05_basic_two_nodes_1y.iesopt.yaml"); config)
        # generate!(normpath(__dir, "06_recursion_h2.iesopt.yaml"); config)
        generate!(normpath(__dir, "07_csv_filestorage.iesopt.yaml"); config)
        generate!(normpath(__dir, "08_basic_investment.iesopt.yaml"); config)
        generate!(normpath(__dir, "09_csv_only.iesopt.yaml"); config)
        # generate!(normpath(__dir, "10_basic_load_shedding.iesopt.yaml"); config)
        generate!(normpath(__dir, "11_basic_unit_commitment.iesopt.yaml"); config)
        # generate!(normpath(__dir, "12_incremental_efficiency.iesopt.yaml"); config)
        # generate!(normpath(__dir, "15_varying_efficiency.iesopt.yaml"); config)
        generate!(normpath(__dir, "16_noncore_components.iesopt.yaml"); config)
        # generate!(normpath(__dir, "17_varying_connection_capacity.iesopt.yaml"); config)

        model = generate!(normpath(__dir, "18_addons.iesopt.yaml"); config)
        get_components(model; tagged=["ModifyMe"])

        model = generate!(normpath(__dir, "20_chp.iesopt.yaml"); config)
        get_component(model, "chp")

        # generate!(normpath(__dir, "22_snapshot_weights.iesopt.yaml"); config)
        # generate!(normpath(__dir, "23_snapshots_from_csv.iesopt.yaml"); config)
        generate!(normpath(__dir, "25_global_parameters.iesopt.yaml"); config)
        # generate!(
        #     normpath(__dir, "26_initial_states.iesopt.yaml");
        #     config,
        #     parameters=Dict("store_initial_state" => 15),
        # )
        # generate!(normpath(__dir, "27_piecewise_linear_costs.iesopt.yaml"); config)
        # generate!(normpath(__dir, "29_advanced_unit_commitment.iesopt.yaml"); config)
        # generate!(normpath(__dir, "31_exclusive_operation.iesopt.yaml"); config)
        # generate!(normpath(__dir, "37_certificates.iesopt.yaml"); config=Dict("general.verbosity.core" => "error"))
        generate!(normpath(__dir, "44_lossy_connections.iesopt.yaml"); config)
        generate!(normpath(__dir, "47_disable_components.iesopt.yaml"); config)
    end

    # Clean up output files after testing is done.
    rm(normpath(__dir, "out"); force=true, recursive=true)
end

precompile(_attach_optimizer, (JuMP.Model,))
