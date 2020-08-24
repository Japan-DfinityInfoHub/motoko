import Prim "mo:prim";
actor {
  public shared(msg) func getCaller() : async (Principal, Blob) {
    return (msg.caller, Prim.blobOfPrincipal(msg.caller));
  };
}
