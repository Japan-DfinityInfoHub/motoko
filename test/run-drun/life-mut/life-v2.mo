import P = "mo:prim";

object Random {
  var state = 1;
  public func next() : Bool {
    state := (123138118391*state + 133489131) % 9999;
    (state % 2 == 0)
  };
};

class below(u : Nat) {
  var i = 0;
  public func next() : ?Nat { if (i >= u) null else {let j = i; i += 1; ?j} };
};

func readBit(bits : [var Word64], index : Nat) : Bool {
  let bit = P.natToWord64(index);
  let mask : Word64 = 1 << (bit % 64);
  (bits[P.word64ToNat(bit >> 6)] & mask) == mask
};

func writeBit(bits : [var Word64], index : Nat, v : Bool) {
  let bit = P.natToWord64(index);
  let mask : Word64 = 1 << (bit % 64);
  let i = P.word64ToNat(bit >> 6);
  if v {
    bits[i] |= mask
  }
  else {
    bits[i] &= ^mask;
  }
};

type Cell = Bool;

type State = {
  #v1 : [[var Cell]];
  #v2 : {size : Nat; bits : [var Word64]}
};

class Grid(state : State) {

  let (n : Nat, bits : [var Word64]) =
    switch state {
      case (#v1 css) {
        let n = css.size();
        let len = (n * n) / 64 + 1;
        let bits = P.Array_init<Word64>(len, 0);
        for (i in css.keys()) {
          for (j in css[i].keys()) {
            writeBit(bits, i * n + j, css[i][j]);
          };
        };
        (n, bits)
      };
      case (#v2 .{size; bits}) {
        (size,bits)
      }
    };

  public func size() : Nat { n };

  public func get(i : Nat, j : Nat) : Cell {
    readBit(bits, i * n + j);
  };

  public func set(i : Nat, j : Nat, v : Cell) {
    writeBit(bits, i * n + j, v);
  };

  func pred(i : Nat) : Nat { (n + i - 1) % n };

  func succ(i : Nat) : Nat { (i + 1) % n };

  func count(i : Nat, j : Nat) : Nat { if (get(i, j)) 1 else 0 };

  func living(i : Nat, j : Nat) : Nat {
    count(pred i, pred j) + count(pred i, j) + count(pred i, succ j) +
    count(     i, pred j)                    + count(     i, succ j) +
    count(succ i, pred j) + count(succ i, j) + count(succ i, succ j)
  };

  func nextCell(i : Nat, j : Nat) : Cell {
    let l : Nat = living(i, j);
    if (get(i, j))
      l == 2 or l == 3
    else
      l == 3;
  };

  public func next(dst : Grid) {
    for (i in below(n)) {
      for (j in below(n)) {
        dst.set(i, j, nextCell(i, j));
      };
    };
  };

  public func toState() : State {
    let ws = bits;
    #v2 .{ size = n; bits = ws }
  };

  public func toText() : Text {
    var t = "\n";
    for (i in below(n)) {
      for (j in below(n)) {
        t #= if (get(i, j)) "O" else " ";
      };
      t #= "\n";
    };
    t
  };
};

actor Life {

  stable var state : State = {
    let n = 32;
    let len = (n * n) / 64 + 1;
    let words = P.Array_init(len, 0 : Word64);
    for (i in words.keys()) {
      var word : Word64 = 0;
      for (j in below(64)) {
        let bit : Word64 = if (Random.next()) 0 else 1;
        word |= bit;
        word <<= 1;
      };
      words[i] := word;
    };
    #v2 .{ size = n; bits = words };
  };

  flexible var src = Grid(state);
  flexible var dst = Grid(state);

  func update(c : Nat) {
    var i = c;
    while (i > 0) {
      src.next(dst);
      let temp = src;
      src := dst;
      dst := temp;
      i -= 1;
    };
  };

  system func preupgrade() {
    state := src.toState();
  };

  system func postupgrade() {
    P.debugPrint("upgraded!");
  };

  public func advance(n : Nat) : async () {
     update(n);
  };

  public query func show() : async () {
     P.debugPrint(src.toText());
  };

};
