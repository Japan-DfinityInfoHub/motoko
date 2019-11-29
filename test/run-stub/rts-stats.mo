let s0 = rts_heap_size();
let a0 = rts_total_allocation();
ignore(Array_init<()>(2500, ()));
let s1 = rts_heap_size();
let a1 = rts_total_allocation();

// the following are too likey to change to be included in the test output
// debugPrint("Size and allocation before: " # debug_show (s0, a0));
// debugPrint("Size and allocation after:  " # debug_show (s1, a1));

// this should be rather stable unless the array representation changes
debugPrint("Size and allocation delta:  " # debug_show (s1-s0, a1-a0));
assert (s1-s0 == 10008);
assert (a1-a0 == 10008);

// no point running these in the interpreter
//SKIP run
//SKIP run-low
//SKIP run-ir
