#module_parameters(MAX_LANES := 200, USE_OS_BARRIER:=true);
/*
Design toughts: The main goal is 
    to have debuggable multithreaded code 
        - This is the main reason why using parallel_for or even using jai for_expansions are a bad idea.
    to have very low friction for editing multithreaded code
        - This is the reason why I opted for a state machine handling in the jai context
        - if you want to run a line multithreaded you just move the line, almost every code modification is O(1) (1 line change to change behavior)

GoWide sets the context state to execute the next ranged loop, widely.
GoNarrow sets the context state to execute the next ranged loop, on a single thread.
GoSingle is the same as GoNarrow, but it will only execute once. Its to avoid doing GoNarrow(1);

Splitting of threads is experimental for now:
    ...
    backup_ctx, left_ctx, right_ctx := GetLaneSplitLeftRight();
    SplitBegin(*left_ctx, *right_ctx);
    LaneActivate(right_ctx); //SPLITTING towards RIGHT side threads
    GoWide(arr_of_meshes.count);
    for work_slot: range.min .. range.max { //for left lanes, range.max is -1
       //this executes only on the right side threads
    }
    LaneActivate(left_ctx); //SPLITTING towards LEFT side threads
    GoWide(arr_of_meshes.count); //Dont forget to call one of these first after activating, otherwise range.min and max will get bad values
    for work_slot: range.min .. range.max { //for right lanes, range.max is -1
       //this executes only on the Left side threads
    }
    LaneJoin(backup_ctx, left_ctx, right_ctx); //this executes LaneSync() internally.
    ...
    a bad thing is that you need to call reset_broadcasts_memory() once per frame to use this feature.
    another bad thing is that this always splits in half, there is no way to tune it for now.

There is many things that needs improve, per example barriers_memory, broadcasts_memory
these are not aligned to 64 bytes, and it can get too MESI (intel joke)
*/

#add_context worker_context: *Worker_Context;
Worker_Context :: struct {
    lane_slot:  s64;
    lane_count: s64;

    //broadcast_slot: is called like that but is also used for barriers.
    broadcast_slot:  s64; //also doubles as this lane-group's index into g_multicore_state.barrier_pool

    execute_widely: bool; //extremely useful
    done: bool; // maybe delete.
}


#import "Basic"; //assert,max,min 
#import "Thread";
#import "Atomics";
#import "System";
#import "Machine_X64";

g_multicore_state: Multicore_By_Default_Global_State;

Multicore_By_Default_Global_State :: struct {
    worker_contexts: [MAX_LANES]Worker_Context;
    threads: [MAX_LANES]Thread;
    total_lane_count: s64;
    debug_initialized: s64; // @Hack

    broadcasts_memory: [MAX_LANES*2]u64; //because wide pointers
    barriers_memory: [MAX_LANES*2]Barrier;
    broadcasts_memory_used_count: s64;

    barrier_pool: [MAX_LANES*2]Barrier;

    shared_mutex: Mutex; //slow, but useful for writting to a hash table inside a wide loop or similar problems

    //not happy about these but is the simplest solution I found for sokol_app and similar softwares that control your frame loop.
    frame_semaphore: Semaphore;
    wide_semaphore: Semaphore;
}

get_broadcast_slot :: () -> slot:s64 {
    using g_multicore_state;
    slot := atomic_add(*broadcasts_memory_used_count, 2);
    assert(slot < broadcasts_memory.count, "broadcasts_memory exhausted");
    return slot;
}

reset_broadcasts_memory :: () {
    using g_multicore_state;
    atomic_write(*broadcasts_memory_used_count, 2);
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



    num_cpus := get_number_of_processors();
    assert(num_cpus >= 1);
    if num_cpus > 200  num_cpus = 200;  // Clamp to a value that is reasonable as of 2021, in case we get weird data.
    #if use_real_cores && (OS == .WINDOWS) || (OS == .LINUX) {
        num_cpus /= 2;// This routine reports hyperthreads, so, divide by two, because of Intel marketing.
        // num_cpus += 1; //TODO: Explanation why real cores + 1 hyperthread works
    } 
    //NOTE: you should use real cores otherwise when you profile you might wonder WHY your code is executing like it is singlethreaded when you have chrome running in the background.

    total_lane_count = min(cast(u32)num_cpus, MAX_LANES);
    for i: 0..total_lane_count-1 {
        thread_init(*threads[i], procedure_to_execute_in_all_lanes);
        assert(threads[i].index != 0);

        //prepare worker context
        worker_contexts[i] = .{ lane_slot = cast(u32)i, lane_count = total_lane_count };
        work_ptr := *worker_contexts[i];
        if i == 0 {
            barrier_init(*barriers_memory[0], cast(s32)total_lane_count);
        }
        // barriers_memory[broadcast_slot];
        // work_ptr.barrier_target_ptr = *worker_contexts[0].barrier;

        //start thread
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

//TODO: figure out a way to replace this garbage:
InitializeCodecycle :: (thread_work: *Worker_Context)  #expand {
    thread_work.done = true;
    `Codecycle_Called_InitializeCodecycle :: "make sure you are 'using your_thread_parameter_name; on the main scope"; //@Hack typechecking, not used, maybe delete.
    context.worker_context = thread_work;
}

//------------------
//TODO: reame these procedures to something more semantic content and more consistent case style.
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


// GetLaneSplit :: () -> backup:Lane_Context, new_ctx: Lane_Context, I_am_right_side: bool, new_ane_count: int {
//  using context.worker_context;

//  return backup, new_ctx, I_am_right_side, new_lane_count;
// }
SplitBegin :: SetLaneStackVariables;
SetLaneStackVariables :: (left_ctx:*Worker_Context, right_ctx:*Worker_Context) {
 using context.worker_context;
 LaneSync();
 half := right_ctx.lane_count;
 assert(right_ctx.lane_count == left_ctx.lane_count);
 should_add_remaining := lane_count > 2 && lane_count % 2 != 0;
 if should_add_remaining right_ctx.lane_count+=1;

 //create new barriers using new corresponding lane_count's
 left_broadcast_slot :int;
 if lane_slot == 0 {
     left_ctx.broadcast_slot = get_broadcast_slot();
     right_ctx.broadcast_slot = get_broadcast_slot();
     assert(left_ctx.broadcast_slot != 0);
     assert(right_ctx.broadcast_slot != 0);
     using g_multicore_state;
     barrier_init(*barriers_memory[left_ctx.broadcast_slot], cast(s32)left_ctx.lane_count);
     barrier_init(*barriers_memory[right_ctx.broadcast_slot], cast(s32)right_ctx.lane_count);
 }
 
 //broadcast the slot, the slot is called broadcast_slot but is also used for barriers.
 LaneSync(); //this line is not needed I think
 lane_sync_broadcast(*left_ctx.broadcast_slot, src_lane=0);
 lane_sync_broadcast(*right_ctx.broadcast_slot, src_lane=0);

 assert(left_ctx.broadcast_slot != 0);
 assert(right_ctx.broadcast_slot != 0);

 I_am_right_side := lane_slot + 1 > half;

 //remap the lane slot
 if I_am_right_side {
  right_ctx.lane_slot = lane_slot - half;
 }

 //disables left or right codepaths (crossed)
 if I_am_right_side {
  left_ctx.lane_count = 0; //we disable left lane for all right threads
 } else {
  right_ctx.lane_count = 0; //we disable right lane for all left threads
 }
 LaneSync(); //idk if this is needed
}

GetLaneSplitLeftRight :: () -> backup:Worker_Context, left:Worker_Context, right:Worker_Context {
 using context.worker_context;
 backup   :Worker_Context=  context.worker_context.*;
 left_ctx :Worker_Context=  context.worker_context.*;
 right_ctx:Worker_Context=  context.worker_context.*;

 //setup left right (same for all threads)
 half := lane_count / 2;
 half = max(half, 1);
 left_ctx.lane_count  = half;
 right_ctx.lane_count = half; 
 left_ctx.broadcast_slot = -1;
 right_ctx.broadcast_slot = -1;

 return backup, left_ctx, right_ctx;
}

LaneJoin :: (backup: Worker_Context, left_ctx:Worker_Context, right_ctx:Worker_Context) {
 LaneSync(); //Idk if I should lanesync here.
 LaneActivate(backup);
 assert(context.worker_context.broadcast_slot == 0);

 //delete splitted barriers, (maybe I should GoSingle() this.)
 if context.worker_context.lane_slot == 0 {
    using g_multicore_state;

    barrier_release(*barriers_memory[left_ctx.broadcast_slot]);
    barrier_release(*barriers_memory[right_ctx.broadcast_slot]);
 }

 LaneSync(); //idk if I should lanesync here
}

LaneActivate :: (ctx: Worker_Context) {
 context.worker_context.* = ctx;
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

BroadcastSync :: lane_sync_broadcast;
#if 0 //DISABLED FOR NOW; use lane_sync_broadcast for now
BroadcastSync :: (payload: *$T, src_lane: s64) {
    using g_multicore_state;
    using context.worker_context;
    #assert(size_of(T) <= 8 && "Cannot broadcast values larger than 8 bytes");

    // assert(context.worker_context.barrier_target_ptr != null);
    assert(payload != null, "you must pass a pointer to a pointer, you probably did, 'some_array_view.data' you should do '*some_array_view.data' instead");

    is_src := lane_slot == src_lane;
    is_destination := lane_slot != src_lane;

    if is_src atomic_write(*broadcasts_memory[broadcast_slot], cast(u64)(payload));
    LaneSync();
    if is_destination payload.* = (.*) cast(*T)atomic_read(*broadcasts_memory[broadcast_slot]);
    LaneSync();
}

Lane_Range :: struct {
    min: s64;
    max: s64;
}

//m_range_from_n_idx_m_count is an almost direct copy, src is Ryan Fleury, raddbg codebase, standard MIT licenced, licence at end of file. :tagMITLicense
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

LaneSync :: (caller_loc := #caller_location) #expand {
    //typechecking
    #if #exists(`work_slot) #run assert(false, "\n\n%1:%2,%3: Error: You must NEVER call LaneSync() inside a for work_slot: range.min..range.max",caller_loc.fully_pathed_filename, caller_loc.line_number, caller_loc.character_number,);;
    #if #exists(`it) #run assert(false, "\n\n%1,%2 Error: You must NEVER call LaneSync() inside a for range.min..range.max",caller_loc.fully_pathed_filename, caller_loc.line_number, caller_loc.character_number,);;

    //hacks
    if context.worker_context.lane_count == 0 return; //search_tag_ImNotHappyAboutThisLine
    if context.worker_context.lane_count == 1 return; //search_tag_ImNotHappyAboutThisLine

    lane_sync_broadcast(ptr = null, src_lane = 0, caller_loc = caller_loc);
}

//TODO: delete caller_loc or make use of it. and maybe stylize it to my way of coding (i.e.: the procedure LaneGetRange or the disabled BroadcastSync)
lane_sync_broadcast :: (ptr: *$T, src_lane: s32, caller_loc := #caller_location) #expand #no_debug {
 using context.worker_context;
 using g_multicore_state;
 #assert(size_of(T) <= 8 && "Cannot broadcast values larger than 8 bytes");

 if ptr != null && lane_slot == src_lane {
     memcpy(*broadcasts_memory[broadcast_slot], ptr, size_of(T));
 }

 barrier_wait(*barriers_memory[broadcast_slot]);

 if ptr != null && lane_slot != src_lane {
     memcpy(ptr, *broadcasts_memory[broadcast_slot], size_of(T));
 }

 if ptr {
     barrier_wait(*barriers_memory[broadcast_slot]);
 }
}



/*
TODO: 
    codecycles, tickings of multiple codecycles
    (maye ask Ryan directly because it seems like I cannot figure this out)
*/
//
//from Glenn Fiedler: gafferongames.com/post/fix_your_timestep/
//
g_renderer_time_apollo: Apollo_Time;

//call this from renderer codecycle
RendererTime_Produce :: () {
    ctime := current_time_consensus();
    atomic_write(*g_renderer_time_apollo.low, ctime.low);
    atomic_write(*g_renderer_time_apollo.high, ctime.high);
}

//consume in any other codecycle
RendererTime_Consume :: () -> float64 {
    apollo_time := atomic_read(*g_renderer_time_apollo);
    return to_float64_seconds(apollo_time);

}

Codecycle :: struct {
    hertz:        float64;
    total_time:   float64;
    delta_time:   float64;
    current_time: float64;
    accumulator:  float64;
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

// BroadcastSyncOLD :: (payload: *$T, src_lane: s64) {
//     using g_multicore_state;
//     using context.worker_context;
//     assert(payload != null, "you must pass a pointer to a pointer, you probably did, 'some_array_view.data' you should do '*some_array_view.data' instead");

//     is_src := lane_slot == src_lane;
//     is_destination := lane_slot != src_lane;

//     if is_src atomic_write(*broadcasts_memory[zero_lane_global_slot], cast(u64)(payload));
//     LaneSync();
//     if is_destination payload.* = (.*) cast(*T)atomic_read(*broadcasts_memory[zero_lane_global_slot]);
//     LaneSync();
// }

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
/*
TODO: figure out if this is worth the effort. I personally think that read write and full barriers introduce a lot of code complexitty
and doing mfence is the way to go for this module.


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
*/

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

Copyright (c) 2026 Roey Borsteinas, Ryan Fleury and Epic Games Tools

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
*/