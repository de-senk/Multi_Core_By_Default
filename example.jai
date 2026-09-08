
#import,dir "../MultiCoreByDefault";
#import "Thread";
#import "Basic";
main :: () {
    initialize_multicore_by_default_use_all_threads(codecycle_game_update);
    deinitialize_multicore_by_default();

}

_dumb_trick_buffer: [32]float;
_dumb_trick_buffer_ids: [32]int;
codecycle_game_update:: (thread: *Thread) -> s64 {
using thread_data : *Worker_Context = cast(*Worker_Context)thread.data;
defer done = true; //important otherwise we close main
    counter:= 0;
    while true {
        counter += 1;
            sync_lanes_for_range(_dumb_trick_buffer.count, #code {
            _dumb_trick_buffer[work_slot] += work_slot + start_slot;
            _dumb_trick_buffer_ids[work_slot] = thread_data.lane_slot;
            // log("TEST-> % % %, WORK SLOT %",thread_data.lane_slot, start_slot, end_slot, work_slot);
        });


        if counter == 5 break;
    }
    log("% %",thread_data.*, _dumb_trick_buffer);
    log("%", _dumb_trick_buffer_ids);
return 0;
}