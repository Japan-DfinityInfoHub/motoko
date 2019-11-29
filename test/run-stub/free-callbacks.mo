actor a {

  public func ping() : async () {
  };

  public func go() = ignore async {
    let s0 = rts_heap_size();
    let a = Array_init<()>(2500, ());
    await ping();
    let s1 = rts_heap_size();
    await ping();
    let s2 = rts_heap_size();
    // last use of a
    ignore(a);
    await ping();
    // now a should be freed
    let s3 = rts_heap_size();

    debugPrint(
      "Ignore Diff: " #
      debug_show s0 # " " #
      debug_show s1 # " " #
      debug_show s2 # " " #
      debug_show s3 # " "
    );
    // This checks that the array (10_000 bytes) has been allocated, but then
    // freed. It allows for some wiggle room
    assert (s1-s0 > 5_000);
    assert (s2-s0 > 5_000);
    assert (s3-s0 < 5_000);
  };

  go();
}

//SKIP run
//SKIP run-low
//SKIP run-ir
