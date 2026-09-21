//NOTE: Third iteration.
/*NOTE: IMPLEMENTED ON THIRD ITERATIONN
        idea (absraction) 2 procedures 'GoWide()' and 'GoNarrow()':
        GoWide(): should set all the ranges and everything
        GoNarrow(): goes to single lane(I was thinking on GoSingle() but that would just be sad.)
        'work_slot' is the variable name one gets to get used to use.

*/


//:jumptag_StuffThatImHappyWithAndIWillNotChangeTooMuch

#module_parameters(MAX_LANES := 200, USE_OS_BARRIER:=true);
#import "Basic"; //assert,max,min procedures
#import "Thread";
#import "Atomics";
#import "System";
#import "Machine_X64";

g_multicore_state: Multicore_By_Default_Global_State;

#add_context worker_context: *Worker_Context;
Worker_Context :: struct {
    work_slot: s64; //this field is HOT (changes a LOT)
    zero_lane_global_slot:  s64;
    lane_slot:  s64;
    lane_count: s64;
    execute_widely: bool; //extremely useful
    subdivide_split: bool; //extremely useful
    done: bool; // maybe delete.
}

Multicore_By_Default_Global_State :: struct {
    worker_contexts: [MAX_LANES]Worker_Context;
    threads: [MAX_LANES]Thread;
    total_lane_count: s64;
    debug_initialized: s64; // @Hack

    barrier_counter : [MAX_LANES]Barrier; //for atomics
    barrier_sense   : [MAX_LANES]Barrier; //for atomics
    broadcast_memory: [MAX_LANES]u64; //for atomics

    shared_mutex: Mutex; //using Mutex are slow, but useful for writting to a hash table inside a wide loop

    frame_semaphore: Semaphore;
    wide_semaphore: Semaphore;

}

deinitialize_multicore_by_default :: () {
    using g_multicore_state;

    // @Hack: debug break if you call deinit more than once.
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

     // barrier_release(*barrier_sense[zero_lane_global_slot]);


    num_cpus := get_number_of_processors();
    assert(num_cpus >= 1);
    if num_cpus > 200  num_cpus = 200;  // Clamp to a value that is reasonable as of 2021, in case we get weird data.
    #if use_real_cores && (OS == .WINDOWS) || (OS == .LINUX) {
        num_cpus /= 2;// This routine reports hyperthreads, so, divide by two, because of Intel marketing.
        num_cpus += 1; //TODO: Explanation why real cores + 1 hyperthread works
    }

    total_lane_count = min(cast(u32)num_cpus, MAX_LANES);
    barrier_init(*barrier_sense[0], cast(s32)total_lane_count);
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

thread_join :: (thread: *Thread) -> s64 {
    thread_data : *Worker_Context = thread.data;
    while !thread_data.done sleep_milliseconds(1);
    thread_deinit(thread);
    // release_thread(thread);
    return thread_data.lane_slot;
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

Lane_Context :: struct {
 zero_lane_global_slot: s64;
 lane_slot: s64;
 lane_count: s64;
}

GetLaneSplit :: () -> backup:Lane_Context, new_ctx: Lane_Context, I_am_right_side: bool, new_ane_count: int {
 using context.worker_context;
 backup  : Lane_Context;
 new_ctx : Lane_Context;
 backup.lane_slot = lane_slot;
 backup.lane_count = lane_count;
 backup.zero_lane_global_slot = zero_lane_global_slot;
 new_ctx = backup;

 half := lane_count / 2;
 half = max(half, 1);
 new_ctx.lane_count = half;

 I_am_right_side := lane_slot + 1 > half;
 if I_am_right_side
 {
  //we remap the lane slot
  new_ctx.lane_slot = lane_slot - half;
  should_add_remaining := lane_count > 2 && lane_count % 2 != 0;
  if should_add_remaining new_ctx.lane_count+=1;
 }
 new_lane_count := half;
 return backup, new_ctx, I_am_right_side, new_lane_count;
}


GetLaneSplitLeftRight :: () -> backup:Lane_Context, left:Lane_Context, right:Lane_Context {
 using context.worker_context;
 backup, new_ctx, I_am_right_side, new_lane_count := GetLaneSplit();
 left  := new_ctx;
 right := new_ctx;

 if I_am_right_side {
  left.lane_count = 0; //we disable left lane
  // left.zero_lane_global_slot = new_ctx.zero_lane_global_slot; //this line mght be pointless
  // We set new zero slot:
  right.zero_lane_global_slot += new_lane_count;
 } else {
  right.lane_count = 0; //we disable right
  left.zero_lane_global_slot += new_lane_count;
 }

 return backup, left, right;
}

LaneJoin :: (ctx: Lane_Context) {
 using context.worker_context;
 using g_multicore_state;
 LaneActivate(ctx);
}

LaneActivate :: (ctx: Lane_Context) {
 using context.worker_context;
  using g_multicore_state;
 if ctx.lane_count == 0 return; //I hate protective coding

 //replace worker context state
 lane_slot = ctx.lane_slot;
 lane_count = ctx.lane_count;
 zero_lane_global_slot = ctx.zero_lane_global_slot;

 if lane_slot == 0 {
    barrier_release(*barrier_sense[zero_lane_global_slot]);
    barrier_init(*barrier_sense[zero_lane_global_slot], cast(s32)lane_count);
 }
}

GoWide :: (total_items: s64) #expand {
    #if !#exists(`range) `range: Lane_Range;
    assert(total_items > 0, "to execute only once you should send 1 as param");
    using context.worker_context;
    execute_widely = true;
    LaneSync();
    `range = LaneGetRange(total_items);
}

GoSingle :: #bake_arguments GoNarrow(total_items=1);
GoNarrow :: (total_items: s64)  #expand {
    #if !#exists(`range) `range: Lane_Range;
    using context.worker_context;
    assert(total_items > 0, "to execute only once you should send 1 as param");
    execute_widely=false;
    LaneSync();
    `range = LaneGetRange(total_items);
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

//:jumptag_StuffThatImHappyWithAndIWillNotChangeTooMuch

BroadcastSync :: (payload: *$T, src_lane: s64) {
    using g_multicore_state;
    using context.worker_context;
    assert(payload != null, "you must pass a pointer to a pointer, you probably did, 'some_array_view.data' you should do '*some_array_view.data' instead");

    is_src := lane_slot == src_lane;
    is_destination := lane_slot != src_lane;

    if is_src atomic_write(*broadcast_memory[zero_lane_global_slot], cast(u64)(payload));
    LaneSync();
    if is_destination payload.* = (.*) cast(*T)atomic_read(*broadcast_memory[zero_lane_global_slot]);
    LaneSync();
}

Lane_Range :: struct {
    min: s64;
    max: s64;
}

//src is Ryan Fleury, raddbg codebase, standard MIT licenced, licence at end of file:
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

LaneGetRange  :: (total_items: s64) -> Lane_Range {
 using context.worker_context;
 result: Lane_Range;
 result.min = 0;
 result.max = -1;

 // inline debug_break();
 if lane_count == 0 return result;
 if execute_widely  return m_range_from_n_idx_m_count(lane_slot, lane_count, total_items);
 if lane_slot == 0 result.max = total_items-1;

 return result;
}

CompilerFence :: () {
#run log("TODO: CompilerFence :: () {, llvm probably changes order of stuff");
}

Barrier_My_writes_are_done  :: Barrier_FlushStoreBuffer;
Barrier_Make_sure_I_read_fresh_data  :: Barrier_FlushStoreBuffer;

//reads can skip through
Barrier_FlushStoreBuffer :: () {
//x86 -> sfence (Store Fence)
//ARM -> DMB ISHST (Data Memory Barrier, Inner Shareable Store)
#if CPU == .X64 {

        #asm { sfence; }
        // CompilerFence();
    } else #if CPU == .ARM64 {
        // ARM requires an actual hardware store fence instruction.
        #asm { dmb ishst; }
    }
}

//discards loads and forces operations to load again what they were about to do.
BarrierFlushLoadBuffer :: () {
//x86 -> lfence (Load Fence)
//ARM -> DMB ISHLD (Data Memory Barrier, Inner Shareable Load)

}

BarrierFlushAll :: () {
//x86 -> mfence/lock (Memory Fence) Full fence
//ARM -> DMB (Data Memory Barrier)

}

LaneSync :: (caller_loc := #caller_location) #expand {
    lane_sync_broadcast(ptr = null, src_lane_index = 0, caller_loc = caller_loc);
}

// LaneSyncBACKUP :: ()  {
//  using context.worker_context;
//  using g_multicore_state;
//  if lane_count > 1 {
//   local_sense := 1 - atomic_read(*barrier_sense[zero_lane_global_slot]);
//   old_arrived := atomic_add(*barrier_counter[zero_lane_global_slot], 1);

//   last_thread_arrived := old_arrived + 1 == lane_count;
//   should_spin := !last_thread_arrived;

//   if should_spin {
//    while atomic_read(*barrier_sense[zero_lane_global_slot]) != local_sense {
//     #asm { pause; }
//    }
//   }

//   if last_thread_arrived {
//    atomic_write(*barrier_counter[zero_lane_global_slot], 0);
//    atomic_write(*barrier_sense[zero_lane_global_slot], local_sense);
//   }

//  }
// }

lane_sync_broadcast :: (ptr: *$T, src_lane_index: s32, caller_loc := #caller_location) #expand #no_debug {
 using context.worker_context;
 using g_multicore_state;
 #assert(size_of(T) <= 8 && "Cannot broadcast values larger than 8 bytes");

 if ptr != null && lane_slot == src_lane_index {
     memcpy(*broadcast_memory[zero_lane_global_slot], ptr, size_of(T));
 }

 barrier_wait(*barrier_sense[zero_lane_global_slot]);

 if ptr != null && lane_slot != src_lane_index {
     memcpy(ptr, *broadcast_memory[zero_lane_global_slot], size_of(T));
 }

 if ptr {
     barrier_wait(*barrier_sense[zero_lane_global_slot]);
 }
}



//NOTE: Windows have OS barrers which are really good (I guess), mac, and probably other OS's doesnt have them.

//from here onwards the code is from Roey Borsteinas (standard MIT licenced), the full licence is at the end of this file at this tag :tagMITLicense
BARRIER_SPIN_COUNT :: 8 * 1024;

#if !USE_OS_BARRIER {
    Barrier :: struct {
        num_threads:   s32;
        count:         s32 #align 64;
        generation_id: s32 #align 64;
        mutex:         Mutex;
        cvar:          Condition_Variable;
        initialized: bool; //to avoids for leaks in LaneSplit strategy
    }

    barrier_init :: (using barrier: *Barrier, count: s32) {
        assert(initialized == false);
        num_threads   = count;
        count         = 0;
        generation_id = 0;
        init(*mutex);
        init(*cvar);
        initialized = true;
    }

    barrier_release :: (using barrier: *Barrier) {
        if initialized == false return;
        destroy(*cvar);
        destroy(*mutex);
        initialized = false;
    }

    barrier_wait :: (using barrier: *Barrier) {
        if num_threads <= 1 then return;

        #if CPU == .X64 {
            #asm { mfence; }
        } else #if CPU == .ARM64 {
            // The data memory barrier ensures that all preceding writes are issued before any subsequent memory
            // operations (including speculative memory access). In acquire/release terms, it is a full barrier. The
            // instruction does not stall execution; it just tells the memory controller to preserve externally-visible
            // ordering. - https://devblogs.microsoft.com/oldnewthing/20220812-00/?p=106968
            #bytes .[0xBF, 0x3B, 0x03, 0xD5]; // dmb ish; data memory barrier
        } else {
            #assert("Unsupported CPU");
        }

        local_gen := atomic_read(*barrier.generation_id);
        if atomic_add(*barrier.count, 1) + 1 < barrier.num_threads {
            for 0..BARRIER_SPIN_COUNT-1 {
                if atomic_read(*barrier.generation_id) != local_gen return;

                #if CPU == .X64 {
                    #asm { pause; }
                } else #if CPU == .ARM64 {
                    // arm64 equivlent of x86's pause
                    #bytes .[0x3F, 0x20, 0x03, 0xD5]; // YIELD
                } else {
                    #assert("Unsupported CPU");
                }
            }
            lock(*barrier.mutex);
            while atomic_read(*barrier.generation_id) == local_gen {
                wait(*barrier.cvar, *barrier.mutex);
            }
            unlock(*barrier.mutex);
        } else {
            lock(*barrier.mutex);
            atomic_write(*barrier.count, 0);
            atomic_add(*barrier.generation_id, 1);
            wake_all(*barrier.cvar);
            unlock(*barrier.mutex);
        }
    }
} else {
    #if OS == .WINDOWS {
        Barrier :: struct {
            platform_specific: SYNCHRONIZATION_BARRIER;
            num_threads: s32;
            initialized: bool; //to avoids for leaks in LaneSplit strategy
        }

        barrier_init :: (using barrier: *Barrier, count: s32) {
            assert(initialized == false);
            v := InitializeSynchronizationBarrier(*platform_specific, count, BARRIER_SPIN_COUNT);
            num_threads = count;
            initialized = true;
        }

        barrier_release :: (using barrier: *Barrier) {
            // if num_threads <= 1 then return;
            if initialized == false return; //hmmm idk about the above line
            v := DeleteSynchronizationBarrier(*platform_specific);
            initialized = false;
        }

        barrier_wait :: (using barrier: *Barrier) {
            NO_DELETE_FLAG : u32 : 0x4;
            v := EnterSynchronizationBarrier(*platform_specific, NO_DELETE_FLAG);
        }

        ULONG_PTR :: u64;
        LONG :: s32;

        SYNCHRONIZATION_BARRIER :: struct {
            Reserved1: Windows.DWORD;
            Reserved2: Windows.DWORD;
            Reserved3: [2] ULONG_PTR;
            Reserved4: Windows.DWORD;
            Reserved5: Windows.DWORD;
        }


        #scope_file
        Windows :: #import "Windows";
        kernel32 :: #library,system "kernel32";

        InitializeSynchronizationBarrier :: (lpBarrier: *SYNCHRONIZATION_BARRIER, lTotalThreads: LONG, lSpinCount: LONG) -> Windows.BOOL #foreign kernel32;
        DeleteSynchronizationBarrier :: (lpBarrier: *SYNCHRONIZATION_BARRIER) -> Windows.BOOL #foreign kernel32;
        EnterSynchronizationBarrier :: (lpBarrier: *SYNCHRONIZATION_BARRIER, dwFlags: Windows.DWORD) -> Windows.BOOL #foreign kernel32;
    } else #if OS == .MACOS {
        #assert(false, "macos doesn't support OS barriers, consider setting jai-wavefront's module parameter USE_OS_BARRIER to false");
    } else {
        #import "POSIX";

        Barrier :: struct {
            barrier: pthread_barrier_t;
            initialized: bool;
        }

        barrier_init :: (using _barrier: *Barrier, count: s32) {
            assert(initialized == false);
            pthread_barrier_init(barrier, null, cast(u32) count);
            initialized = true;
        }

        barrier_release :: (using _barrier: *Barrier) {
            if initialized == false return;
            if barrier != null {
                pthread_barrier_destroy(barrier);
            }
            initialized = false; //hmm
        }

        barrier_wait :: (using _barrier: *Barrier) {
            if barrier != null {
                pthread_barrier_wait(barrier);
            }
        }
    }
}
/*:tagMITLicense

MIT License

Copyright (c) 2026 Roey Borsteinas

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
*/