(* WIP translation of syntaxops to use IR in place of Source *)
open Source
open Ir
open Ir_effect

module T = Mo_types.Type

type var = exp

(* Field names *)

let nameN s = s

let nextN = "next"

(* Identifiers *)

let idE id typ =
  { it = VarE id;
    at = no_region;
    note = { note_typ = typ; note_eff = T.Triv }
  }

let id_of_exp x =
  match x.it with
  | VarE x -> x
  | _ -> failwith "Impossible: id_of_exp"

let arg_of_exp x =
  match x.it with
  | VarE i -> { it = i; at = x.at; note = x.note.note_typ }
  | _ -> failwith "Impossible: arg_of_exp"

let exp_of_arg a =
  idE a.it a.note

(* Fresh id generation *)

module Stamps = Map.Make(String)
let id_stamps = ref Stamps.empty

let fresh name_base () : string =
  let n = Lib.Option.get (Stamps.find_opt name_base !id_stamps) 0 in
  id_stamps := Stamps.add name_base (n + 1) !id_stamps;
  Printf.sprintf "$%s/%i" name_base n

let fresh_id name_base () : id =
  fresh name_base ()

let fresh_var name_base typ : exp =
  let name = fresh name_base () in
  idE name typ

let fresh_vars name_base ts =
  List.mapi (fun i t -> fresh_var (Printf.sprintf "%s%i" name_base i) t) ts


(* Patterns *)

let varP x =
  { it = VarP (id_of_exp x);
    at = x.at;
    note = x.note.note_typ
  }

let tupP pats =
  { it = TupP pats;
    note = T.Tup (List.map (fun p -> p.note) pats);
    at = no_region }

let seqP ps =
  match ps with
  | [p] -> p
  | ps -> tupP ps

(* Primitives *)

let primE prim es =
  let ty = match prim with
    | ShowPrim _ -> T.text
    | ICReplyPrim _ -> T.Non
    | ICRejectPrim -> T.Non
    | ICErrorCodePrim -> T.Prim T.Int32
    | _ -> assert false (* implement more as needed *)
  in
  let effs = List.map eff es in
  let e = List.fold_left max_eff T.Triv effs in
  { it = PrimE (prim, es);
    at = no_region;
    note = { note_typ = ty; note_eff = e }
  }

let asyncE typ e =
  { it = PrimE (CPSAsync, [e]);
    at = no_region;
    note = { note_typ = T.Async typ; note_eff = eff e }
  }

let assertE e =
  { it = AssertE e;
    at = no_region;
    note = { note_typ = T.unit; note_eff = eff e}
  }

let awaitE typ e1 e2 =
  { it = PrimE (CPSAwait, [e1; e2]);
    at = no_region;
    note = { note_typ = T.unit; note_eff = max_eff (eff e1) (eff e2) }
  }

let ic_replyE ts e =
  (match ts with
  | [t] -> assert (T.sub (e.note.note_typ) t)
  | _ -> assert (T.sub (T.Tup ts) (e.note.note_typ)));
  { it = PrimE (ICReplyPrim ts, [e]);
    at = no_region;
    note = { note_typ = T.unit; note_eff = eff e }
  }

let ic_rejectE e =
  { it = PrimE (ICRejectPrim, [e]);
    at = no_region;
    note = { note_typ = T.unit; note_eff = eff e }
  }

let ic_error_codeE () =
  { it = PrimE (ICErrorCodePrim, []);
    at = no_region;
    note = { note_typ = T.Prim T.Int32; note_eff = T.Triv }
  }

let ic_callE f e k r =
  let es = [f; e; k; r] in
  let effs = List.map eff es in
  let eff = List.fold_left max_eff T.Triv effs in
  { it = PrimE (ICCallPrim, es);
    at = no_region;
    note = { note_typ = T.unit; note_eff = eff }
  }


(* tuples *)

let projE e n =
  match typ e with
  | T.Tup ts ->
     { it = ProjE (e, n);
       note = { note_typ = List.nth ts n; note_eff = eff e };
       at = no_region;
     }
  | _ -> failwith "projE"

let dec_eff dec = match dec.it with
  | TypD _ -> T.Triv
  | LetD (_,e) | VarD (_,e) -> eff e

let is_useful_dec dec = match dec.it with
  | LetD ({it = WildP;_}, {it = TupE [];_}) -> false
  | LetD ({it = TupP [];_}, {it = TupE [];_}) -> false
  | _ -> true

let blockE decs exp =
  let decs' = List.filter is_useful_dec decs in
  match decs' with
  | [] -> exp
  | _ ->
    let es = List.map dec_eff decs' in
    let typ = typ exp in
    let e =  List.fold_left max_eff (eff exp) es in
    { it = BlockE (decs', exp);
      at = no_region;
      note = {note_typ = typ; note_eff = e }
    }

let textE s =
  { it = LitE (TextLit s);
    at = no_region;
    note = { note_typ = T.Prim T.Text; note_eff = T.Triv }
  }

let unitE =
  { it = TupE [];
    at = no_region;
    note = { note_typ = T.Tup []; note_eff = T.Triv }
  }

let boolE b =
  { it = LitE (BoolLit b);
    at = no_region;
    note = { note_typ = T.bool; note_eff = T.Triv}
  }

let callE exp1 ts exp2 =
  match T.promote (typ exp1) with
  | T.Func (_sort, _control, _, _, ret_tys) ->
    { it = CallE (exp1, ts, exp2);
      at = no_region;
      note = {
        note_typ = T.open_ ts (T.seq ret_tys);
        note_eff = max_eff (eff exp1) (eff exp2)
      }
    }
  | T.Non -> exp1
  | _ -> raise (Invalid_argument "callE expect a function")

let ifE exp1 exp2 exp3 typ =
  { it = IfE (exp1, exp2, exp3);
    at = no_region;
    note = {
      note_typ = typ;
      note_eff = max_eff (eff exp1) (max_eff (eff exp2) (eff exp3))
    }
  }

let dotE exp name typ =
  { it = DotE (exp, name);
    at = no_region;
    note = {
      note_typ = typ;
      note_eff = eff exp
    }
  }

let switch_optE exp1 exp2 pat exp3 typ1  =
  { it =
      SwitchE
        (exp1,
         [{ it = {pat = {it = LitP NullLit;
                         at = no_region;
                         note = typ exp1};
                  exp = exp2};
            at = no_region;
           note = () };
          { it = {pat = {it = OptP pat;
                        at = no_region;
                        note = typ exp1};
                  exp = exp3};
            at = no_region;
            note = () }]
        );
    at = no_region;
    note = {
      note_typ = typ1;
      note_eff = max_eff (eff exp1) (max_eff (eff exp2) (eff exp3))
    }
  }

let switch_variantE exp1 cases typ1 =
  { it =
      SwitchE (exp1,
        List.map (fun (l,p,e) ->
          { it = {pat = {it = TagP (l, p);
                         at = no_region;
                         note = typ exp1};
                  exp = e};
            at = no_region;
            note = ()
          })
          cases
      );
    at = no_region;
    note = {
      note_typ = typ1;
      note_eff = List.fold_left max_eff (eff exp1) (List.map (fun (l,p,e) -> eff e) cases)
    }
  }

let tupE exps =
  let effs = List.map eff exps in
  let eff = List.fold_left max_eff T.Triv effs in
  { it = TupE exps;
    at = no_region;
    note = {
      note_typ = T.Tup (List.map typ exps);
      note_eff = eff
    }
  }

let breakE l exp =
  { it = BreakE (l, exp);
    at = no_region;
    note = {
      note_eff = eff exp;
      note_typ = T.Non
    }
  }

let retE exp =
  { it = RetE exp;
    at = no_region;
    note = { note_eff = eff exp;
             note_typ = T.Non }
  }

let immuteE e =
  { e with
    note = { note_eff = eff e;
             note_typ = T.as_immut (typ e) }
  }


let assignE exp1 exp2 =
  assert (T.is_mut (typ exp1));
  { it = AssignE (exp1, exp2);
    at = no_region;
    note = { note_eff = Ir_effect.max_eff (eff exp1) (eff exp2);
             note_typ = T.unit }
  }

let labelE l typ exp =
  { it = LabelE (l, typ, exp);
    at = no_region;
    note = { note_eff = eff exp;
             note_typ = typ }
  }

(* Used to desugar for loops, while loops and loop-while loops. *)
let loopE exp =
  { it = LoopE exp;
    at = no_region;
    note = { note_eff = eff exp ;
             note_typ = T.Non }
  }

let declare_idE x typ exp1 =
  { it = DeclareE (x, typ, exp1);
    at = no_region;
    note = exp1.note;
  }

let define_idE x mut exp1 =
  { it = DefineE (x, mut, exp1);
    at = no_region;
    note = { note_typ = T.unit;
             note_eff = T.Triv}
  }

let newObjE sort ids typ =
  { it = NewObjE (sort, ids, typ);
    at = no_region;
    note = { note_typ = typ;
             note_eff = T.Triv }
  }


(* Declarations *)

let letP pat exp = LetD (pat, exp) @@ no_region

let letD x exp = letP (varP x) exp

let varD x exp =
  VarD (x, exp) @@ no_region

let expD exp =
  let pat = { it = WildP; at = exp.at; note = exp.note.note_typ } in
  LetD (pat, exp) @@ exp.at

(* Derived expressions *)

let letE x exp1 exp2 = blockE [letD x exp1] exp2

let thenE exp1 exp2 = blockE [expD exp1] exp2

let ignoreE exp =
  if typ exp = T.unit
  then exp
  else thenE exp (tupE [])


(* Mono-morphic function expression *)
let funcE name t x exp =
  let sort, control, arg_tys, ret_tys = match t with
    | T.Func(s, c, _, ts1, ts2) -> s, c, ts1, ts2
    | _ -> assert false in
  let args, exp' =
    if List.length arg_tys = 1;
    then
      [ arg_of_exp x ], exp
    else
      let vs = fresh_vars "param" arg_tys in
      List.map arg_of_exp vs,
      blockE [letD x (tupE vs)] exp
  in
  ({it = FuncE
     ( name,
       sort,
       control,
       [],
       args,
       (* TODO: Assert invariant: retty has no free (unbound) DeBruijn indices -- Claudio *)
       ret_tys,
       exp'
     );
    at = no_region;
    note = { note_eff = T.Triv; note_typ = t }
   })

let nary_funcE name t xs exp =
  let sort, control, arg_tys, ret_tys = match t with
    | T.Func(s, c, _, ts1, ts2) -> s, c, ts1, ts2
    | _ -> assert false in
  assert (List.length arg_tys = List.length xs);
  ({it = FuncE
      ( name,
        sort,
        control,
        [],
        List.map arg_of_exp xs,
        ret_tys,
        exp
      );
    at = no_region;
    note = { note_eff = T.Triv; note_typ = t }
  })

(* Mono-morphic function declaration, sharing inferred from f's type *)
let funcD f x exp =
  match f.it, x.it with
  | VarE _, VarE _ ->
    letD f (funcE (id_of_exp f) (typ f) x exp)
  | _ -> failwith "Impossible: funcD"

(* Mono-morphic, n-ary function declaration *)
let nary_funcD f xs exp =
  match f.it with
  | VarE _ ->
    letD f (nary_funcE (id_of_exp f) (typ f) xs exp)
  | _ -> failwith "Impossible: funcD"


(* Continuation types *)

let answerT = T.unit

let contT typ = T.Func (T.Local, T.Returns, [], T.as_seq typ, [])

let err_contT =  T.Func (T.Local, T.Returns, [], [T.catch], [])

let cpsT typ = T.Func (T.Local, T.Returns, [], [contT typ; err_contT], [])

let fresh_cont typ = fresh_var "k" (contT typ)

let fresh_err_cont ()  = fresh_var "r" (err_contT)

(* Sequence expressions *)

let seqE es =
  match es with
  | [e] -> e
  | es -> tupE es

(* Lambdas & continuations *)

(* Lambda abstraction *)

(* local lambda *)
let (-->) x exp =
  let fun_ty = T.Func (T.Local, T.Returns, [], T.as_seq (typ x), T.as_seq (typ exp)) in
  funcE "$lambda" fun_ty x exp

(* n-ary local lambda *)
let (-->*) xs exp =
  let fun_ty = T.Func (T.Local, T.Returns, [], List.map typ xs, T.as_seq (typ exp)) in
  nary_funcE "$lambda" fun_ty xs exp

(* Lambda application (monomorphic) *)

let ( -*- ) exp1 exp2 =
  match typ exp1 with
  | T.Func (_, _, [], _, ret_tys) ->
    { it = CallE (exp1, [], exp2);
      at = no_region;
      note = {note_typ = T.seq ret_tys;
              note_eff = max_eff (eff exp1) (eff exp2)}
    }
  | typ1 -> failwith
           (Printf.sprintf "Impossible: \n func: %s \n : %s arg: \n %s"
              (Wasm.Sexpr.to_string 80 (Arrange_ir.exp exp1))
              (T.string_of_typ typ1)
              (Wasm.Sexpr.to_string 80 (Arrange_ir.exp exp2)))


(* derived loop forms; each can be expressed as an unconditional loop *)

let whileE exp1 exp2 =
  (* while e1 e2
     ~~> label l loop {
           if e1 then { e2 } else { break l }
         }
  *)
  let lab = fresh_id "done" () in
  labelE lab T.unit (
      loopE (
          ifE exp1
            exp2
            (breakE lab (tupE []))
            T.unit
        )
    )

let loopWhileE exp1 exp2 =
  (* loop e1 while e2
    ~~> label l loop {
          let () = e1 ;
          if e2 { } else { break l }
        }
   *)
  let lab = fresh_id "done" () in
  labelE lab T.unit (
      loopE (
          thenE exp1
            ( ifE exp2
               (tupE [])
               (breakE lab (tupE []))
               T.unit
            )
        )
    )

let forE pat exp1 exp2 =
  (* for p in e1 e2
     ~~>
     let nxt = e1.next ;
     label l loop {
       switch nxt () {
         case null { break l };
         case p    { e2 };
       }
     } *)
  let lab = fresh_id "done" () in
  let ty1 = exp1.note.note_typ in
  let _, tfs = T.as_obj_sub ["next"] ty1 in
  let tnxt = T.lookup_val_field "next" tfs in
  let nxt = fresh_var "nxt" tnxt in
  letE nxt (dotE exp1 (nameN "next") tnxt) (
    labelE lab T.unit (
      loopE (
        switch_optE (callE nxt [] (tupE []))
          (breakE lab (tupE []))
          pat exp2 T.unit
      )
    )
  )

let unreachableE =
  (* Do we want UnreachableE in the AST *)
  loopE unitE

