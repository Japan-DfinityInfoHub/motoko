import Principal = "mo:base/Principal";

actor {

   var c = 0;

   public func inc() : async () { c += 1 };
   public func set(n : Nat) : async () { c := n };
   public query func read() : async Nat { c };
   public func reset() : () { c := 0 }; // oneway
/*
// tag::inspect-trick[]
   system func inspect() : Bool {
     false
   }
// end::inspect-trick[]
*/
};
