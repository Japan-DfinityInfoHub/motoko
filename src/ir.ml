(* Patterns *)

type 'a phrase = ('a, Syntax.typ_note) Source.annotated_phrase

type typ_bind = (Type.bind, Type.typ) Source.annotated_phrase

type pat = (pat', Type.typ) Source.annotated_phrase
and pat' =
  | WildP                                      (* wildcard *)
  | VarP of Syntax.id                          (* variable *)
  | LitP of Syntax.lit                         (* literal *)
  | TupP of pat list                           (* tuple *)
  | OptP of pat                                (* option *)
  | AltP of pat * pat                          (* disjunctive *)

(* Expressions *)

type exp = exp' phrase
and exp' =
  | PrimE of string                            (* primitive *)
  | VarE of Syntax.id                          (* variable *)
  | LitE of Syntax.lit                         (* literal *)
  | UnE of Type.typ * Syntax.unop * exp        (* unary operator *)
  | BinE of                                    (* binary operator *)
      Type.typ * exp * Syntax.binop * exp
  | RelE of                                    (* relational operator *)
      Type.typ * exp * Syntax.relop * exp
  | TupE of exp list                           (* tuple *)
  | ProjE of exp * int                         (* tuple projection *)
  | OptE of exp                                (* option injection *)
  | ActorE of                                  (* actor *)
      Syntax.id * exp_field list * Type.typ
  | DotE of exp * Syntax.name                  (* object projection *)
  | ActorDotE of exp * Syntax.name             (* actor field access *)
  | AssignE of exp * exp                       (* assignment *)
  | ArrayE of Syntax.mut * Type.typ * exp list  (* array *)
  | IdxE of exp * exp                          (* array indexing *)
  | CallE of                                   (* function call *)
      Value. call_conv * exp * Type.typ list * exp
  | BlockE of dec list * Type.typ              (* block *)
  | IfE of exp * exp * exp                     (* conditional *)
  | SwitchE of exp * case list                 (* switch *)
  | WhileE of exp * exp                        (* while-do loop *)
  | LoopE of exp * exp option                  (* do-while loop *)
  | ForE of pat * exp * exp                    (* iteration *)
  | LabelE of Syntax.id * Type.typ * exp       (* label *)
  | BreakE of Syntax.id * exp                  (* break *)
  | RetE of exp                                (* return *)
  | AsyncE of exp                              (* async *)
  | AwaitE of exp                              (* await *)
  | AssertE of exp                             (* assertion *)
  | DeclareE of Syntax.id * Type.typ * exp     (* local promise *)
  | DefineE of Syntax.id * Syntax.mut * exp    (* promise fulfillment *)
  | NewObjE of                                 (* make an object, preserving mutable identity *)
      Syntax.obj_sort * (Syntax.name * Syntax.id) list * Type.typ

and exp_field = exp_field' Source.phrase
and exp_field' = {name : Syntax.name; id : Syntax.id; exp : exp; mut : Syntax.mut; priv : Syntax.priv}

and case = case' Source.phrase
and case' = {pat : pat; exp : exp}


(* Declarations *)

and dec = dec' phrase
and dec' =
  | ExpD of exp                                (* plain expression *)
  | LetD of pat * exp                          (* immutable *)
  | VarD of Syntax.id * exp                    (* mutable *)
  | FuncD of                                   (* function *)
      Value.call_conv * Syntax.id * typ_bind list * pat * Type.typ * exp
  | TypD of Type.con * Type.kind               (* type *)


(* Program *)

type prog = prog' Source.phrase
and prog' = dec list
