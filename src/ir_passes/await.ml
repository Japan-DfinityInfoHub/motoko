open Ir_def
open Mo_types

open Source
open Ir
open Ir_effect
module R = Rename
module T = Type
open Construct

(* continuations, syntactic and meta-level *)

type kont = ContVar of exp
          | MetaCont of T.typ * (exp -> exp)

let meta typ exp =
  let expanded = ref false in
  let exp v = assert (not(!expanded));
              expanded := true;
              exp v
  in
  MetaCont (typ, exp)

(* reify a continuation as syntax *)
let letcont k scope =
  match k with
  | ContVar k' -> scope k' (* letcont eta-contraction *)
  | MetaCont (typ, cont) ->
    let k' = fresh_cont typ in
    let v = fresh_var "v" typ in
    blockE [funcD k' v (cont v)] (* at this point, I'm really worried about variable capture *)
            (scope k')

(* The empty identifier names the implicit return label *)

type label = Return | Throw | Named of string

let ( -@- ) k exp2 =
  match k with
  | ContVar exp1 ->
     exp1 -*- exp2
  | MetaCont (typ,k) ->
     match exp2.it with
     | VarE _ -> k exp2
     | _ ->
        let u = fresh_var "u" typ in
        letE u exp2 (k u)

(* Label environments *)

module LabelEnv = Env.Make(struct type t = label let compare = compare end)

module PatEnv = Env.Make(String)

type label_sort = Cont of kont | Label


(* Trivial translation of pure terms (eff = T.Triv) *)

let rec t_exp context exp =
  assert (eff exp = T.Triv);
  { exp with it = t_exp' context exp.it }
and t_exp' context exp' =
  match exp' with
  | VarE _
  | LitE _ -> exp'
  | PrimE (p, exps) ->
    PrimE (p, List.map (t_exp context) exps)
  | TupE exps ->
    TupE (List.map (t_exp context) exps)
  | OptE exp1 ->
    OptE (t_exp context exp1)
  | TagE (id, exp1) ->
    TagE (id, t_exp context exp1)
  | ProjE (exp1, n) ->
    ProjE (t_exp context exp1, n)
  | DotE (exp1, id) ->
    DotE (t_exp context exp1, id)
  | ActorDotE (exp1, id) ->
    ActorDotE (t_exp context exp1, id)
  | AssignE (exp1, exp2) ->
    AssignE (t_exp context exp1, t_exp context exp2)
  | ArrayE (mut, typ, exps) ->
    ArrayE (mut, typ, List.map (t_exp context) exps)
  | IdxE (exp1, exp2) ->
    IdxE (t_exp context exp1, t_exp context exp2)
  | CallE (exp1, typs, exp2) ->
    CallE (t_exp context exp1, typs, t_exp context exp2)
  | BlockE b ->
    BlockE (t_block context b)
  | IfE (exp1, exp2, exp3) ->
    IfE (t_exp context exp1, t_exp context exp2, t_exp context exp3)
  | SwitchE (exp1, cases) ->
    let cases' = List.map
                  (fun {it = {pat;exp}; at; note} ->
                     {it = {pat;exp = t_exp context exp}; at; note})
                  cases
    in
    SwitchE (t_exp context exp1, cases')
  | LoopE exp1 ->
    LoopE (t_exp context exp1)
  | LabelE (id, _typ, exp1) ->
    let context' = LabelEnv.add (Named id) Label context in
    LabelE (id, _typ, t_exp context' exp1)
  | BreakE (id, exp1) ->
    begin
      match LabelEnv.find_opt (Named id) context with
      | Some (Cont k) -> RetE (k -@- (t_exp context exp1))
      | Some Label -> BreakE (id, t_exp context exp1)
      | None -> assert false
    end
  | RetE exp1 ->
    begin
      match LabelEnv.find_opt Return context with
      | Some (Cont k) -> RetE (k -@- (t_exp context exp1))
      | Some Label -> RetE (t_exp context exp1)
      | None -> assert false
    end
  | AsyncE exp1 ->
     let exp1 = R.exp R.Renaming.empty exp1 in (* rename all bound vars apart *)
     (* add the implicit return/throw label *)
     let k_ret = fresh_cont (typ exp1) in
     let k_fail = fresh_err_cont () in
     let context' =
       LabelEnv.add Return (Cont (ContVar k_ret))
         (LabelEnv.add Throw (Cont (ContVar k_fail)) LabelEnv.empty)
     in
     (asyncE (typ exp1) ([k_ret; k_fail] -->*
                           c_exp context' exp1 (ContVar k_ret))).it
  | TryE _
  | ThrowE _
  | AwaitE _ -> assert false (* these never have effect T.Triv *)
  | AssertE exp1 ->
    AssertE (t_exp context exp1)
  | DeclareE (id, typ, exp1) ->
    DeclareE (id, typ, t_exp context exp1)
  | DefineE (id, mut ,exp1) ->
    DefineE (id, mut, t_exp context exp1)
  | FuncE (x, s, c, typbinds, pat, typ, exp) ->
    let context' = LabelEnv.add Return Label LabelEnv.empty in
    FuncE (x, s, c, typbinds, pat, typ,t_exp context' exp)
  | ActorE (id, ds, ids, t) ->
    ActorE (id, t_decs context ds, ids, t)
  | NewObjE (sort, ids, typ) -> exp'
  | SelfCallE _ -> assert false

and t_dec context dec =
  {dec with it = t_dec' context dec.it}
and t_dec' context dec' =
  match dec' with
  | TypD _ -> dec'
  | LetD (pat, exp) -> LetD (pat, t_exp context exp)
  | VarD (id, exp) -> VarD (id, t_exp context exp)

and t_decs context decs = List.map (t_dec context) decs

and t_block context (ds, exp) = (t_decs context ds, t_exp context exp)

(* non-trivial translation of possibly impure terms (eff = T.Await) *)

and unary context k unE e1 =
  match eff e1 with
  | T.Await ->
    c_exp context e1 (meta (typ e1) (fun v1 -> k -@- unE v1))
  | T.Triv ->
    assert false

and binary context k binE e1 e2 =
  match eff e1, eff e2 with
  | T.Triv, T.Await ->
    let v1 = fresh_var "v" (typ e1) in (* TBR *)
    letE v1 (t_exp context e1)
      (c_exp context e2 (meta (typ e2) (fun v2 -> k -@- binE v1 v2)))
  | T.Await, T.Await ->
    c_exp context e1
      (meta (typ e1) (fun v1 ->
           c_exp context e2
             (meta (typ e2) (fun v2 ->
                  k -@- binE v1 v2))))
  | T.Await, T.Triv ->
    c_exp context e1 (meta (typ e1) (fun v1 -> k -@- binE v1 (t_exp context e2)))
  | T.Triv, T.Triv ->
    assert false

and nary context k naryE es =
  let rec nary_aux vs es  =
    match es with
    | [] -> k -@- naryE (List.rev vs)
    | [e1] when eff e1 = T.Triv ->
       (* TBR: optimization - no need to name the last trivial argument *)
       k -@- naryE (List.rev (e1 :: vs))
    | e1 :: es ->
       match eff e1 with
       | T.Triv ->
          let v1 = fresh_var "v" (typ e1) in
          letE v1 (t_exp context e1)
            (nary_aux (v1 :: vs) es)
       | T.Await ->
          c_exp context e1
            (meta (typ e1) (fun v1 -> nary_aux (v1 :: vs) es))
  in
  nary_aux [] es


and c_if context k e1 e2 e3 =
  letcont k (fun k ->
  let trans_branch exp = match eff exp with
    | T.Triv -> k -*- t_exp context exp
    | T.Await -> c_exp context exp (ContVar k)
  in
  let e2 = trans_branch e2 in
  let e3 = trans_branch e3 in
  match eff e1 with
  | T.Triv ->
    ifE (t_exp context e1) e2 e3 answerT
  | T.Await ->
    c_exp context e1 (meta (typ e1) (fun v1 -> ifE v1 e2 e3 answerT))
  )

and c_loop context k e1 =
  let loop = fresh_var "loop" (contT T.unit) in
  match eff e1 with
  | T.Triv ->
    assert false
  | T.Await ->
    let v1 = fresh_var "v" T.unit in
    blockE [funcD loop v1
              (c_exp context e1 (ContVar loop))]
            (loop -*- unitE)

and c_assign context k e exp1 exp2 =
 match exp1.it with
 | VarE _ ->
   unary context k (fun v2 -> e (AssignE(exp1, v2))) exp2
 | DotE (exp11, id) ->
   binary context k (fun v11 v2 ->
    e (AssignE ({exp1 with it = DotE (v11, id)}, v2))) exp11 exp2
 | IdxE (exp11, exp12) ->
   nary context k (fun vs -> match vs with
    | [v11; v12; v2] ->
      e (AssignE ({exp1 with it = IdxE (v11, v12)}, v2))
    | _ -> assert false)
    [exp11; exp12; exp2]
 | _ -> assert false

and c_exp context exp =
  c_exp' context exp

and c_exp' context exp k =
  let e exp' = {exp with it = exp'} in
  match exp.it with
  | _ when is_triv exp ->
    k -@- (t_exp context exp)
  | VarE _
  | LitE _
  | FuncE _ ->
    assert false
  | PrimE (p, exps) ->
    nary context k (fun vs -> e (PrimE (p, vs))) exps
  | TupE exps ->
    nary context k (fun vs -> e (TupE vs)) exps
  | OptE exp1 ->
    unary context k (fun v1 -> e (OptE v1)) exp1
  | TagE (i, exp1) ->
    unary context k (fun v1 -> e (TagE (i, v1))) exp1
  | ProjE (exp1, n) ->
    unary context k (fun v1 -> e (ProjE (v1, n))) exp1
  | ActorE _ ->
    assert false; (* ActorE fields cannot await *)
  | DotE (exp1, id) ->
    unary context k (fun v1 -> e (DotE (v1, id))) exp1
  | ActorDotE (exp1, id) ->
    unary context k (fun v1 -> e (DotE (v1, id))) exp1
  | AssignE (exp1, exp2) ->
    c_assign context k e exp1 exp2
  | ArrayE (mut, typ, exps) ->
    nary context k (fun vs -> e (ArrayE (mut, typ, vs))) exps
  | IdxE (exp1, exp2) ->
    binary context k (fun v1 v2 -> e (IdxE (v1, v2))) exp1 exp2
  | CallE (exp1, typs, exp2) ->
    binary context k (fun v1 v2 -> e (CallE (v1, typs, v2))) exp1 exp2
  | BlockE (decs, exp) ->
    c_block context decs exp k
  | IfE (exp1, exp2, exp3) ->
    c_if context k exp1 exp2 exp3
  | SwitchE (exp1, cases) ->
    letcont k (fun k ->
    let cases' = List.map
                   (fun {it = {pat;exp}; at; note} ->
                     let exp' = match eff exp with
                       | T.Triv -> k -*- (t_exp context exp)
                       | T.Await -> c_exp context exp (ContVar k)
                     in
                     {it = {pat;exp = exp' }; at; note})
                  cases
    in
    begin
    match eff exp1 with
    | T.Triv ->
       {exp with it = SwitchE(t_exp context exp1, cases')}
    | T.Await ->
       c_exp context exp1
         (meta (typ exp1)
            (fun v1 -> {exp with it = SwitchE(v1,cases')}))
    end)
  | TryE (exp1, cases) ->
    (* TODO: do we need to reify f? *)
    let f = match LabelEnv.find Throw context with Cont f -> f | _ -> assert false in
    letcont f (fun f ->
    letcont k (fun k ->
    let cases' = List.map
                   (fun {it = {pat;exp}; at; note} ->
                     let exp' = match eff exp with
                       | T.Triv -> k -*- (t_exp context exp)
                       | T.Await -> c_exp context exp (ContVar k)
                     in
                     {it = {pat;exp = exp' }; at; note})
                   cases
    in
    let error = fresh_var "v" T.catch  in
    let cases' = cases' @ [{it = {pat = varP error; exp = f -*- error};
                            at = no_region;
                            note = ()}] in
    let throw = fresh_err_cont () in
    let e =  fresh_var "e" T.catch in
    let context' = LabelEnv.add Throw (Cont (ContVar throw)) context in
    begin
    match eff exp1 with
    | T.Triv ->
      k -*- (t_exp context exp1)
    | T.Await ->
      blockE
        [funcD throw e { it = SwitchE (e, cases');
                          at = exp.at;
                          note = {note_eff = T.Await; (* shouldn't matter *)
                                  note_typ = T.unit}
        }]
        (c_exp context' exp1 (ContVar k))
    end))
  | LoopE exp1 ->
    c_loop context k exp1
  | LabelE (id, _typ, exp1) ->
     letcont k
       (fun k ->
         let context' = LabelEnv.add (Named id) (Cont (ContVar k)) context in
         c_exp context' exp1 (ContVar k)) (* TODO optimize me, if possible *)
  | BreakE (id, exp1) ->
    begin
      match LabelEnv.find_opt (Named id) context with
      | Some (Cont k') ->
         c_exp context exp1 k'
      | Some Label -> assert false
      | None -> assert false
    end
  | RetE exp1 ->
    begin
      match LabelEnv.find_opt Return context with
      | Some (Cont k') ->
         c_exp context exp1 k'
      | Some Label -> assert false
      | None -> assert false
    end
  | ThrowE exp1 ->
    begin
      match LabelEnv.find_opt Throw context with
      | Some (Cont k') -> c_exp context exp1 k'
      | Some Label
      | None -> assert false
    end
  | AsyncE exp1 ->
     (* add the implicit return label *)
    let k_ret = fresh_cont (typ exp1) in
    let k_fail = fresh_err_cont () in
    let context' =
      LabelEnv.add Return (Cont (ContVar k_ret))
        (LabelEnv.add Throw (Cont (ContVar k_fail)) LabelEnv.empty)
    in
    k -@- (asyncE (typ exp1) ([k_ret; k_fail] -->*
                                   (c_exp context' exp1 (ContVar k_ret))))
  | AwaitE exp1 ->
     let r = match LabelEnv.find_opt Throw context with
     | Some (Cont r) -> r
     | Some Label
     | None -> assert false
     in
     letcont r
       (fun r ->
     letcont k
       (fun k ->
         let kr = tupE [k;r] in
         match eff exp1 with
         | T.Triv ->
            awaitE (typ exp) (t_exp context exp1) kr
         | T.Await ->
            c_exp context  exp1
              (meta (typ exp1) (fun v1 -> (awaitE (typ exp) v1 kr)))
       )
     )
  | AssertE exp1 ->
    unary context k (fun v1 -> e (AssertE v1)) exp1
  | DeclareE (id, typ, exp1) ->
    unary context k (fun v1 -> e (DeclareE (id, typ, v1))) exp1
  | DefineE (id, mut, exp1) ->
    unary context k (fun v1 -> e (DefineE (id, mut, v1))) exp1
  | NewObjE _ -> exp
  | SelfCallE _ -> assert false

and c_block context decs exp k =
  let is_typ dec =
    match dec.it with
    | TypD _ -> true
    | _ -> false
  in
  let (typ_decs,val_decs) = List.partition is_typ decs in
  blockE typ_decs
    (declare_decs val_decs (c_decs context val_decs (meta T.unit (fun _ -> c_exp context exp k))))

and c_dec context dec (k:kont) =
  match dec.it with
  | TypD _ ->
    assert false
  | LetD (pat,exp) ->
    let patenv,pat' = rename_pat pat in
    let block exp =
      let dec_pat' = {dec with it = LetD(pat',exp)} in
      blockE (dec_pat' :: define_pat patenv pat)
             (k -@- tupE[])
    in
     begin
       match eff exp with
       | T.Triv ->
         block (t_exp context exp)
       | T.Await ->
         c_exp context exp (meta (typ exp)
                              (fun v -> block v))
     end
  | VarD (id,exp) ->
    begin
      match eff exp with
      | T.Triv ->
        k -@- define_idE id Var (t_exp context exp)
      | T.Await ->
        c_exp context exp
          (meta (typ exp)
             (fun v -> k -@- define_idE id Var v))
    end


and c_decs context decs k =
  match decs with
  | [] ->
    k -@- unitE
  | dec :: decs ->
    c_dec context dec (meta T.unit (fun v -> c_decs context decs k))

(* Blocks and Declarations *)

and declare_dec dec exp : exp =
  match dec.it with
  | TypD _ -> assert false
  | LetD (pat, _) -> declare_pat pat exp
  | VarD (id, exp1) -> declare_id id (T.Mut (typ exp1)) exp

and declare_decs decs exp : exp =
  match decs with
  | [] -> exp
  | dec :: decs' ->
    declare_dec dec (declare_decs decs' exp)

(* Patterns *)

and declare_id id typ exp =
  declare_idE id typ exp

and declare_pat pat exp : exp =
  match pat.it with
  | WildP | LitP  _ ->  exp
  | VarP id -> declare_id id pat.note exp
  | TupP pats -> declare_pats pats exp
  | ObjP pfs -> declare_pats (pats_of_obj_pat pfs) exp
  | OptP pat1
  | TagP (_, pat1) -> declare_pat pat1 exp
  | AltP (pat1, pat2) -> declare_pat pat1 exp

and declare_pats pats exp : exp =
  match pats with
  | [] -> exp
  | pat :: pats' ->
    declare_pat pat (declare_pats pats' exp)

and rename_pat pat =
  let (patenv,pat') = rename_pat' pat in
  (patenv, { pat with it = pat' })

and rename_pat' pat =
  match pat.it with
  | WildP
  | LitP _ -> (PatEnv.empty, pat.it)
  | VarP id ->
    let v = fresh_var "v" pat.note in
    (PatEnv.singleton id v,
     VarP (id_of_exp v))
  | TupP pats ->
    let (patenv,pats') = rename_pats pats in
    (patenv,TupP pats')
  | ObjP pfs ->
    let (patenv, pats') = rename_pats (pats_of_obj_pat pfs) in
    let pfs' = replace_obj_pat pfs pats' in
    (patenv, ObjP pfs')
  | OptP pat1 ->
    let (patenv,pat1) = rename_pat pat1 in
    (patenv, OptP pat1)
  | TagP (i, pat1) ->
    let (patenv,pat1) = rename_pat pat1 in
    (patenv, TagP (i, pat1))
  | AltP (pat1,pat2) ->
    assert(Freevars.S.is_empty (snd (Freevars.pat pat1)));
    assert(Freevars.S.is_empty (snd (Freevars.pat pat2)));
    (PatEnv.empty,pat.it)

and rename_pats pats =
  match pats with
  | [] -> (PatEnv.empty,[])
  | (pat :: pats) ->
    let (patenv1, pat') = rename_pat pat in
    let (patenv2, pats') = rename_pats pats in
    (PatEnv.disjoint_union patenv1 patenv2, pat' :: pats')

and define_pat patenv pat : dec list =
  match pat.it with
  | WildP
  | LitP _ ->
    []
  | VarP id ->
    [ expD (define_idE id Const (PatEnv.find id patenv)) ]
  | TupP pats -> define_pats patenv pats
  | ObjP pfs -> define_pats patenv (pats_of_obj_pat pfs)
  | OptP pat1
  | TagP (_, pat1) -> define_pat patenv pat1
  | AltP (pat1, pat2) ->
    assert(Freevars.S.is_empty (snd (Freevars.pat pat1)));
    assert(Freevars.S.is_empty (snd (Freevars.pat pat2)));
    []

and define_pats patenv (pats : pat list) : dec list =
  List.concat (List.map (define_pat patenv) pats)

and t_prog (prog, flavor) =
  (t_block LabelEnv.empty prog, { flavor with has_await = false })

let transform prog = t_prog prog


