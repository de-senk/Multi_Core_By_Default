//NOTE: First iteration.
#module_parameters(MAX_LANES := 200);
#import "Basic";
#import "Thread";
#import "Atomics";
#import "System";
#import "Math";

g_multicore_state: Multicore_By_Default_Global_State;

Multicore_By_Default_Global_State :: struct {
    worker_contexts: [MAX_LANES]Worker_Context;
    threads: [MAX_LANES]Thread;
    lane_count: u32;

    barrier_counter: u64; //because atomics
    barrier_generation: u64; //because atomics

}

Worker_Context :: struct {
    lane_slot:   u32;
    lane_count: u32;
    done: bool;
}

thread_join :: (thread: *Thread) -> u64 {
    thread_data : *Worker_Context = thread.data;
    while !thread_data.done  sleep_milliseconds(1);
    thread_deinit(thread);
    // release_thread(thread);
    return thread_data.lane_slot;
}

deinitialize_multicore_by_default :: () {
    using g_multicore_state;
    for i: 0..lane_count-1 {
        thread_join(*threads[i]);
    }
}

initialize_multicore_by_default :: (procedure_to_execute_in_all_lanes: Thread_Proc) {
    using g_multicore_state;
    // init(*barrier_generation,      "Multicore by default Barrier");
    num_cpus := get_number_of_processors();
    assert(num_cpus >= 1);
    if num_cpus > 200  num_cpus = 200;  // Clamp to a value that is reasonable as of 2021, in case we get weird data.
    #if (OS == .WINDOWS) || (OS == .LINUX)
        num_cpus /= 2;// This routine reports hyperthreads, so, divide by two, because of Intel marketing.

    lane_count = min(cast(u32)num_cpus, MAX_LANES);
    for i: 0..lane_count-1 {
        worker_contexts[i] = .{ lane_slot = cast(u32)i, lane_count = lane_count };
        thread_init(*threads[i], procedure_to_execute_in_all_lanes);
        threads[i].data = *worker_contexts[i];
        thread_start(*threads[i]);
    }
}


initialize_multicore_by_default_use_all_threads :: (procedure_to_execute_in_all_lanes: Thread_Proc) {
    using g_multicore_state;
    num_cpus := get_number_of_processors();
    assert(num_cpus >= 1);
    if num_cpus > 200  num_cpus = 200;  // Clamp to a value that is reasonable as of 2021, in case we get weird data.
    //DISABLED TO USE ALL THREADS
      // #if (OS == .WINDOWS) || (OS == .LINUX)
      //     num_cpus /= 2;// This routine reports hyperthreads, so, divide by two, because of Intel marketing.

    lane_count = min(cast(u32)num_cpus, MAX_LANES);
    for i: 0..lane_count-1 {
        worker_contexts[i] = .{ lane_slot = cast(u32)i, lane_count = lane_count };
        thread_init(*threads[i], procedure_to_execute_in_all_lanes);
        threads[i].data = *worker_contexts[i];
        thread_start(*threads[i]);
    }
}

sync_lanes_for_range :: (total_items: s64, body: Code) #expand
{
    #if !#exists(`start_slot) `start_slot: s64;
    #if !#exists(`end_slot) `end_slot: s64;
    #if !#exists(`work_slot) `work_slot: s64;

    items_per_lane := (total_items +`lane_count - 1)/`lane_count;
    `start_slot = `lane_slot * items_per_lane;
    `end_slot = `start_slot + items_per_lane;
    if `end_slot > total_items then `end_slot = total_items;
    for i: `start_slot..`end_slot -1 {
        `work_slot = i;
        #insert body;
    }

    if `lane_count > 1 {
        gen := atomic_read(*g_multicore_state.barrier_generation);
        old_arrived := atomic_add(*g_multicore_state.barrier_counter, 1);
        should_spin := true;
        if old_arrived + 1 == `lane_count {
            should_spin = false;
            g_multicore_state.barrier_counter = 0;
            atomic_add(*g_multicore_state.barrier_generation, 1);
        }

        if should_spin {
            while atomic_read(*g_multicore_state.barrier_generation) == gen {
                #asm { pause; } //TODO: make this crosspaltform (ARM, etc)
            }
        }
    }
}