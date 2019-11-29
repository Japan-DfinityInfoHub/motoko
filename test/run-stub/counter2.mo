let a = actor {
  var c = 1;
  public func inc() {
    c += 1;
    debugPrintNat c;
  };
  public func printCounter () {
    debugPrintNat c;
  }
};

a.inc();
a.inc();
a.inc();
a.printCounter();

func test() {
  var i : Int = 10;
  while (i  > 0) {
    a.inc();
    i -= 1;
  }
};

let _ = test();
