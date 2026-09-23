#import,dir "../../Multi_Core_By_Default";
#import "Thread";
#import "Basic";

should_exit_software: bool;
main :: () {
   
    initialize_multicore_by_default(WideEntryPoint, use_real_cores=true);

    //we trigger the semapgore at the end of the thread on all threads, then
    //we wait for all threads to stop executing 
    MDF_Semaphore_Wait_For_Wide();

    deinitialize_multicore_by_default();
    

}


test_buffer: [32]float;
test_buffer_ids: [32]int;
#import "Thread";
#import "Atomics";
WideEntryPoint:: (thread: *Thread) -> s64 {
    thread_work : *Worker_Context = cast(*Worker_Context)thread.data;
    InitializeCodecycle(thread_work); //we must call this, this sets the context.worker_context
    assert(context.worker_context != null);

    using context.worker_context; //this is not needed if you use the Higher level API. is just to write less in this example.

    counter:int;
    while !atomic_read(*should_exit_software) {
        LaneSync(); 

        GoWide(test_buffer.count);
        //this is executed on all threads
        for work_slot: range.min .. range.max { 
            test_buffer[work_slot] += work_slot + range.min;
            test_buffer_ids[work_slot] = lane_slot;
        }

        GoNarrow(test_buffer.count);
        //this is executed on 1 thread
        for work_slot: range.min .. range.max { // other theads get range. min == 0 and max == -1
            test_buffer[work_slot] += work_slot + lane_slot;
        }

        
        GoSingle();
        //this is executed on 1 thread and only 1 time
        for work_slot: range.min .. range.max { //range.max == 0 and in jai for 0..0 executes once.
            test_buffer[work_slot] += work_slot + lane_slot;
        }

        LaneSync();
        thread_yield(); //@Hack
        if counter == 5 break;
        counter += 1;
    } //while loop
    
    
    GoNarrow(1);
    for work_slot: range.min .. range.max {
        log("thread_work:% \n test_buffer %",thread_work.*, test_buffer);
        log(" test_buffer_ids %", test_buffer_ids);
        should_exit_software = true;
    }

    //we mus call this, this is not necessary on this example but in the sokol example makes more sense to use semaphores.
    MDF_Semaphore_Green_Wide();

    return 0;
}