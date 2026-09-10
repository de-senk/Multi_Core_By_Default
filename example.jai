//NOTE: this contains a lot of machinery/boilerplate just to be able to run in sokol so thereefore there is a todo
//TODO: reduce the machinery needed to make this work.
// problem 1, WideEntryPoint need to call InitializeCodecycle
// problem 2, semaphores wrangling is annoying, but idk what to do.
// problem 3, thread_yield() is stupid, but maybe there is no escape from it.
#import,dir "../Multi_Core_By_Default";
#import "Thread";
#import "Basic";

should_exit_software: bool;
g_multicore_is_initialized: bool;
g_sokol_is_running: bool;
g_sokol_weird_counter: int;
main :: () {
    //assume you dont really have control of the windowing and entrypont,
    //...per example, Sokol

    //sokol internally calls your callbacks:
    sokol_init_frame_cb();
    while g_sokol_is_running sokol_frame_cb();
    sokol_cleanup_cb();
}

sokol_init_frame_cb :: () {
    g_sokol_is_running= true;
}

sokol_request_quit :: () {
    g_sokol_weird_counter+=1;

    //because sokol can run more than 1 frame_cb when you request a quit.
    if g_sokol_weird_counter > 3 g_sokol_is_running = false;
}

sokol_cleanup_cb :: () {

}

sokol_frame_cb :: () {

    if should_exit_software {
        lane_cont := GetLaneCount();
        if lane_cont > 0 {
            for 0..lane_cont-1 MDF_Semaphore_Green_Wide();
            deinitialize_multicore_by_default();
        }
        sokol_request_quit();
        return;
    }
    if !g_multicore_is_initialized {
        g_multicore_is_initialized = true;
        initialize_multicore_by_default(WideEntryPoint);
    }

    //I need to rename these
    MDF_Semaphore_Green_Frame();
    MDF_Semaphore_Wait_For_Wide();

    //here you call your stuff that only can becalled inside frame_cb()
    // sg_end_pass();
    // sg_commit();

}

test_buffer: [32]float;
test_buffer_ids: [32]int;
#import "Thread";
#import "Atomics";
WideEntryPoint:: (thread: *Thread) -> s64 {
    using thread_work : *Worker_Context = cast(*Worker_Context)thread.data;
    InitializeCodecycle(thread_work);
    assert(g_multicore_is_initialized);
    assert(context.worker_context != null);
    counter:int;
    while !atomic_read(*should_exit_software) {
        LaneSync();
        MDF_Semaphore_Wait_For_Frame();
        LaneSync();

        GoWide(test_buffer.count);

        //this is executed on all threads
        for work_slot: range.min .. range.max {
            test_buffer[work_slot] += work_slot + range.min;
            test_buffer_ids[work_slot] = lane_slot;
        }

        GoNarrow(test_buffer.count);

        //this is executed on 1 thread
        for work_slot: range.min .. range.max {
            test_buffer[work_slot] += work_slot + lane_slot;
        }

        LaneSync();
        MDF_Semaphore_Green_Wide();
        thread_yield(); //@Hack
        if counter == 5 break;
        counter += 1;
    }

    GoNarrow(1);
    for work_slot: range.min .. range.max {
        log("thread_work:% \n test_buffer %",thread_work.*, test_buffer);
        log(" test_buffer_ids %", test_buffer_ids);
        should_exit_software = true;
    }

    MDF_Semaphore_Green_Wide();

    return 0;
}