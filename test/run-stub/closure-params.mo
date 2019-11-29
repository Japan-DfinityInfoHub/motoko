let a = actor {
  var c = 0;
  public func incn(n : Nat) : () {
    c += n;
    debugPrintNat(c);
  };
  public func readCounter(f : shared Nat -> ()) : () {
    f(c);
  };

  public func printNat(n: Nat) { debugPrintNat n };

  incn(1);
  readCounter(printNat);
  incn(2);
  readCounter(printNat);
  incn(3);
  readCounter(printNat);
  incn(4);
  readCounter(printNat);
  incn(5);
  readCounter(printNat);
};

