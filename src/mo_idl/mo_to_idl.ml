open Mo_types
open Mo_types.Type
open Source
open Printf
module E = Mo_def.Syntax
module I = Idllib.Syntax

let env = ref Env.empty
(* For monomorphization *)
let stamp = ref Env.empty
let type_map = ref Env.empty

let normalize str =
  let illegal_chars = ['-'; '/';] in
  String.map (fun c -> if List.mem c illegal_chars then '_' else c) str

let string_of_con vs c =
  let name = string_of_con c in
  match Con.kind c with
  | Def ([], _) -> normalize name
  | Def (tbs, _) ->
     let id = sprintf "%s<%s>" name (String.concat "," (List.map string_of_typ vs)) in
     let n =
       match Env.find_opt id !type_map with
       | None ->
          (match Env.find_opt name !stamp with
           | None ->
              stamp := Env.add name 1 !stamp;
              type_map := Env.add id 1 !type_map;
              1
           | Some n ->
              stamp := Env.add name (n+1) !stamp;
              type_map := Env.add id (n+1) !type_map;
              n+1)
       | Some n -> n
     in Printf.sprintf "%s_%d" (normalize name) n
  | _ -> assert false

let prim p =
  match p with
  | Null -> I.PrimT I.Null
  | Bool -> I.PrimT I.Bool
  | Nat -> I.PrimT I.Nat
  | Nat8 -> I.PrimT I.Nat8
  | Nat16 -> I.PrimT I.Nat16
  | Nat32 -> I.PrimT I.Nat32
  | Nat64 -> I.PrimT I.Nat64
  | Int -> I.PrimT I.Int
  | Int8 -> I.PrimT I.Int8
  | Int16 -> I.PrimT I.Int16
  | Int32 -> I.PrimT I.Int32
  | Int64 -> I.PrimT I.Int64
  | Word8 -> I.PrimT I.Nat8
  | Word16 -> I.PrimT I.Nat16
  | Word32 -> I.PrimT I.Nat32
  | Word64 -> I.PrimT I.Nat64
  | Float -> I.PrimT I.Float64
  | Char -> I.PrimT I.Nat32
  | Text -> I.PrimT I.Text
  | Blob -> I.VecT (I.PrimT I.Nat8 @@ no_region)
  | Error -> assert false

let rec typ vs t =
  (match t with
  | Any -> I.PrimT I.Reserved
  | Non -> I.PrimT I.Empty
  | Prim p -> prim p
  | Var (s, i) -> (typ vs (List.nth vs i)).it
  | Con (c, []) ->
     (match Con.kind c with
     | Def ([], Prim p) -> prim p
     | Def ([], Any) -> I.PrimT I.Reserved
     | Def ([], Non) -> I.PrimT I.Empty
     | _ ->
        chase_con vs c;
        I.VarT (string_of_con vs c @@ no_region)
     )
  | Con (c, ts) ->
     let ts =
       List.map (fun t ->
           match t with
           | Var (s, i) -> List.nth vs i
           | _ -> t
         ) ts in
     (match Con.kind c with
      | Def (tbs, t) ->
         (* use this for inlining defs, doesn't work with recursion
         (typ ts t).it
          *)
         chase_con ts c;
         I.VarT (string_of_con ts c @@ no_region)
      | _ -> assert false)
  | Typ c -> assert false
  | Tup ts ->
     if ts = [] then
       I.PrimT I.Null
     else
       I.RecordT (tuple vs ts)
  | Array t -> I.VecT (typ vs t)
  | Opt t -> I.OptT (typ vs t)
  | Obj (Object, fs) ->
     I.RecordT (List.map (field vs) fs)
  | Obj (Actor, fs) -> I.ServT (meths vs fs)
  | Obj (Module, _) -> assert false
  | Variant fs ->
     I.VariantT (List.map (field vs) fs)
  | Func (Shared s, c, [], ts1, ts2) ->
     let t1 = args vs ts1 in
     (match ts2, c with
     | [], Returns -> I.FuncT ([I.Oneway @@ no_region], t1, [])
     | ts, Promises ->
       I.FuncT (
         (match s with
          | Query -> [I.Query @@ no_region]
          | Write -> []),
         t1, args vs ts)
     | _ -> assert false)
  | Func _ -> assert false
  | Async t -> assert false
  | Mut t -> assert false
  | Pre -> assert false
  ) @@ no_region
and field vs {lab; typ=t} =
  let open Idllib.Escape in
  match unescape lab with
  | Nat nat ->
     I.{label = I.Id nat @@ no_region; typ = typ vs t} @@ no_region
  | Id id ->
     I.{label = I.Named id @@ no_region; typ = typ vs t} @@ no_region
and tuple vs ts =
  List.mapi (fun i x ->
      let id = Lib.Uint32.of_int i in
      I.{label = I.Unnamed id @@ no_region; typ = typ vs x} @@ no_region
    ) ts
and args vs ts =
  List.map (typ vs) ts
and meths vs fs =
  List.fold_right (fun f list ->
      match f.typ with
      | Typ c ->
         chase_con vs c;
         list
      | _ ->
         let meth =
           let open Idllib.Escape in
           match unescape f.lab with
           | Nat nat ->
              I.{var = Lib.Uint32.to_string nat @@ no_region;
                 meth = typ vs f.typ} @@ no_region
           | Id id ->
              I.{var = id @@ no_region;
                 meth = typ vs f.typ} @@ no_region in
         meth :: list
    ) fs []
and chase_con vs c =
  let id = string_of_con vs c in
  if not (Env.mem id !env) then
    (match Con.kind c with
     | Def (_, t) ->
         env := Env.add id (I.PreT @@ no_region) !env;
         let t = typ vs t in
         env := Env.add id t !env
     | _ -> assert false)

let is_actor_con c =
  match Con.kind c with
  | Def ([], Obj (Actor, _)) -> true
  | _ -> false

let chase_decs env =
  ConSet.iter (fun c ->
      if is_actor_con c then chase_con [] c
    ) env.Scope.con_env

let gather_decs () =
  Env.fold (fun id t list ->
      let dec = I.TypD (id @@ no_region, t) @@ no_region in
      dec::list
    ) !env []

let actor progs =
  let open E in
  let find_last_actor (prog : prog) =
    let anon = "anon" in
    let check_dec d t def =
      let rec check_pat p =
        match p.it with
        | WildP -> Some (anon, t)
        | VarP id -> Some (id.it, t)
        | ParP p -> check_pat p
        | _ -> def
      in
      match d.it with
      | ExpD _ -> Some (anon, t)
      | LetD (pat, _) -> check_pat pat
      | _ -> def
    in
    List.fold_left
      (fun actor (d : dec) ->
        match d.note.note_typ with
        | Obj (Actor, _) as t -> check_dec d t actor
        | Con (c, []) as t when is_actor_con c -> check_dec d t actor
        | _ -> actor
      ) None prog.it in

  match progs with
  | [] -> None
  | _ ->
     let prog = Lib.List.last progs in
     match find_last_actor prog with
     | None -> None
     | Some (id, t) -> Some (I.ActorD (id @@ no_region, typ [] t) @@ no_region)

let prog (progs, senv) : I.prog =
  env := Env.empty;
  let actor = actor progs in
  if actor = None then chase_decs senv;
  let decs = gather_decs () in
  let prog = I.{decs = decs; actor = actor} in
  {it = prog; at = no_region; note = ""}
