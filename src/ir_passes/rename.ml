open Ir_def

open Source
open Ir

module Renaming = Map.Make(String)

(* One traversal for each syntactic category, named by that category *)

module Stamps = Map.Make(String)
let stamps = ref Stamps.empty

let fresh_id id =
  let n = Lib.Option.get (Stamps.find_opt id !stamps) 0 in
  stamps := Stamps.add id (n + 1) !stamps;
  Printf.sprintf "%s/%i" id n

let id rho i =
  try Renaming.find i rho
  with Not_found -> i

let id_bind rho i =
  let i' = fresh_id i in
  (i', Renaming.add i i' rho)

let arg_bind rho a =
  let i' = fresh_id a.it in
  ({a with it = i'}, Renaming.add a.it i' rho)

let rec exp rho e  =
    {e with it = exp' rho e.it}

and exp' rho e  = match e with
  | VarE i              -> VarE (id rho i)
  | LitE l              -> e
  | PrimE (p, es)       -> PrimE (p, List.map (exp rho) es)
  | TupE es             -> TupE (List.map (exp rho) es)
  | ProjE (e, i)        -> ProjE (exp rho e, i)
  | ActorE (i, ds, fs, t)-> let i',rho' = id_bind rho i in
                            let ds', rho'' = decs rho' ds
                            in ActorE (i', ds', fields rho'' fs, t)
  | DotE (e, i)         -> DotE (exp rho e, i)
  | ActorDotE (e, i)    -> ActorDotE (exp rho e, i)
  | AssignE (e1, e2)    -> AssignE (exp rho e1, exp rho e2)
  | ArrayE (m, t, es)   -> ArrayE (m, t, exps rho es)
  | IdxE (e1, e2)       -> IdxE (exp rho e1, exp rho e2)
  | CallE (e1, ts, e2)  -> CallE  (exp rho e1, ts, exp rho e2)
  | BlockE (ds, e1)     -> let ds', rho' = decs rho ds
                           in BlockE (ds', exp rho' e1)
  | IfE (e1, e2, e3)    -> IfE (exp rho e1, exp rho e2, exp rho e3)
  | SwitchE (e, cs)     -> SwitchE (exp rho e, cases rho cs)
  | LoopE e1            -> LoopE (exp rho e1)
  | LabelE (i, t, e)    -> let i',rho' = id_bind rho i in
                           LabelE(i', t, exp rho' e)
  | BreakE (i, e)       -> BreakE(id rho i,exp rho e)
  | RetE e              -> RetE (exp rho e)
  | AsyncE e            -> AsyncE (exp rho e)
  | AwaitE e            -> AwaitE (exp rho e)
  | AssertE e           -> AssertE (exp rho e)
  | OptE e              -> OptE (exp rho e)
  | TagE (i, e)         -> TagE (i, exp rho e)
  | DeclareE (i, t, e)  -> let i',rho' = id_bind rho i in
                           DeclareE (i', t, exp rho' e)
  | DefineE (i, m, e)   -> DefineE (id rho i, m, exp rho e)
  | FuncE (x, s, c, tp, p, ts, e) ->
     let p', rho' = args rho p in
     let e' = exp rho' e in
     FuncE (x, s, c, tp, p', ts, e')
  | NewObjE (s, fs, t)  -> NewObjE (s, fields rho fs, t)
  | ThrowE e            -> ThrowE (exp rho e)
  | TryE (e, cs)        -> TryE (exp rho e, cases rho cs)
  | SelfCallE (ts, e1, e2, e3) ->
     SelfCallE (ts, exp rho e1, exp rho e2, exp rho e3)

and exps rho es  = List.map (exp rho) es

and fields rho fs =
  List.map (fun f -> { f with it = { f.it with var = id rho f.it.var } }) fs

and args rho as_ =
  match as_ with
  | [] -> ([],rho)
  | a::as_ ->
     let (a', rho') = arg_bind rho a in
     let (as_', rho'') = args rho' as_ in
     (a'::as_', rho'')

and pat rho p =
    let p',rho = pat' rho p.it in
    {p with it = p'}, rho

and pat' rho p = match p with
  | WildP         -> (p, rho)
  | VarP i        ->
    let i, rho' = id_bind rho i in
     (VarP i, rho')
  | TupP ps       -> let (ps, rho') = pats rho ps in
                     (TupP ps, rho')
  | ObjP pfs      ->
    let (pats, rho') = pats rho (pats_of_obj_pat pfs) in
    (ObjP (replace_obj_pat pfs pats), rho')
  | LitP l        -> (p, rho)
  | OptP p        -> let (p', rho') = pat rho p in
                     (OptP p', rho')
  | TagP (i, p)   -> let (p', rho') = pat rho p in
                     (TagP (i, p'), rho')
  | AltP (p1, p2) -> assert(Freevars.S.is_empty (snd (Freevars.pat p1)));
                     assert(Freevars.S.is_empty (snd (Freevars.pat p2)));
                     let (p1', _) = pat rho p1 in
                     let (p2' ,_) = pat rho p2 in
                     (AltP (p1', p2'), rho)

and pats rho ps  =
  match ps with
  | [] -> ([],rho)
  | p::ps ->
     let (p', rho') = pat rho p in
     let (ps', rho'') = pats rho' ps in
     (p'::ps', rho'')

and case rho (c : case) =
    {c with it = case' rho c.it}
and case' rho { pat = p; exp = e} =
  let (p', rho') = pat rho p in
  let e' = exp rho' e in
  {pat=p'; exp=e'}

and cases rho cs = List.map (case rho) cs

and dec rho d =
  let (mk_d, rho') = dec' rho d.it in
  ({d with it = mk_d}, rho')

and dec' rho d = match d with
  | LetD (p, e) ->
     let p', rho = pat rho p in
     (fun rho' -> LetD (p',exp rho' e)),
     rho
  | VarD (i, e) ->
     let i', rho = id_bind rho i in
     (fun rho' -> VarD (i',exp rho' e)),
     rho
  | TypD c -> (* we don't rename type names *)
     (fun rho -> d),
     rho

and decs rho ds =
  let rec decs_aux rho ds =
    match ds with
    | [] -> ([], rho)
    | d::ds ->
       let (mk_d, rho') = dec rho d in
       let (mk_ds, rho'') = decs_aux rho' ds in
       (mk_d::mk_ds, rho'')
  in
  let mk_ds, rho' = decs_aux rho ds in
  let ds' = List.map (fun mk_d -> { mk_d with it = mk_d.it rho' } ) mk_ds in
  (ds', rho')
