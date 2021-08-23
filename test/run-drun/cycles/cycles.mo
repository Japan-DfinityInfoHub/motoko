import Prim "mo:⛔";

module {

  public let balance : () -> Nat64 = Prim.cyclesBalance;

  public let available : () -> Nat64 = Prim.cyclesAvailable;

  public let accept : Nat64 -> Nat64 = Prim.cyclesAccept;

  public let add : Nat64 -> () = Prim.cyclesAdd;

  public let refunded : () -> Nat64 = Prim.cyclesRefunded;

  public func provisional_top_up_actor(a : actor {}, amount : Nat) : async () {
    let amount_ = amount;
    let ic00 = actor "aaaaa-aa" : actor {
      provisional_top_up_canister :
        { canister_id: Principal; amount : Nat } -> async ();
    };
    await ic00.provisional_top_up_canister({
      canister_id = Prim.principalOfActor(a);
      amount = amount_})
  }
}
