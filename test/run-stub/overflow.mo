// We have theses tests in run-dfinity because we want to check that certain
// traps are happening, and a good way to test this is if a message gets
// aborted.

ignore(async {
    ignore ((0-1):Int);
    debugPrint("This is reachable.");
});
ignore(async {
    ignore ((1-1):Nat);
    debugPrint("This is reachable.");
});
ignore(async {
    ignore ((0-1):Nat);
    debugPrint("This should be unreachable.");
});
ignore(async {
    ignore ((0-1):Nat);
    debugPrint("This should be unreachable.");
});
/*
ignore(async {
    ignore ((18446744073709551615 + 0):Nat);
    debugPrint("This is reachable.");
});
*/
ignore(async {
    ignore ((9223372036854775806 + 9223372036854775806 + 1):Nat);
    debugPrint("This is reachable.");
});
ignore(async {
    ignore ((9223372036854775806 + 9223372036854775806 + 2):Nat);
    debugPrint("This is reachable.");
});
