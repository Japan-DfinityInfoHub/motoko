// import Set

////////////////////////////////////////////////////////////////////
let SetDb = new {

  private func setDbPrint(s:Set<Nat>) {
    func rec(s:Set<Nat>, ind:Nat, bits:Hash) {
      func indPrint(i:Nat) {
	      if (i == 0) { } else { print "| "; indPrint(i-1) }
      };
      func bitsPrintRev(bits:Bits) {
	      switch bits {
	      case null { print "" };
	      case (?(bit,bits_)) {
		           bitsPrintRev(bits_);
		           if bit { print "1R." }
		           else   { print "0L." }
	           }
	      }
      };
      switch s {
      case null {
	           //indPrint(ind);
	           //bitsPrintRev(bits);
	           //print "(null)\n";
	         };
      case (?n) {
	           switch (n.key) {
	           case null {
		                //indPrint(ind);
		                //bitsPrintRev(bits);
		                //print "bin \n";
		                rec(n.right, ind+1, ?(true, bits));
		                rec(n.left,  ind+1, ?(false,bits));
		                //bitsPrintRev(bits);
		                //print ")\n"
		              };
	           case (?k) {
		                //indPrint(ind);
		                bitsPrintRev(bits);
		                print "(leaf ";
		                printInt k;
		                print ")\n";
		              };
	           }
	         };
      }
    };
    rec(s, 0, null);
  };

  ////////////////////////////////////////////////////////////////////////////////

  private func natEq(n:Nat,m:Nat):Bool{ n == m};

  func insert(s:Set<Nat>, x:Nat, xh:Hash):Set<Nat> = {
    print "  setInsert(";
    printInt x;
    print ")";
    let r = Set.insert<Nat>(s,x,xh);
    print ";\n";
    setDbPrint(r);
    r
  };

  func mem(s:Set<Nat>, sname:Text, x:Nat, xh:Hash):Bool = {
    print "  setMem(";
    print sname;
    print ", ";
    printInt x;
    print ")";
    let b = Set.mem<Nat>(s,x,xh,natEq);
    if b { print " = true" } else { print " = false" };
    print ";\n";
    b
  };

  func union(s1:Set<Nat>, s1name:Text, s2:Set<Nat>, s2name:Text):Set<Nat> = {
    print "  setUnion(";
    print s1name;
    print ", ";
    print s2name;
    print ")";
    // also: test that merge agrees with disj:
    let r1 = Set.union<Nat>(s1, s2);
    let r2 = Trie.disj<Nat,(),(),()>(s1, s2, natEq, func (_:?(),_:?()):(())=());
    assert(Trie.equalStructure<Nat,()>(r1, r2, natEq, Set.unitEq));
    print ";\n";
    setDbPrint(r1);
    print "=========\n";
    setDbPrint(r2);
    r1
  };

  func intersect(s1:Set<Nat>, s1name:Text, s2:Set<Nat>, s2name:Text):Set<Nat> = {
    print "  setIntersect(";
    print s1name;
    print ", ";
    print s2name;
    print ")";
    let r = Set.intersect<Nat>(s1, s2, natEq);
    print ";\n";
    setDbPrint(r);
    r
  };

};
