//NOTE: Second iteration.
/*NOTE:
    Next idea (absraction) 2 procedures 'GoWide()' and 'GoNarrow()':
        GoWide(): should set all the ranges and everything
        GoNarrow(): goes to single lane(I was thinking on GoSingle() but that would just be sad.)
        'work_slot' is the variable name one gets to get used to use.
*/


//:jumptag_StuffThatImHappyWithAndIWillNotChange

#module_parameters(MAX_LANES := 200);
#import "Basic"; //assert,max,min procedures
#import "Thread";
#import "Atomics";
#import "System";
#import "Machine_X64";

g_multicore_state: Multicore_By_Default_Global_State;

#add_context worker_context: *Worker_Context;
Worker_Context :: struct {
    lane_slot:   s64;
    lane_count: s64;
    done: bool;
}


Multicore_By_Default_Global_State :: struct {
    worker_contexts: [MAX_LANES]Worker_Context;
    threads: [MAX_LANES]Thread;
    total_lane_count: s64;
    debug_initialized: s64;

    barrier_counter : s64; //for atomics
    barrier_sense   : s64; //for atomics
    broadcast_memory: u64; //for atomics

    shared_mutex: Mutex; //using Mutex are slow, but useful for writting to a hash table inside a wide loop

    frame_semaphore: Semaphore;
    wide_semaphore: Semaphore;

}

BroadcastSync :: (payload: *$T, src_lane: s64) {
    using g_multicore_state;
    using context.worker_context;
    assert(payload != null, "you must pass a pointer to a pointer, you probably did, 'some_array_view.data' you should do '*some_array_view.data' instead");

    is_src := lane_slot == src_lane;
    is_destination := lane_slot != src_lane;

    if is_src atomic_write(*broadcast_memory, cast(u64)(payload));
    LaneSync();
    if is_destination payload.* = (.*) cast(*T)atomic_read(*broadcast_memory);
    LaneSync();
}


thread_join :: (thread: *Thread) -> s64 {
    thread_data : *Worker_Context = thread.data;
    while !thread_data.done  sleep_milliseconds(1);
    thread_deinit(thread);
    // release_thread(thread);
    return thread_data.lane_slot;
}


deinitialize_multicore_by_default :: () {
    using g_multicore_state;
    debug_initialized -= 1;
    assert(debug_initialized == 0);
    for i: 0..total_lane_count-1 thread_join(*threads[i]);
    destroy(*wide_semaphore);
    destroy(*frame_semaphore);
    destroy(*shared_mutex);
    total_lane_count = 0;
}

initialize_multicore_by_default :: (procedure_to_execute_in_all_lanes: Thread_Proc, $use_real_cores := true) -> s64 {
    using g_multicore_state;
    debug_initialized += 1;
    assert(debug_initialized == 1);
    init(*shared_mutex,"Block them All", 1);
    init(*wide_semaphore, 0);
    init(*frame_semaphore, 0);
    
    num_cpus := get_number_of_processors();
    assert(num_cpus >= 1);
    if num_cpus > 200  num_cpus = 200;  // Clamp to a value that is reasonable as of 2021, in case we get weird data.
    #if use_real_cores && (OS == .WINDOWS) || (OS == .LINUX)
        num_cpus /= 2;// This routine reports hyperthreads, so, divide by two, because of Intel marketing.

    total_lane_count = min(cast(u32)num_cpus, MAX_LANES);
    for i: 0..total_lane_count-1 {
        worker_contexts[i] = .{ lane_slot = cast(u32)i, lane_count = total_lane_count };
        thread_init(*threads[i], procedure_to_execute_in_all_lanes);
        assert(threads[i].index != 0);
        work_ptr := *worker_contexts[i];
        threads[i].data = work_ptr;
        thread_start(*threads[i]);
    }
    return total_lane_count;

}

InitializeCodecycle :: (thread_work: *Worker_Context)  #expand {
    // `defer thread_work.done = true;
    thread_work.done = true;
    `Codecycle_Called_InitializeCodecycle :: "make sure you are 'using your_thread_parameter_name; on the main scope";
    context.worker_context = thread_work;
}



//------------------
//TODO: reame these procedures to something more nice looking.
MDF_Semaphore_Wait_For_Frame :: () {
    using g_multicore_state;
    wait_for(*frame_semaphore);

}
MDF_Semaphore_Green_Wide :: () {
    using g_multicore_state;
    signal(*wide_semaphore);
}

MDF_Semaphore_Wait_For_Wide :: () {
    using g_multicore_state;
    assert(context.worker_context==null, "this procedure should be called in your frame loop");
    for 0..total_lane_count - 1 wait_for(*wide_semaphore);
}
MDF_Semaphore_Green_Frame :: () {
    using g_multicore_state;
    assert(context.worker_context==null, "this procedure should be called in your frame loop");
    for 0..total_lane_count - 1 signal(*frame_semaphore);
}
//------------------


GetLaneCount :: () -> s64 {
    using g_multicore_state;
    return total_lane_count;
}

//NOTE: Terrible idea because YOU LOSE DEBUGGABILITY, when jai gets first class suport for #expand macros, then this might be a good idea.
sync_lanes_for_range :: (total_items: s64, body: Code) #expand
{
    assert(false, "using this is stupid if you cannot debug it");
    #if !#exists(`Codecycle_Called_InitializeCodecycle) #assert(false);


    items_per_lane := (total_items +`lane_count - 1)/`lane_count;
    `start_slot = `lane_slot * items_per_lane;
    `end_slot = `start_slot + items_per_lane;
    if `end_slot > total_items then `end_slot = total_items;
    for i: `start_slot..`end_slot -1 {
        `work_slot = i;
        #insert body;
    }

    if `lane_count > 1 {
        gen := atomic_read(*g_multicore_state.barrier_sense);
        old_arrived := atomic_add(*g_multicore_state.barrier_counter, 1);
        should_spin := true;
        if old_arrived + 1 == `lane_count {
            should_spin = false;
            g_multicore_state.barrier_counter = 0;
            atomic_add(*g_multicore_state.barrier_sense, 1);
        }

        if should_spin {
            while atomic_read(*g_multicore_state.barrier_sense) == gen {
                #asm { pause; } //TODO: make this crosspaltform (ARM, etc)
            }
        }
    }
}


/*--- @Hack ----*/
thread_yield :: () {
    #if OS == .WINDOWS {
        #import "Windows";
	    SleepEx :: (milliseconds: DWORD, alertable: BOOL) -> void #foreign kernel32;
        SleepEx(0, 1);
    }
    else {
	    sched_yield();
    }
}


//
//from Glenn Fiedler: gafferongames.com/post/fix_your_timestep/
//
g_renderer_time_apollo: Apollo_Time;

//call this from renderer codecycle
RendererTime_Produce :: () {
    atomic_write(*g_renderer_time_apollo, current_time_consensus());
}

//consume in any other codecycle
RendererTime_Consume :: () -> float64 {
    apollo_time := atomic_read(*g_renderer_time_apollo);
    return to_float64_seconds(apollo_time);

}

Codecycle :: struct {
    hertz:        float64;
    total_time:        float64;
    delta_time:        float64;
    current_time:      float64;
    accumulator: float64;
}

FixYourTimeStep_InitForThread :: (_hertz: float64) #expand {
    `codecycle_ctx: Codecycle;
    using `codecycle_ctx;
    current_time = RendererTime_Consume();
    accumulator  = 0.0;
    total_time   = 0.0;
    hertz        = _hertz;
    delta_time   = 1.0/_hertz; //?: hardcoded for some reason
}



FixYourTimeStep_Loop :: (anti_spiral_treshold: float64 = 0.25) -> loop_max:s64, dt:float64, alpha:float64 #expand {
    using `codecycle_ctx;
    new_time := RendererTime_Consume();
    frame_time := new_time - current_time;
    if ( frame_time > anti_spiral_treshold )
            frame_time = anti_spiral_treshold;
    current_time = new_time;
    accumulator += frame_time;

    loop_max: s64 = -1 ; //because jai foor loops need negative numbers to NOT process

    while accumulator >= delta_time {
        loop_max+=1;
        accumulator -= frame_time;
        total_time += delta_time;
    }

    alpha := accumulator / delta_time;
    return loop_max, delta_time, alpha;
}

//:jumptag_StuffThatImHappyWithAndIWillNotChange

Lane_Range :: struct {
    min: s64;
    max: s64;
}

//src is Ryan Fleury, raddbg codebase:
m_range_from_n_idx_m_count :: ( n_idx:s64,  n_count:s64,  m_count:s64) -> Lane_Range
{
  main_idxes_per_lane:s64 = m_count/n_count;
  leftover_idxes_count:s64 = m_count - main_idxes_per_lane*n_count;
  leftover_idxes_before_this_lane_count:s64 = min(n_idx, leftover_idxes_count);
  lane_base_idx:s64 = n_idx*main_idxes_per_lane + leftover_idxes_before_this_lane_count;
  lane_base_idx__clamped:s64 = min(lane_base_idx, m_count);
  lane_opl_idx:s64 = lane_base_idx__clamped + main_idxes_per_lane + (ifx (n_idx < leftover_idxes_count) then 1 else 0);
  lane_opl_idx__clamped:s64 = min(lane_opl_idx, m_count);

  result: Lane_Range;
  result.min = lane_base_idx__clamped;
  result.max = lane_opl_idx__clamped-1;
  return result;
}

LaneGetRange  :: (total_items: s64) -> Lane_Range  {
    using context.worker_context;
    return m_range_from_n_idx_m_count(lane_slot, lane_count, total_items);
}

LaneSync :: ()  {
    using context.worker_context;
    using g_multicore_state;
    if lane_count > 1 {
        local_sense := 1 - atomic_read(*barrier_sense);
        old_arrived := atomic_add(*barrier_counter, 1);

        last_thread_arrived := old_arrived + 1 == lane_count;
        should_spin := !last_thread_arrived;

        if should_spin {
            while atomic_read(*barrier_sense) != local_sense {
                #asm { pause; }
            }
        }

        if last_thread_arrived {
            atomic_write(*barrier_counter, 0);
            atomic_write(*barrier_sense, local_sense);
        }

    }
}

