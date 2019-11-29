open Ir_def
open Mo_types
open Mo_values
(* Translates away calls to `show`. *)
open Source
open Ir
module T = Type
open Construct

(* A type identifier *)

(* This needs to map types to some identifier with the following properties:

 - Its domain are normalized types that do not mention any type parameters
 - It needs to be injective wrt. type equality
 - It needs to terminate, even for recursive types
 - It may fail upon type parameters (i.e. no polymorphism)

We can use string_of_typ here for now, it seems.
*)

let typ_id : T.typ -> string =
  T.string_of_typ

(* Environment *)

(* We go through the file and collect all type arguments to `show`.
   We store them in `params`, indexed by their `type_id`
*)

module M = Map.Make(String)
type env =
  { params : T.typ M.t ref
  }

let empty_env : env = {
  params = ref M.empty;
  }

let add_type env t : unit =
  env.params := M.add (typ_id t) t !(env.params)

(* Function names *)

(* For a concrete type `t` we want to create a function name for `show`.
   This name needs to be disjoint from all user-generated names.
   Luckily, we are not limited in the characters to use at this point.
*)

let show_name_for t =
  "@show<" ^ typ_id t ^ ">"

let show_fun_typ_for t =
  T.Func (T.Local, T.Returns, [], [t], [T.Prim T.Text])

let show_var_for t : Construct.var =
  idE (show_name_for t) (show_fun_typ_for t)

(* The AST traversal *)

let rec t_exps env decs = List.map (t_exp env) decs

and t_exp env (e : Ir.exp) =
  { e with it = t_exp' env e.it }

and t_exp' env = function
  | LitE l -> LitE l
  | VarE id -> VarE id
  | PrimE (ShowPrim ot, [exp1]) ->
    let t' = T.normalize ot in
    add_type env t';
    let f = idE (show_name_for t') (show_fun_typ_for t') in
    CallE (f, [], t_exp env exp1)
  | PrimE (p, es) -> PrimE (p, t_exps env es)
  | TupE exps -> TupE (t_exps env exps)
  | OptE exp1 ->
    OptE (t_exp env exp1)
  | TagE (l, exp1) ->
    TagE (l, t_exp env exp1)
  | ProjE (exp1, n) ->
    ProjE (t_exp env exp1, n)
  | ActorE (id, ds, fields, typ) ->
    ActorE (id, t_decs env ds, fields, typ)
  | DotE (exp1, id) ->
    DotE (t_exp env exp1, id)
  | ActorDotE (exp1, id) ->
    ActorDotE (t_exp env exp1, id)
  | AssignE (exp1, exp2) ->
    AssignE (t_exp env exp1, t_exp env exp2)
  | ArrayE (mut, t, exps) ->
    ArrayE (mut, t, t_exps env exps)
  | IdxE (exp1, exp2) ->
    IdxE (t_exp env exp1, t_exp env exp2)
  | FuncE (s, c, id, typbinds, pat, typT, exp) ->
    FuncE (s, c, id, typbinds, pat, typT, t_exp env exp)
  | CallE (exp1, typs, exp2)  ->
    CallE(t_exp env exp1, typs, t_exp env exp2)
  | BlockE block -> BlockE (t_block env block)
  | IfE (exp1, exp2, exp3) ->
    IfE (t_exp env exp1, t_exp env exp2, t_exp env exp3)
  | SwitchE (exp1, cases) ->
    let cases' =
      List.map
        (fun {it = {pat;exp}; at; note} ->
          {it = {pat = pat; exp = t_exp env exp}; at; note})
        cases
    in
    SwitchE (t_exp env exp1, cases')
  | TryE (exp1, cases) ->
    let cases' =
      List.map
        (fun {it = {pat;exp}; at; note} ->
          {it = {pat = pat; exp = t_exp env exp}; at; note})
        cases
    in
    TryE (t_exp env exp1, cases')
  | LoopE exp1 ->
    LoopE (t_exp env exp1)
  | LabelE (id, typ, exp1) ->
    LabelE (id, typ, t_exp env exp1)
  | BreakE (id, exp1) ->
    BreakE (id, t_exp env exp1)
  | RetE exp1 ->
    RetE (t_exp env exp1)
  | ThrowE exp1 ->
    ThrowE (t_exp env exp1)
  | AsyncE e -> AsyncE (t_exp env e)
  | AwaitE e -> AwaitE (t_exp env e)
  | AssertE exp1 ->
    AssertE (t_exp env exp1)
  | DeclareE (id, typ, exp1) ->
    DeclareE (id, typ, t_exp env exp1)
  | DefineE (id, mut ,exp1) ->
    DefineE (id, mut, t_exp env exp1)
  | NewObjE (sort, ids, t) ->
    NewObjE (sort, ids, t)
  | SelfCallE (ts, e1, e2, e3) ->
    SelfCallE (ts, t_exp env e1, t_exp env e2, t_exp env e3)

and t_dec env dec = { dec with it = t_dec' env dec.it }

and t_dec' env dec' =
  match dec' with
  | TypD con_id -> TypD con_id
  | LetD (pat,exp) -> LetD (pat,t_exp env exp)
  | VarD (id,exp) -> VarD (id,t_exp env exp)

and t_decs env decs = List.map (t_dec env) decs

and t_block env (ds, exp) = (t_decs env ds, t_exp env exp)

and t_prog env (prog, flavor) = (t_block env prog, flavor)


(* Construction helpers *)

(* Many of these are simply the entry points for helper functions defined in
   the prelude. *)

let argE t = idE "x" t

let define_show : T.typ -> Ir.exp -> Ir.dec = fun t e ->
  Construct.funcD (show_var_for t) (argE t) e

let text_exp : Ir.exp' -> Ir.exp = fun e ->
  { it = e;
    at = no_region;
    note = { note_typ = T.Prim T.Text; note_eff = T.Triv }
  }

let invoke_generated_show : T.typ -> Ir.exp -> Ir.exp = fun t e ->
  text_exp (CallE (show_var_for t, [], e))

let invoke_prelude_show : string -> T.typ -> Ir.exp -> Ir.exp = fun n t e ->
  let fun_typ = T.Func (T.Local, T.Returns, [], [t], [T.Prim T.Text]) in
  text_exp (CallE
    ( { it = VarE n
      ; at = no_region
      ; note = { note_typ = fun_typ; note_eff = T.Triv }
      }
    , []
    , argE t
    )
  )

let invoke_text_of_option : T.typ -> Ir.exp -> Ir.exp -> Ir.exp = fun t f e ->
  let fun_typ =
    T.Func (T.Local, T.Returns, [{T.var="T";T.bound=T.Any}], [show_fun_typ_for (T.Var ("T",0)); T.Opt (T.Var ("T",0))], [T.Prim T.Text]) in
  text_exp (CallE
    ( { it = VarE "@text_of_option"
      ; at = no_region
      ; note = { note_typ = fun_typ; note_eff = T.Triv }
      }
    , [t]
    , { it = TupE [f; e]
      ; at = no_region
      ; note = { note_typ = T.Tup [show_fun_typ_for t; T.Opt t]; note_eff = T.Triv }
      }
    )
  )

let invoke_text_of_variant : T.typ -> Ir.exp -> T.lab -> Ir.exp -> Ir.exp = fun t f l e ->
  let fun_typ =
    T.Func (T.Local, T.Returns, [{T.var="T";T.bound=T.Any}], [T.Prim T.Text; show_fun_typ_for (T.Var ("T",0)); T.Var ("T",0)], [T.Prim T.Text]) in
  text_exp (CallE
    ( { it = VarE "@text_of_variant"
      ; at = no_region
      ; note = { note_typ = fun_typ; note_eff = T.Triv }
      }
    , [t]
    , { it = TupE [textE l; f; e]
      ; at = no_region
      ; note = { note_typ = T.Tup [T.Prim T.Text; show_fun_typ_for t; t]; note_eff = T.Triv }
      }
    )
  )

let invoke_text_of_array : T.typ -> Ir.exp -> Ir.exp -> Ir.exp = fun t f e ->
  let fun_typ =
    T.Func (T.Local, T.Returns, [{T.var="T";T.bound=T.Any}], [show_fun_typ_for (T.Var ("T",0)); T.Array (T.Var ("T",0))], [T.Prim T.Text]) in
  text_exp (CallE
    ( { it = VarE "@text_of_array"
      ; at = no_region
      ; note = { note_typ = fun_typ; note_eff = T.Triv }
      }
    , [t]
    , { it = TupE [f; e]
      ; at = no_region
      ; note = { note_typ = T.Tup [show_fun_typ_for t; T.Array t]; note_eff = T.Triv }
      }
    )
  )

let invoke_text_of_array_mut : T.typ -> Ir.exp -> Ir.exp -> Ir.exp = fun t f e ->
  let fun_typ =
    T.Func (T.Local, T.Returns, [{T.var="T";T.bound=T.Any}], [show_fun_typ_for (T.Var ("T",0)); T.Array (T.Mut (T.Var ("T",0)))], [T.Prim T.Text]) in
  text_exp (CallE
    ( { it = VarE "@text_of_array_mut"
      ; at = no_region
      ; note = { note_typ = fun_typ; note_eff = T.Triv }
      }
    , [t]
    , { it = TupE [f; e]
      ; at = no_region
      ; note = { note_typ = T.Tup [show_fun_typ_for t; T.Array (T.Mut t)]; note_eff = T.Triv }
      }
    )
  )

let list_build : 'a -> 'a -> 'a -> 'a list -> 'a list = fun pre sep post xs ->
  let rec go = function
    | [] -> [ post ]
    | [x] -> [ x; post ]
    | x::xs -> [ x; sep ] @ go xs
  in [ pre ] @ go xs

let catE : Ir.exp -> Ir.exp -> Ir.exp = fun e1 e2 ->
  { it = PrimE (BinPrim (T.text, Operator.CatOp), [e1; e2])
  ; at = no_region
  ; note = { note_typ = T.Prim T.Text; note_eff = T.Triv }
  }

let cat_list : Ir.exp list -> Ir.exp = fun es ->
  List.fold_right catE es (textE "")

(* Synthesizing a single show function *)

(* Returns the new declarations, as well as a list of further types it needs *)


let show_for : T.typ -> Ir.dec * T.typ list = fun t ->
  match t with
  | T.Prim T.Bool ->
    define_show t (invoke_prelude_show "@text_of_Bool" t (argE t)),
    []
  | T.Prim T.Nat ->
    define_show t (invoke_prelude_show "@text_of_Nat" t (argE t)),
    []
  | T.Prim T.Int ->
    define_show t (invoke_prelude_show "@text_of_Int" t (argE t)),
    []
  | T.(Prim Nat8) ->
    define_show t (invoke_prelude_show "@text_of_Nat8" t (argE t)),
    []
  | T.(Prim Nat16) ->
    define_show t (invoke_prelude_show "@text_of_Nat16" t (argE t)),
    []
  | T.(Prim Nat32) ->
    define_show t (invoke_prelude_show "@text_of_Nat32" t (argE t)),
    []
  | T.(Prim Nat64) ->
    define_show t (invoke_prelude_show "@text_of_Nat64" t (argE t)),
    []
  | T.(Prim Int8) ->
    define_show t (invoke_prelude_show "@text_of_Int8" t (argE t)),
    []
  | T.(Prim Int16) ->
    define_show t (invoke_prelude_show "@text_of_Int16" t (argE t)),
    []
  | T.(Prim Int32) ->
    define_show t (invoke_prelude_show "@text_of_Int32" t (argE t)),
    []
  | T.(Prim Int64) ->
    define_show t (invoke_prelude_show "@text_of_Int64" t (argE t)),
    []
  | T.(Prim Word8) ->
    define_show t (invoke_prelude_show "@text_of_Word8" t (argE t)),
    []
  | T.(Prim Word16) ->
    define_show t (invoke_prelude_show "@text_of_Word16" t (argE t)),
    []
  | T.(Prim Word32) ->
    define_show t (invoke_prelude_show "@text_of_Word32" t (argE t)),
    []
  | T.(Prim Word64) ->
    define_show t (invoke_prelude_show "@text_of_Word64" t (argE t)),
    []
  | T.Prim T.Text ->
    define_show t (invoke_prelude_show "@text_of_Text" t (argE t)),
    []
  | T.Prim T.Null ->
    define_show t (textE ("null")),
    []
  | T.Func _ ->
    define_show t (textE ("func")),
    []
  | T.Con (c,_) ->
    (* t is normalized, so this is a type parameter *)
    define_show t (textE ("show_for: cannot handle type parameter " ^ T.string_of_typ t)),
    []
  | T.Tup [] ->
    define_show t (textE ("()")),
    []
  | T.Tup ts' ->
    let ts' = List.map T.normalize ts' in
    define_show t (
      cat_list (list_build
        (textE "(") (textE ", ") (textE ")")
        (List.mapi (fun i t' ->
           invoke_generated_show t' (
             { it = ProjE (argE t, i)
             ; at = no_region
             ; note = { note_typ = t'; note_eff = T.Triv }
             }
           )
        ) ts')
      )
    ),
    ts'
  | T.Opt t' ->
    let t' = T.normalize t' in
    define_show t (invoke_text_of_option t' (show_var_for t') (argE t)),
    [t']
  | T.Array t' ->
    let t' = T.normalize t' in
    begin match t' with
    | T.Mut t' ->
      define_show t (invoke_text_of_array_mut t' (show_var_for t') (argE t)),
      [t']
    | _ ->
      define_show t (invoke_text_of_array t' (show_var_for t') (argE t)),
      [t']
    end
  | T.Obj (T.Object, fs) ->
    define_show t (
      cat_list (list_build
        (textE "{") (textE "; ") (textE "}")
        (List.map (fun f ->
          let t' = T.as_immut (T.normalize f.Type.typ) in
          catE
            (textE (f.Type.lab ^ " = "))
            (invoke_generated_show t'
              { it = DotE (argE t, f.Type.lab)
              ; at = no_region
              ; note = { note_typ = t'; note_eff = T.Triv }
              }
            )
          ) fs
        )
      )
    ),
    List.map (fun f -> T.as_immut (T.normalize (f.Type.typ))) fs
  | T.Variant fs ->
    define_show t (
      switch_variantE
        (argE t)
        (List.map (fun {T.lab = l; typ = t'} ->
          let t' = T.normalize t' in
          l,
          (varP (argE t')), (* Shadowing, but that's fine *)
          (invoke_text_of_variant t' (show_var_for t') l (argE t'))
        ) fs)
        (T.Prim T.Text)
    ),
    List.map (fun (f : T.field) -> T.normalize f.T.typ) fs
  | T.Non ->
    define_show t unreachableE,
    []
  | _ -> assert false (* Should be prevented by can_show *)

(* Synthesizing the types recursively. Hopefully well-founded. *)

let show_decls : T.typ M.t -> Ir.dec list = fun roots ->
  let seen = ref M.empty in

  let rec go = function
    | [] -> []
    | t::todo when M.mem (typ_id t) !seen ->
      go todo
    | t::todo ->
      seen := M.add (typ_id t) () !seen;
      let (decl, deps) = show_for t in
      decl :: go (deps @ todo)
  in go (List.map snd (M.bindings roots))

(* Entry point for the program transformation *)

let transform scope prog =
  let env = empty_env in
  (* Find all parameters to show in the program *)
  let prog = t_prog env prog in
  (* Create declarations for them *)
  let decls = show_decls !(env.params) in
  (* Add them to the program *)
  let prog' = let ((d,e),f) = prog in ((decls @ d,e), { f with has_show = false }) in
  prog';
