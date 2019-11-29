(*
This module is the backend of the Motoko compiler. It takes a program in
the intermediate representation (ir.ml), and produces a WebAssembly module,
with DFINITY extensions (customModule.ml). An important helper module is
instrList.ml, which provides a more convenient way of assembling WebAssembly
instruction lists, as it takes care of (1) source locations and (2) labels.

This file is split up in a number of modules, purely for namespacing and
grouping. Every module has a high-level prose comment explaining the concept;
this keeps documentation close to the code (a lesson learned from Simon PJ).
*)

open Ir_def
open Mo_values
open Mo_types
open Mo_config

open Wasm.Ast
open Wasm.Types
open Source
(* Re-shadow Source.(@@), to get Pervasives.(@@) *)
let (@@) = Pervasives.(@@)

module G = InstrList
let (^^) = G.(^^) (* is this how we import a single operator from a module that we otherwise use qualified? *)

(* WebAssembly pages are 64kb. *)
let page_size = Int32.of_int (64*1024)

(*
Pointers are skewed (translated) -1 relative to the actual offset.
See documentation of module BitTagged for more detail.
*)
let ptr_skew = -1l
let ptr_unskew = 1l

(* Helper functions to produce annotated terms (Wasm.AST) *)
let nr x = { Wasm.Source.it = x; Wasm.Source.at = Wasm.Source.no_region }

let todo fn se x = Printf.eprintf "%s: %s" fn (Wasm.Sexpr.to_string 80 se); x

module SR = struct
  (* This goes with the StackRep module, but we need the types earlier *)

  (* Statically known values: They are not put on the stack, but the
     “stack representation“ carries the static information.
  *)
  type static_thing =
    | StaticFun of int32
    | StaticMessage of int32 (* anonymous message, only temporary *)
    | PublicMethod of int32 * string

  (* Value representation on the stack:

     Compiling an expression means putting its value on the stack. But
     there are various ways of putting a value onto the stack -- unboxed,
     tupled etc.
   *)
  type t =
    | Vanilla
    | UnboxedTuple of int
    | UnboxedWord64
    | UnboxedWord32
    | Unreachable
    | StaticThing of static_thing

  let unit = UnboxedTuple 0

  let bool = Vanilla

end (* SR *)

(*

** The compiler environment.

Of course, as we go through the code we have to track a few things; these are
put in the compiler environment, type `E.t`. Some fields are valid globally, some
only make sense locally, i.e. within a single function (but we still put them
in one big record, for convenience).

The fields fall into the following categories:

 1. Static global fields. Never change.
    Example: whether we are compiling with -no-system-api; the prelude code

 2. Immutable global fields. Change in a well-scoped manner.
    Example: Mapping from Motoko names to their location.

 3. Mutable global fields. Change only monotonously.
    These are used to register things like functions. This should be monotone
    in the sense that entries are only added, and that the order should not
    matter in a significant way. In some instances, the list contains futures
    so that we can reserve and know the _position_ of the thing before we have
    to actually fill it in.

 4. Static local fields. Never change within a function.
    Example: number of parameters and return values

 5. Immutable local fields. Change in a well-scoped manner.
    Example: Jump label depth

 6. Mutable local fields. See above
    Example: Name and type of locals.

**)

(* Before we can define the environment, we need some auxillary types *)

module E = struct

  (* Utilities, internal to E *)
  let reg (ref : 'a list ref) (x : 'a) : int32 =
      let i = Wasm.I32.of_int_u (List.length !ref) in
      ref := !ref @ [ x ];
      i

  let reserve_promise (ref : 'a Lib.Promise.t list ref) _s : (int32 * ('a -> unit)) =
      let p = Lib.Promise.make () in (* For debugging with named promises, use s here *)
      let i = Wasm.I32.of_int_u (List.length !ref) in
      ref := !ref @ [ p ];
      (i, Lib.Promise.fulfill p)


  (* The environment type *)
  module NameEnv = Env.Make(String)
  module StringEnv = Env.Make(String)
  type local_names = (int32 * string) list (* For the debug section: Names of locals *)
  type func_with_names = func * local_names
  type lazy_built_in =
    | Declared of (int32 * (func_with_names -> unit))
    | Defined of int32
    | Pending of (unit -> func_with_names)
  type t = {
    (* Global fields *)
    (* Static *)
    mode : Flags.compile_mode;
    prelude : Ir.prog; (* The prelude. Re-used when compiling actors *)
    rts : Wasm_exts.CustomModule.extended_module option; (* The rts. Re-used when compiling actors *)
    trap_with : t -> string -> G.t;
      (* Trap with message; in the env for dependency injection *)

    (* Immutable *)

    (* Mutable *)
    func_types : func_type list ref;
    func_imports : import list ref;
    other_imports : import list ref;
    exports : export list ref;
    funcs : (func * string * local_names) Lib.Promise.t list ref;
    globals : (global * string) list ref;
    global_names : int32 NameEnv.t ref;
    built_in_funcs : lazy_built_in NameEnv.t ref;
    static_strings : int32 StringEnv.t ref;
    end_of_static_memory : int32 ref; (* End of statically allocated memory *)
    static_memory : (int32 * string) list ref; (* Content of static memory *)
    static_memory_frozen : bool ref;
      (* Sanity check: Nothing should bump end_of_static_memory once it has been read *)

    (* Local fields (only valid/used inside a function) *)
    (* Static *)
    n_param : int32; (* Number of parameters (to calculate indices of locals) *)
    return_arity : int; (* Number of return values (for type of Return) *)

    (* Immutable *)

    (* Mutable *)
    locals : value_type list ref; (* Types of locals *)
    local_names : (int32 * string) list ref; (* Names of locals *)
  }


  (* The initial global environment *)
  let mk_global mode rts prelude trap_with dyn_mem : t = {
    mode;
    rts;
    prelude;
    trap_with;
    func_types = ref [];
    func_imports = ref [];
    other_imports = ref [];
    exports = ref [];
    funcs = ref [];
    globals = ref [];
    global_names = ref NameEnv.empty;
    built_in_funcs = ref NameEnv.empty;
    static_strings = ref StringEnv.empty;
    end_of_static_memory = ref dyn_mem;
    static_memory = ref [];
    static_memory_frozen = ref false;
    (* Actually unused outside mk_fun_env: *)
    n_param = 0l;
    return_arity = 0;
    locals = ref [];
    local_names = ref [];
  }


  let mk_fun_env env n_param return_arity =
    { env with
      n_param;
      return_arity;
      locals = ref [];
      local_names = ref [];
    }

  (* We avoid accessing the fields of t directly from outside of E, so here are a
     bunch of accessors. *)

  let mode (env : t) = env.mode


  let add_anon_local (env : t) ty =
      let i = reg env.locals ty in
      Wasm.I32.add env.n_param i

  let add_local_name (env : t) li name =
      let _ = reg env.local_names (li, name) in ()

  let get_locals (env : t) = !(env.locals)
  let get_local_names (env : t) : (int32 * string) list = !(env.local_names)

  let _add_other_import (env : t) m =
    ignore (reg env.other_imports m)

  let add_export (env : t) e =
    ignore (reg env.exports e)

  let add_global (env : t) name g =
    assert (not (NameEnv.mem name !(env.global_names)));
    let gi = reg env.globals (g, name) in
    env.global_names := NameEnv.add name gi !(env.global_names)

  let add_global32 (env : t) name mut init =
    add_global env name (
      nr { gtype = GlobalType (I32Type, mut);
        value = nr (G.to_instr_list (G.i (Wasm.Ast.Const (nr (Wasm.Values.I32 init)))))
      })

  let add_global64 (env : t) name mut init =
    add_global env name (
      nr { gtype = GlobalType (I64Type, mut);
        value = nr (G.to_instr_list (G.i (Wasm.Ast.Const (nr (Wasm.Values.I64 init)))))
      })

  let get_global (env : t) name : int32 =
    match NameEnv.find_opt name !(env.global_names) with
    | Some gi -> gi
    | None -> raise (Invalid_argument (Printf.sprintf "No global named %s declared" name))

  let get_global32_lazy (env : t) name mut init : int32 =
    match NameEnv.find_opt name !(env.global_names) with
    | Some gi -> gi
    | None -> add_global32 env name mut init; get_global env name

  let export_global env name =
    add_export env (nr {
      name = Wasm.Utf8.decode name;
      edesc = nr (GlobalExport (nr (get_global env name)))
    })

  let get_globals (env : t) = List.map (fun (g,n) -> g) !(env.globals)

  let reserve_fun (env : t) name =
    let (j, fill) = reserve_promise env.funcs name in
    let n = Int32.of_int (List.length !(env.func_imports)) in
    let fi = Int32.add j n in
    let fill_ (f, local_names) = fill (f, name, local_names) in
    (fi, fill_)

  let add_fun (env : t) name (f, local_names) =
    let (fi, fill) = reserve_fun env name in
    fill (f, local_names);
    fi

  let built_in (env : t) name : int32 =
    match NameEnv.find_opt name !(env.built_in_funcs) with
    | None ->
        let (fi, fill) = reserve_fun env name in
        env.built_in_funcs := NameEnv.add name (Declared (fi, fill)) !(env.built_in_funcs);
        fi
    | Some (Declared (fi, _)) -> fi
    | Some (Defined fi) -> fi
    | Some (Pending mk_fun) ->
        let (fi, fill) = reserve_fun env name in
        env.built_in_funcs := NameEnv.add name (Defined fi) !(env.built_in_funcs);
        fill (mk_fun ());
        fi

  let define_built_in (env : t) name mk_fun : unit =
    match NameEnv.find_opt name !(env.built_in_funcs) with
    | None ->
        env.built_in_funcs := NameEnv.add name (Pending mk_fun) !(env.built_in_funcs);
    | Some (Declared (fi, fill)) ->
        env.built_in_funcs := NameEnv.add name (Defined fi) !(env.built_in_funcs);
        fill (mk_fun ());
    | Some (Defined fi) ->  ()
    | Some (Pending mk_fun) -> ()

  let get_return_arity (env : t) = env.return_arity

  let get_func_imports (env : t) = !(env.func_imports)
  let get_other_imports (env : t) = !(env.other_imports)
  let get_exports (env : t) = !(env.exports)
  let get_funcs (env : t) = List.map Lib.Promise.value !(env.funcs)

  let func_type (env : t) ty =
    let rec go i = function
      | [] -> env.func_types := !(env.func_types) @ [ ty ]; Int32.of_int i
      | ty'::tys when ty = ty' -> Int32.of_int i
      | _ :: tys -> go (i+1) tys
       in
    go 0 !(env.func_types)

  let get_types (env : t) = !(env.func_types)

  let add_func_import (env : t) modname funcname arg_tys ret_tys =
    if !(env.funcs) = []
    then
      let i = {
        module_name = Wasm.Utf8.decode modname;
        item_name = Wasm.Utf8.decode funcname;
        idesc = nr (FuncImport (nr (func_type env (FuncType (arg_tys, ret_tys)))))
      } in
      let fi = reg env.func_imports (nr i) in
      let name = modname ^ "." ^ funcname in
      assert (not (NameEnv.mem name !(env.built_in_funcs)));
      env.built_in_funcs := NameEnv.add name (Defined fi) !(env.built_in_funcs);
    else assert false (* "add all imports before all functions!" *)

  let call_import (env : t) modname funcname =
    let name = modname ^ "." ^ funcname in
    match NameEnv.find_opt name !(env.built_in_funcs) with
      | Some (Defined fi) -> G.i (Call (nr fi))
      | _ ->
        Printf.eprintf "Function import not declared: %s\n" name;
        G.i Unreachable

  let get_prelude (env : t) = env.prelude
  let get_rts (env : t) = env.rts

  let get_trap_with (env : t) = env.trap_with
  let trap_with env msg = env.trap_with env msg
  let then_trap_with env msg = G.if_ (ValBlockType None) (trap_with env msg) G.nop
  let else_trap_with env msg = G.if_ (ValBlockType None) G.nop (trap_with env msg)

  let reserve_static_memory (env : t) size : int32 =
    if !(env.static_memory_frozen) then assert false (* "Static memory frozen" *);
    let ptr = !(env.end_of_static_memory) in
    let aligned = Int32.logand (Int32.add size 3l) (Int32.lognot 3l) in
    env.end_of_static_memory := Int32.add ptr aligned;
    ptr

  let add_mutable_static_bytes (env : t) data : int32 =
    let ptr = reserve_static_memory env (Int32.of_int (String.length data)) in
    env.static_memory := !(env.static_memory) @ [ (ptr, data) ];
    Int32.(add ptr ptr_skew) (* Return a skewed pointer *)

  let add_static_bytes (env : t) data : int32 =
    match StringEnv.find_opt data !(env.static_strings)  with
    | Some ptr -> ptr
    | None ->
      let ptr = add_mutable_static_bytes env data  in
      env.static_strings := StringEnv.add data ptr !(env.static_strings);
      ptr

  let get_end_of_static_memory env : int32 =
    env.static_memory_frozen := true;
    !(env.end_of_static_memory)

  let get_static_memory env =
    !(env.static_memory)

  let mem_size env =
    Int32.(add (div (get_end_of_static_memory env) page_size) 1l)
end


(* General code generation functions:
   Rule of thumb: Here goes stuff that independent of the Motoko AST.
*)

(* Function called compile_* return a list of instructions (and maybe other stuff) *)

let compile_unboxed_const i = G.i (Wasm.Ast.Const (nr (Wasm.Values.I32 i)))
let compile_const_64 i = G.i (Wasm.Ast.Const (nr (Wasm.Values.I64 i)))
let compile_unboxed_zero = compile_unboxed_const 0l
let compile_unboxed_one = compile_unboxed_const 1l

(* Some common arithmetic, used for pointer and index arithmetic *)
let compile_op_const op i =
    compile_unboxed_const i ^^
    G.i (Binary (Wasm.Values.I32 op))
let compile_add_const = compile_op_const I32Op.Add
let compile_sub_const = compile_op_const I32Op.Sub
let compile_mul_const = compile_op_const I32Op.Mul
let compile_divU_const = compile_op_const I32Op.DivU
let compile_shrU_const = compile_op_const I32Op.ShrU
let compile_shrS_const = compile_op_const I32Op.ShrS
let compile_shl_const = compile_op_const I32Op.Shl
let compile_rotr_const = compile_op_const I32Op.Rotr
let compile_rotl_const = compile_op_const I32Op.Rotl
let compile_bitand_const = compile_op_const I32Op.And
let compile_bitor_const = function
  | 0l -> G.nop | n -> compile_op_const I32Op.Or n
let compile_rel_const rel i =
  compile_unboxed_const i ^^
  G.i (Compare (Wasm.Values.I32 rel))
let compile_eq_const = compile_rel_const I32Op.Eq

let compile_op64_const op i =
    compile_const_64 i ^^
    G.i (Binary (Wasm.Values.I64 op))
let _compile_add64_const = compile_op64_const I64Op.Add
let compile_sub64_const = compile_op64_const I64Op.Sub
let _compile_mul64_const = compile_op64_const I64Op.Mul
let _compile_divU64_const = compile_op64_const I64Op.DivU
let compile_shrU64_const = function
  | 0L -> G.nop | n -> compile_op64_const I64Op.ShrU n
let compile_shrS64_const = function
  | 0L -> G.nop | n -> compile_op64_const I64Op.ShrS n
let compile_shl64_const = function
  | 0L -> G.nop | n -> compile_op64_const I64Op.Shl n
let compile_bitand64_const = compile_op64_const I64Op.And
let _compile_bitor64_const = function
  | 0L -> G.nop | n -> compile_op64_const I64Op.Or n
let compile_eq64_const i =
  compile_const_64 i ^^
  G.i (Compare (Wasm.Values.I64 I64Op.Eq))

(* more random utilities *)

let bytes_of_int32 (i : int32) : string =
  let b = Buffer.create 4 in
  let i1 = Int32.to_int i land 0xff in
  let i2 = (Int32.to_int i lsr 8) land 0xff in
  let i3 = (Int32.to_int i lsr 16) land 0xff in
  let i4 = (Int32.to_int i lsr 24) land 0xff in
  Buffer.add_char b (Char.chr i1);
  Buffer.add_char b (Char.chr i2);
  Buffer.add_char b (Char.chr i3);
  Buffer.add_char b (Char.chr i4);
  Buffer.contents b

(* A common variant of todo *)

let todo_trap env fn se = todo fn se (E.trap_with env ("TODO: " ^ fn))
let todo_trap_SR env fn se = todo fn se (SR.Unreachable, E.trap_with env ("TODO: " ^ fn))

(* Locals *)

let new_local_ env t name =
  let i = E.add_anon_local env t in
  E.add_local_name env i name;
  ( G.i (LocalSet (nr i))
  , G.i (LocalGet (nr i))
  , i
  )

let new_local env name =
  let (set_i, get_i, _) = new_local_ env I32Type name
  in (set_i, get_i)

let new_local64 env name =
  let (set_i, get_i, _) = new_local_ env I64Type name
  in (set_i, get_i)

(* Some common code macros *)

(* Iterates while cond is true. *)
let compile_while cond body =
    G.loop_ (ValBlockType None) (
      cond ^^ G.if_ (ValBlockType None) (body ^^ G.i (Br (nr 1l))) G.nop
    )

(* Expects a number on the stack. Iterates from zero to below that number. *)
let from_0_to_n env mk_body =
    let (set_n, get_n) = new_local env "n" in
    let (set_i, get_i) = new_local env "i" in
    set_n ^^
    compile_unboxed_zero ^^
    set_i ^^

    compile_while
      ( get_i ^^
        get_n ^^
        G.i (Compare (Wasm.Values.I32 I32Op.LtU))
      ) (
        mk_body get_i ^^

        get_i ^^
        compile_add_const 1l ^^
        set_i
      )


(* Pointer reference and dereference  *)

let load_unskewed_ptr : G.t =
  G.i (Load {ty = I32Type; align = 2; offset = 0l; sz = None})

let _store_unskewed_ptr : G.t =
  G.i (Store {ty = I32Type; align = 2; offset = 0l; sz = None})

let load_ptr : G.t =
  G.i (Load {ty = I32Type; align = 2; offset = ptr_unskew; sz = None})

let store_ptr : G.t =
  G.i (Store {ty = I32Type; align = 2; offset = ptr_unskew; sz = None})

module FakeMultiVal = struct
  (* For some use-cases (e.g. processing the compiler output with analysis
     tools) it is useful to avoid the multi-value extension.

     This module provides mostly transparent wrappers that put multiple values
     in statically allocated globals and pull them off again.

     So far only does I32Type (but that could be changed).

     If the multi_value flag is on, these do not do anything.
  *)
  let ty tys =
    if !Flags.multi_value || List.length tys <= 1
    then tys
    else []

  let global env i =
    E.get_global32_lazy env (Printf.sprintf "multi_val_%d" i) Mutable 0l

  let store env tys =
    if !Flags.multi_value || List.length tys <= 1 then G.nop else
    G.concat_mapi (fun i _ ->
      G.i (GlobalSet (nr (global env i)))
    ) tys

  let load env tys =
    if !Flags.multi_value || List.length tys <= 1 then G.nop else
    let n = List.length tys - 1 in
    G.concat_mapi (fun i _ ->
      G.i (GlobalGet (nr (global env (n - i))))
    ) tys

end (* FakeMultiVal *)

module Func = struct
  (* This module contains basic bookkeeping functionality to define functions,
     in particular creating the environment, and finally adding it to the environment.
  *)

  let of_body env params retty mk_body =
    let env1 = E.mk_fun_env env (Int32.of_int (List.length params)) (List.length retty) in
    List.iteri (fun i (n,_t) -> E.add_local_name env1 (Int32.of_int i) n) params;
    let ty = FuncType (List.map snd params, FakeMultiVal.ty retty) in
    let body = G.to_instr_list (
      mk_body env1 ^^ FakeMultiVal.store env1 retty
    ) in
    (nr { ftype = nr (E.func_type env ty);
          locals = E.get_locals env1;
          body }
    , E.get_local_names env1)

  let define_built_in env name params retty mk_body =
    E.define_built_in env name (fun () -> of_body env params retty mk_body)

  (* (Almost) transparently lift code into a function and call this function. *)
  (* Also add a hack to support multiple return values *)
  let share_code env name params retty mk_body =
    define_built_in env name params retty mk_body;
    G.i (Call (nr (E.built_in env name))) ^^
    FakeMultiVal.load env retty


  (* Shorthands for various arities *)
  let share_code0 env name retty mk_body =
    share_code env name [] retty (fun env -> mk_body env)
  let share_code1 env name p1 retty mk_body =
    share_code env name [p1] retty (fun env -> mk_body env
        (G.i (LocalGet (nr 0l)))
    )
  let share_code2 env name (p1,p2) retty mk_body =
    share_code env name [p1; p2] retty (fun env -> mk_body env
        (G.i (LocalGet (nr 0l)))
        (G.i (LocalGet (nr 1l)))
    )
  let share_code3 env name (p1, p2, p3) retty mk_body =
    share_code env name [p1; p2; p3] retty (fun env -> mk_body env
        (G.i (LocalGet (nr 0l)))
        (G.i (LocalGet (nr 1l)))
        (G.i (LocalGet (nr 2l)))
    )
  let share_code4 env name (p1, p2, p3, p4) retty mk_body =
    share_code env name [p1; p2; p3; p4] retty (fun env -> mk_body env
        (G.i (LocalGet (nr 0l)))
        (G.i (LocalGet (nr 1l)))
        (G.i (LocalGet (nr 2l)))
        (G.i (LocalGet (nr 3l)))
    )

end (* Func *)

module RTS = struct
  (* The connection to the C parts of the RTS *)
  let system_imports env =
    E.add_func_import env "rts" "as_memcpy" [I32Type; I32Type; I32Type] [];
    E.add_func_import env "rts" "version" [] [I32Type];
    E.add_func_import env "rts" "parse_idl_header" [I32Type; I32Type; I32Type] [];
    E.add_func_import env "rts" "read_u32_of_leb128" [I32Type] [I32Type];
    E.add_func_import env "rts" "read_i32_of_sleb128" [I32Type] [I32Type];
    E.add_func_import env "rts" "bigint_of_word32" [I32Type] [I32Type];
    E.add_func_import env "rts" "bigint_of_word32_signed" [I32Type] [I32Type];
    E.add_func_import env "rts" "bigint_to_word32_wrap" [I32Type] [I32Type];
    E.add_func_import env "rts" "bigint_to_word32_trap" [I32Type] [I32Type];
    E.add_func_import env "rts" "bigint_to_word32_signed_trap" [I32Type] [I32Type];
    E.add_func_import env "rts" "bigint_of_word64" [I64Type] [I32Type];
    E.add_func_import env "rts" "bigint_of_word64_signed" [I64Type] [I32Type];
    E.add_func_import env "rts" "bigint_to_word64_wrap" [I32Type] [I64Type];
    E.add_func_import env "rts" "bigint_to_word64_trap" [I32Type] [I64Type];
    E.add_func_import env "rts" "bigint_to_word64_signed_trap" [I32Type] [I64Type];
    E.add_func_import env "rts" "bigint_eq" [I32Type; I32Type] [I32Type];
    E.add_func_import env "rts" "bigint_isneg" [I32Type] [I32Type];
    E.add_func_import env "rts" "bigint_count_bits" [I32Type] [I32Type];
    E.add_func_import env "rts" "bigint_2complement_bits" [I32Type] [I32Type];
    E.add_func_import env "rts" "bigint_lt" [I32Type; I32Type] [I32Type];
    E.add_func_import env "rts" "bigint_gt" [I32Type; I32Type] [I32Type];
    E.add_func_import env "rts" "bigint_le" [I32Type; I32Type] [I32Type];
    E.add_func_import env "rts" "bigint_ge" [I32Type; I32Type] [I32Type];
    E.add_func_import env "rts" "bigint_add" [I32Type; I32Type] [I32Type];
    E.add_func_import env "rts" "bigint_sub" [I32Type; I32Type] [I32Type];
    E.add_func_import env "rts" "bigint_mul" [I32Type; I32Type] [I32Type];
    E.add_func_import env "rts" "bigint_rem" [I32Type; I32Type] [I32Type];
    E.add_func_import env "rts" "bigint_div" [I32Type; I32Type] [I32Type];
    E.add_func_import env "rts" "bigint_pow" [I32Type; I32Type] [I32Type];
    E.add_func_import env "rts" "bigint_neg" [I32Type] [I32Type];
    E.add_func_import env "rts" "bigint_lsh" [I32Type; I32Type] [I32Type];
    E.add_func_import env "rts" "bigint_abs" [I32Type] [I32Type];
    E.add_func_import env "rts" "bigint_leb128_size" [I32Type] [I32Type];
    E.add_func_import env "rts" "bigint_leb128_encode" [I32Type; I32Type] [];
    E.add_func_import env "rts" "bigint_leb128_decode" [I32Type] [I32Type];
    E.add_func_import env "rts" "bigint_sleb128_size" [I32Type] [I32Type];
    E.add_func_import env "rts" "bigint_sleb128_encode" [I32Type; I32Type] [];
    E.add_func_import env "rts" "bigint_sleb128_decode" [I32Type] [I32Type];
    E.add_func_import env "rts" "leb128_encode" [I32Type; I32Type] [];
    E.add_func_import env "rts" "sleb128_encode" [I32Type; I32Type] [];
    E.add_func_import env "rts" "utf8_validate" [I32Type; I32Type] [];
    E.add_func_import env "rts" "skip_leb128" [I32Type] [];
    E.add_func_import env "rts" "skip_any" [I32Type; I32Type; I32Type; I32Type] [];
    E.add_func_import env "rts" "find_field" [I32Type; I32Type; I32Type; I32Type; I32Type] [I32Type];
    E.add_func_import env "rts" "skip_fields" [I32Type; I32Type; I32Type; I32Type] [];
    E.add_func_import env "rts" "remember_closure" [I32Type] [I32Type];
    E.add_func_import env "rts" "recall_closure" [I32Type] [I32Type];
    E.add_func_import env "rts" "closure_count" [] [I32Type];
    E.add_func_import env "rts" "closure_table_loc" [] [I32Type];
    E.add_func_import env "rts" "closure_table_size" [] [I32Type];
    ()

end (* RTS *)

module Heap = struct
  (* General heap object functionality (allocation, setting fields, reading fields) *)

  (* Memory addresses are 32 bit (I32Type). *)
  let word_size = 4l

  (* The heap base global can only be used late, see conclude_module
     and GHC.register *)
  let get_heap_base env =
    G.i (GlobalGet (nr (E.get_global env "__heap_base")))

  (* We keep track of the end of the used heap in this global, and bump it if
     we allocate stuff. This is the actual memory offset, not-skewed yet *)
  let get_heap_ptr env =
    G.i (GlobalGet (nr (E.get_global env "end_of_heap")))
  let set_heap_ptr env =
    G.i (GlobalSet (nr (E.get_global env "end_of_heap")))
  let get_skewed_heap_ptr env = get_heap_ptr env ^^ compile_add_const ptr_skew

  let register_globals env =
    (* end-of-heap pointer, we set this to __heap_base upon start *)
    E.add_global32 env "end_of_heap" Mutable 0xDEADBEEFl;

    (* counter for total allocations *)
    E.add_global64 env "allocations" Mutable 0L

  let count_allocations env =
    (* assumes number of allocated bytes on the stack *)
    G.i (Convert (Wasm.Values.I64 I64Op.ExtendUI32)) ^^
    G.i (GlobalGet (nr (E.get_global env "allocations"))) ^^
    G.i (Binary (Wasm.Values.I64 I64Op.Add)) ^^
    G.i (GlobalSet (nr (E.get_global env "allocations")))

  let get_total_allocation env =
    G.i (GlobalGet (nr (E.get_global env "allocations")))

  (* Page allocation. Ensures that the memory up to the given unskewed pointer is allocated. *)
  let grow_memory env =
    Func.share_code1 env "grow_memory" ("ptr", I32Type) [] (fun env get_ptr ->
      let (set_pages_needed, get_pages_needed) = new_local env "pages_needed" in
      get_ptr ^^ compile_divU_const page_size ^^
      compile_add_const 1l ^^
      G.i MemorySize ^^
      G.i (Binary (Wasm.Values.I32 I32Op.Sub)) ^^
      set_pages_needed ^^

      (* Check that the new heap pointer is within the memory *)
      get_pages_needed ^^
      compile_unboxed_zero ^^
      G.i (Compare (Wasm.Values.I32 I32Op.GtS)) ^^
      G.if_ (ValBlockType None)
        ( get_pages_needed ^^
          G.i MemoryGrow ^^
          (* Check result *)
          compile_unboxed_zero ^^
          G.i (Compare (Wasm.Values.I32 I32Op.LtS)) ^^
          E.then_trap_with env "Cannot grow memory."
        ) G.nop
      )

  (* Dynamic allocation *)
  let dyn_alloc_words env =
    Func.share_code1 env "alloc_words" ("n", I32Type) [I32Type] (fun env get_n ->
      (* expects the size (in words), returns the skewed pointer *)

      (* return the current pointer (skewed) *)
      get_skewed_heap_ptr env ^^

      (* Cound allocated bytes *)
      get_n ^^ compile_mul_const word_size ^^
      count_allocations env ^^

      (* Update heap pointer *)
      get_heap_ptr env ^^
      get_n ^^ compile_mul_const word_size ^^
      G.i (Binary (Wasm.Values.I32 I32Op.Add)) ^^
      set_heap_ptr env ^^

      (* grow memory if needed *)
      get_heap_ptr env ^^ grow_memory env
    )

  let dyn_alloc_bytes env =
    Func.share_code1 env "alloc_bytes" ("n", I32Type) [I32Type] (fun env get_n ->
      get_n ^^
      (* Round up to next multiple of the word size and convert to words *)
      compile_add_const 3l ^^
      compile_divU_const word_size ^^
      dyn_alloc_words env
    )

  (* Static allocation (always words)
     (uses dynamic allocation for smaller and more readable code) *)
  let alloc env (n : int32) : G.t =
    compile_unboxed_const n  ^^
    dyn_alloc_words env

  (* Heap objects *)

  (* At this level of abstraction, heap objects are just flat arrays of words *)

  let load_field (i : int32) : G.t =
    let offset = Int32.(add (mul word_size i) ptr_unskew) in
    G.i (Load {ty = I32Type; align = 2; offset; sz = None})

  let store_field (i : int32) : G.t =
    let offset = Int32.(add (mul word_size i) ptr_unskew) in
    G.i (Store {ty = I32Type; align = 2; offset; sz = None})

  (* Although we occasionally want to treat two 32 bit fields as one 64 bit number *)

  let load_field64 (i : int32) : G.t =
    let offset = Int32.(add (mul word_size i) ptr_unskew) in
    G.i (Load {ty = I64Type; align = 2; offset; sz = None})

  let store_field64 (i : int32) : G.t =
    let offset = Int32.(add (mul word_size i) ptr_unskew) in
    G.i (Store {ty = I64Type; align = 2; offset; sz = None})

  (* Create a heap object with instructions that fill in each word *)
  let obj env element_instructions : G.t =
    let (set_heap_obj, get_heap_obj) = new_local env "heap_object" in

    let n = List.length element_instructions in
    alloc env (Wasm.I32.of_int_u n) ^^
    set_heap_obj ^^

    let init_elem idx instrs : G.t =
      get_heap_obj ^^
      instrs ^^
      store_field (Wasm.I32.of_int_u idx)
    in
    G.concat_mapi init_elem element_instructions ^^
    get_heap_obj

  (* Convenience functions related to memory *)
  (* Copying bytes (works on unskewed memory addresses) *)
  let memcpy env = E.call_import env "rts" "as_memcpy"

  (* Copying words (works on skewed memory addresses) *)
  let memcpy_words_skewed env =
    Func.share_code3 env "memcpy_words_skewed" (("to", I32Type), ("from", I32Type), ("n", I32Type)) [] (fun env get_to get_from get_n ->
      get_n ^^
      from_0_to_n env (fun get_i ->
          get_to ^^
          get_i ^^ compile_mul_const word_size ^^
          G.i (Binary (Wasm.Values.I32 I32Op.Add)) ^^

          get_from ^^
          get_i ^^ compile_mul_const word_size ^^
          G.i (Binary (Wasm.Values.I32 I32Op.Add)) ^^
          load_ptr ^^

          store_ptr
      )
    )

end (* Heap *)

module Stack = struct
  (* The RTS includes C code which requires a shadow stack in linear memory.
     We reserve some space for it at the beginning of memory space (just like
     wasm-l would), this way stack overflow would cause out-of-memory, and not
     just overwrite static data.

     We sometimes use the stack space if we need small amounts of scratch space.
  *)

  let end_of_stack = page_size (* 64k of stack *)

  let register_globals env =
    (* stack pointer *)
    E.add_global32 env "__stack_pointer" Mutable end_of_stack;
    E.export_global env "__stack_pointer"

  let get_stack_ptr env =
    G.i (GlobalGet (nr (E.get_global env "__stack_pointer")))
  let set_stack_ptr env =
    G.i (GlobalSet (nr (E.get_global env "__stack_pointer")))

  let alloc_words env n =
    get_stack_ptr env ^^
    compile_unboxed_const (Int32.mul n Heap.word_size) ^^
    G.i (Binary (Wasm.Values.I32 I32Op.Sub)) ^^
    set_stack_ptr env ^^
    get_stack_ptr env

  let free_words env n =
    get_stack_ptr env ^^
    compile_unboxed_const (Int32.mul n Heap.word_size) ^^
    G.i (Binary (Wasm.Values.I32 I32Op.Add)) ^^
    set_stack_ptr env

  let with_words env name n f =
    let (set_x, get_x) = new_local env name in
    alloc_words env n ^^ set_x ^^
    f get_x ^^
    free_words env n

end (* Stack *)

module ClosureTable = struct
  (* See rts/closure-table.c *)
  let remember env : G.t = E.call_import env "rts" "remember_closure"
  let recall env : G.t = E.call_import env "rts" "recall_closure"
  let count env : G.t = E.call_import env "rts" "closure_count"
  let size env : G.t = E.call_import env "rts" "closure_table_size"
  let root env : G.t = E.call_import env "rts" "closure_table_loc"
end (* ClosureTable *)

module Bool = struct
  (* Boolean literals are either 0 or 1
     Both are recognized as unboxed scalars anyways,
     This allows us to use the result of the WebAssembly comparison operators
     directly, and to use the booleans directly with WebAssembly’s If.
  *)
  let lit = function
    | false -> compile_unboxed_zero
    | true -> compile_unboxed_one

  let neg = G.i (Test (Wasm.Values.I32 I32Op.Eqz))

end (* Bool *)


module BitTagged = struct
  let scalar_shift = 2l

  (* This module takes care of pointer tagging:

     A pointer to an object at offset `i` on the heap is represented as
     `i-1`, so the low two bits of the pointer are always set. We call
     `i-1` a *skewed* pointer, in a feeble attempt to avoid the term shifted,
     which may sound like a logical shift.

     We use the constants ptr_skew and ptr_unskew to change a pointer as a
     signpost where we switch between raw pointers to skewed ones.

     This means we can store a small unboxed scalar x as (x << 2), and still
     tell it apart from a pointer.

     We actually use the *second* lowest bit to tell a pointer apart from a
     scalar.

     It means that 0 and 1 are also recognized as non-pointers, and we can use
     these for false and true, matching the result of WebAssembly’s comparison
     operators.
  *)
  let if_unboxed env retty is1 is2 =
    Func.share_code1 env "is_unboxed" ("x", I32Type) [I32Type] (fun env get_x ->
      (* Get bit *)
      get_x ^^
      compile_bitand_const 0x2l ^^
      (* Check bit *)
      G.i (Test (Wasm.Values.I32 I32Op.Eqz))
    ) ^^
    G.if_ retty is1 is2

  (* With two bit-tagged pointers on the stack, decide
     whether both are scalars and invoke is1 (the fast path)
     if so, and otherwise is2 (the slow path).
  *)
  let if_both_unboxed env retty is1 is2 =
    G.i (Binary (Wasm.Values.I32 I32Op.Or)) ^^
    if_unboxed env retty is1 is2

  (* The untag_scalar and tag functions expect 64 bit numbers *)
  let untag_scalar env =
    compile_shrU_const scalar_shift ^^
    G.i (Convert (Wasm.Values.I64 I64Op.ExtendUI32))

  let tag =
    G.i (Convert (Wasm.Values.I32 I32Op.WrapI64)) ^^
    compile_shl_const scalar_shift

  (* The untag_i32 and tag_i32 functions expect 32 bit numbers *)
  let untag_i32 env =
    compile_shrU_const scalar_shift

  let tag_i32 =
    compile_unboxed_const scalar_shift ^^
    G.i (Binary (Wasm.Values.I32 I32Op.Shl))

end (* BitTagged *)

module Tagged = struct
  (* Tagged objects have, well, a tag to describe their runtime type.
     This tag is used to traverse the heap (serialization, GC), but also
     for objectification of arrays.

     The tag is a word at the beginning of the object.

     All tagged heap objects have a size of at least two words
     (important for GC, which replaces them with an Indirection).

     Attention: This mapping is duplicated in rts/rts.c, so update both!
   *)

  type tag =
    | Object
    | ObjInd (* The indirection used for object fields *)
    | Array (* Also a tuple *)
    | Int (* Contains a 64 bit number *)
    | MutBox (* used for mutable heap-allocated variables *)
    | Closure
    | Some (* For opt *)
    | Variant
    | Blob
    | Indirection
    | SmallWord (* Contains a 32 bit unsigned number *)
    | BigInt

  (* Let's leave out tag 0 to trap earlier on invalid memory *)
  let int_of_tag = function
    | Object -> 1l
    | ObjInd -> 2l
    | Array -> 3l
    | Int -> 5l
    | MutBox -> 6l
    | Closure -> 7l
    | Some -> 8l
    | Variant -> 9l
    | Blob -> 10l
    | Indirection -> 11l
    | SmallWord -> 12l
    | BigInt -> 13l

  (* The tag *)
  let header_size = 1l
  let tag_field = 0l

  (* Assumes a pointer to the object on the stack *)
  let store tag =
    compile_unboxed_const (int_of_tag tag) ^^
    Heap.store_field tag_field

  let load =
    Heap.load_field tag_field

  (* Branches based on the tag of the object pointed to,
     leaving the object on the stack afterwards. *)
  let branch_default env retty def (cases : (tag * G.t) list) : G.t =
    let (set_tag, get_tag) = new_local env "tag" in

    let rec go = function
      | [] -> def
      | ((tag, code) :: cases) ->
        get_tag ^^
        compile_eq_const (int_of_tag tag) ^^
        G.if_ retty code (go cases)
    in
    load ^^
    set_tag ^^
    go cases

  (* like branch_default but the tag is known statically *)
  let branch env retty = function
    | [] -> G.i Unreachable
    | [_, code] -> G.i Drop ^^ code
    | (_, code) :: cases -> branch_default env retty code cases

  (* like branch_default but also pushes the scrutinee on the stack for the
   * branch's consumption *)
  let _branch_default_with env retty def cases =
    let (set_o, get_o) = new_local env "o" in
    let prep (t, code) = (t, get_o ^^ code)
    in set_o ^^ get_o ^^ branch_default env retty def (List.map prep cases)

  (* like branch_default_with but the tag is known statically *)
  let branch_with env retty = function
    | [] -> G.i Unreachable
    | [_, code] -> code
    | (_, code) :: cases ->
       let (set_o, get_o) = new_local env "o" in
       let prep (t, code) = (t, get_o ^^ code)
       in set_o ^^ get_o ^^ branch_default env retty (get_o ^^ code) (List.map prep cases)

  (* Can a value of this type be represented by a heap object with this tag? *)
  (* Needs to be conservative, i.e. return `true` if unsure *)
  (* This function can also be used as assertions in a lint mode, e.g. in compile_exp *)
  let can_have_tag ty tag =
    let open Mo_types.Type in
    match (tag : tag) with
    | Array ->
      begin match normalize ty with
      | (Con _ | Any) -> true
      | (Array _ | Tup _) -> true
      | (Prim _ |  Obj _ | Opt _ | Variant _ | Func _ | Non) -> false
      | (Pre | Async _ | Mut _ | Var _ | Typ _) -> assert false
      end
    | Blob ->
      begin match normalize ty with
      | (Con _ | Any) -> true
      | (Prim Text) -> true
      | (Prim _ | Obj _ | Array _ | Tup _ | Opt _ | Variant _ | Func _ | Non) -> false
      | (Pre | Async _ | Mut _ | Var _ | Typ _) -> assert false
      end
    | Object ->
      begin match normalize ty with
      | (Con _ | Any) -> true
      | (Obj _) -> true
      | (Prim _ | Array _ | Tup _ | Opt _ | Variant _ | Func _ | Non) -> false
      | (Pre | Async _ | Mut _ | Var _ | Typ _) -> assert false
      end
    | _ -> true

  (* like branch_with but with type information to statically skip some branches *)
  let _branch_typed_with env ty retty branches =
    branch_with env retty (List.filter (fun (tag,c) -> can_have_tag ty tag) branches)

  let obj env tag element_instructions : G.t =
    Heap.obj env @@
      compile_unboxed_const (int_of_tag tag) ::
      element_instructions

end (* Tagged *)

module MutBox = struct
  (* Mutable heap objects *)

  let field = Tagged.header_size
  let load = Heap.load_field field
  let store = Heap.store_field field
end


module Opt = struct
  (* The Option type. Not much interesting to see here. Structure for
     Some:

       ┌─────┬─────────┐
       │ tag │ payload │
       └─────┴─────────┘

    A None value is simply an unboxed scalar.

  *)

  let payload_field = Tagged.header_size

  (* This needs to be disjoint from all pointers, i.e. tagged as a scalar. *)
  let null = compile_unboxed_const 5l

  let is_some env =
    null ^^
    G.i (Compare (Wasm.Values.I32 I32Op.Ne))

  let inject env e = Tagged.obj env Tagged.Some [e]
  let project = Heap.load_field payload_field

end (* Opt *)

module Variant = struct
  (* The Variant type. We store the variant tag in a first word; we can later
     optimize and squeeze it in the Tagged tag. We can also later support unboxing
     variants with an argument of type ().

       ┌─────────┬────────────┬─────────┐
       │ heaptag │ varianttag │ payload │
       └─────────┴────────────┴─────────┘

  *)

  let tag_field = Tagged.header_size
  let payload_field = Int32.add Tagged.header_size 1l

  let hash_variant_label : Mo_types.Type.lab -> int32 =
    Mo_types.Hash.hash

  let inject env l e =
    Tagged.obj env Tagged.Variant [compile_unboxed_const (hash_variant_label l); e]

  let get_tag = Heap.load_field tag_field
  let project = Heap.load_field payload_field

  (* Test if the top of the stacks points to a variant with this label *)
  let test_is env l =
    get_tag ^^
    compile_eq_const (hash_variant_label l)

end (* Variant *)


module Closure = struct
  (* In this module, we deal with closures, i.e. functions that capture parts
     of their environment.

     The structure of a closure is:

       ┌─────┬───────┬──────┬──────────────┐
       │ tag │ funid │ size │ captured ... │
       └─────┴───────┴──────┴──────────────┘

  *)
  let header_size = Int32.add Tagged.header_size 2l

  let funptr_field = Tagged.header_size
  let len_field = Int32.add 1l Tagged.header_size

  let get = G.i (LocalGet (nr 0l))
  let load_data i = Heap.load_field (Int32.add header_size i)
  let store_data i = Heap.store_field (Int32.add header_size i)

  (* Expect on the stack
     * the function closure
     * and arguments (n-ary!)
     * the function closure again!
  *)
  let call_closure env n_args n_res =
    (* Calculate the wasm type for a given calling convention.
       An extra first argument for the closure! *)
    let ty = E.func_type env (FuncType (
      I32Type :: Lib.List.make n_args I32Type,
      FakeMultiVal.ty (Lib.List.make n_res I32Type))) in
    (* get the table index *)
    Heap.load_field funptr_field ^^
    (* All done: Call! *)
    G.i (CallIndirect (nr ty)) ^^
    FakeMultiVal.load env (Lib.List.make n_res I32Type)

  let fixed_closure env fi fields =
      Tagged.obj env Tagged.Closure
        ([ compile_unboxed_const fi
         ; compile_unboxed_const (Int32.of_int (List.length fields)) ] @
         fields)

end (* Closure *)


module BoxedWord64 = struct
  (* We store large word64s, nat64s and int64s in immutable boxed 64bit heap objects.

     Small values (just <2^5 for now, so that both code paths are well-tested)
     are stored unboxed, tagged, see BitTagged.

     The heap layout of a BoxedWord64 is:

       ┌─────┬─────┬─────┐
       │ tag │    i64    │
       └─────┴─────┴─────┘

  *)

  let payload_field = Tagged.header_size

  let compile_box env compile_elem : G.t =
    let (set_i, get_i) = new_local env "boxed_i64" in
    Heap.alloc env 3l ^^
    set_i ^^
    get_i ^^ Tagged.store Tagged.Int ^^
    get_i ^^ compile_elem ^^ Heap.store_field64 payload_field ^^
    get_i

  let box env = Func.share_code1 env "box_i64" ("n", I64Type) [I32Type] (fun env get_n ->
      get_n ^^ compile_const_64 (Int64.of_int (1 lsl 5)) ^^
      G.i (Compare (Wasm.Values.I64 I64Op.LtU)) ^^
      G.if_ (ValBlockType (Some I32Type))
        (get_n ^^ BitTagged.tag)
        (compile_box env get_n)
    )

  let unbox env = Func.share_code1 env "unbox_i64" ("n", I32Type) [I64Type] (fun env get_n ->
      get_n ^^
      BitTagged.if_unboxed env (ValBlockType (Some I64Type))
        ( get_n ^^ BitTagged.untag_scalar env)
        ( get_n ^^ Heap.load_field64 payload_field)
    )

  let _box32 env =
    G.i (Convert (Wasm.Values.I64 I64Op.ExtendSI32)) ^^ box env

  let _lit env n = compile_const_64 n ^^ box env

  let compile_add env = G.i (Binary (Wasm.Values.I64 I64Op.Add))
  let compile_signed_sub env = G.i (Binary (Wasm.Values.I64 I64Op.Sub))
  let compile_mul env = G.i (Binary (Wasm.Values.I64 I64Op.Mul))
  let compile_signed_div env = G.i (Binary (Wasm.Values.I64 I64Op.DivS))
  let compile_signed_mod env = G.i (Binary (Wasm.Values.I64 I64Op.RemS))
  let compile_unsigned_div env = G.i (Binary (Wasm.Values.I64 I64Op.DivU))
  let compile_unsigned_rem env = G.i (Binary (Wasm.Values.I64 I64Op.RemU))
  let compile_unsigned_sub env =
    Func.share_code2 env "nat_sub" (("n1", I64Type), ("n2", I64Type)) [I64Type] (fun env get_n1 get_n2 ->
      get_n1 ^^ get_n2 ^^ G.i (Compare (Wasm.Values.I64 I64Op.LtU)) ^^
      E.then_trap_with env "Natural subtraction underflow" ^^
      get_n1 ^^ get_n2 ^^ G.i (Binary (Wasm.Values.I64 I64Op.Sub))
    )

  let compile_unsigned_pow env =
    let rec pow () = Func.share_code2 env "pow"
                       (("n", I64Type), ("exp", I64Type)) [I64Type]
                       Wasm.Values.(fun env get_n get_exp ->
         let one = compile_const_64 1L in
         let (set_res, get_res) = new_local64 env "res" in
         let square_recurse_with_shifted =
           get_n ^^ get_exp ^^ one ^^
           G.i (Binary (I64 I64Op.ShrU)) ^^
           pow () ^^ set_res ^^ get_res ^^ get_res ^^ G.i (Binary (Wasm.Values.I64 I64Op.Mul))
         in get_exp ^^ G.i (Test (I64 I64Op.Eqz)) ^^
            G.if_ (ValBlockType (Some I64Type))
             one
             (get_exp ^^ one ^^ G.i (Binary (I64 I64Op.And)) ^^ G.i (Test (I64 I64Op.Eqz)) ^^
              G.if_ (ValBlockType (Some I64Type))
                square_recurse_with_shifted
                (get_n ^^
                 square_recurse_with_shifted ^^
                 G.i (Binary (Wasm.Values.I64 I64Op.Mul)))))
    in pow ()

  let compile_eq env = G.i (Compare (Wasm.Values.I64 I64Op.Eq))
  let compile_relop env i64op = G.i (Compare (Wasm.Values.I64 i64op))

end (* BoxedWord64 *)


module BoxedSmallWord = struct
  (* We store proper 32bit Word32 in immutable boxed 32bit heap objects.

     Small values (just <2^10 for now, so that both code paths are well-tested)
     are stored unboxed, tagged, see BitTagged.

     The heap layout of a BoxedSmallWord is:

       ┌─────┬─────┐
       │ tag │ i32 │
       └─────┴─────┘

  *)

  let payload_field = Tagged.header_size

  let compile_box env compile_elem : G.t =
    let (set_i, get_i) = new_local env "boxed_i32" in
    Heap.alloc env 2l ^^
    set_i ^^
    get_i ^^ Tagged.store Tagged.SmallWord ^^
    get_i ^^ compile_elem ^^ Heap.store_field payload_field ^^
    get_i

  let box env = Func.share_code1 env "box_i32" ("n", I32Type) [I32Type] (fun env get_n ->
      get_n ^^ compile_unboxed_const (Int32.of_int (1 lsl 10)) ^^
      G.i (Compare (Wasm.Values.I32 I32Op.LtU)) ^^
      G.if_ (ValBlockType (Some I32Type))
        (get_n ^^ BitTagged.tag_i32)
        (compile_box env get_n)
    )

  let unbox env = Func.share_code1 env "unbox_i32" ("n", I32Type) [I32Type] (fun env get_n ->
      get_n ^^
      BitTagged.if_unboxed env (ValBlockType (Some I32Type))
        ( get_n ^^ BitTagged.untag_i32 env)
        ( get_n ^^ Heap.load_field payload_field)
    )

  let _lit env n = compile_unboxed_const n ^^ box env

end (* BoxedSmallWord *)

module UnboxedSmallWord = struct
  (* While smaller-than-32bit words are treated as i32 from the WebAssembly perspective,
     there are certain differences that are type based. This module provides helpers to abstract
     over those. *)

  let bits_of_type = function
    | Type.(Int8|Nat8|Word8) -> 8
    | Type.(Int16|Nat16|Word16) -> 16
    | _ -> 32

  let shift_of_type ty = Int32.of_int (32 - bits_of_type ty)

  let bitwidth_mask_of_type = function
    | Type.Word8 -> 0b111l
    | Type.Word16 -> 0b1111l
    | p -> todo "bitwidth_mask_of_type" (Arrange_type.prim p) 0l

  let const_of_type ty n = Int32.(shift_left n (to_int (shift_of_type ty)))

  let padding_of_type ty = Int32.(sub (const_of_type ty 1l) one)

  let mask_of_type ty = Int32.lognot (padding_of_type ty)

  let name_of_type ty seed = match Arrange_type.prim ty with
    | Wasm.Sexpr.Atom s -> seed ^ "<" ^ s ^ ">"
    | wtf -> todo "name_of_type" wtf seed

  (* Makes sure that we only shift/rotate the maximum number of bits available in the word. *)
  let clamp_shift_amount = function
    | Type.Word32 -> G.nop
    | ty -> compile_bitand_const (bitwidth_mask_of_type ty)

  let shift_leftWordNtoI32 = compile_shl_const

  (* Makes sure that the word payload (e.g. shift/rotate amount) is in the LSB bits of the word. *)
  let lsb_adjust = function
    | Type.(Int32|Nat32|Word32) -> G.nop
    | Type.(Nat8|Word8|Nat16|Word16) as ty -> compile_shrU_const (shift_of_type ty)
    | Type.(Int8|Int16) as ty -> compile_shrS_const (shift_of_type ty)
    | _ -> assert false

  (* Makes sure that the word payload (e.g. operation result) is in the MSB bits of the word. *)
  let msb_adjust = function
    | Type.(Int32|Nat32|Word32) -> G.nop
    | ty -> shift_leftWordNtoI32 (shift_of_type ty)

  (* Makes sure that the word representation invariant is restored. *)
  let sanitize_word_result = function
    | Type.Word32 -> G.nop
    | ty -> compile_bitand_const (mask_of_type ty)

  (* Sets the number (according to the type's word invariant) of LSBs. *)
  let compile_word_padding = function
    | Type.Word32 -> G.nop
    | ty -> compile_bitor_const (padding_of_type ty)

  (* Kernel for counting leading zeros, according to the word invariant. *)
  let clz_kernel ty =
    compile_word_padding ty ^^
    G.i (Unary (Wasm.Values.I32 I32Op.Clz)) ^^
    msb_adjust ty
    
  (* Kernel for counting trailing zeros, according to the word invariant. *)
  let ctz_kernel ty =
    compile_word_padding ty ^^
    compile_rotr_const (shift_of_type ty) ^^
    G.i (Unary (Wasm.Values.I32 I32Op.Ctz)) ^^
    msb_adjust ty

  (* Kernel for testing a bit position, according to the word invariant. *)
  let btst_kernel env ty =
    let (set_b, get_b) = new_local env "b"
    in lsb_adjust ty ^^ set_b ^^ lsb_adjust ty ^^
       compile_unboxed_one ^^ get_b ^^ clamp_shift_amount ty ^^
       G.i (Binary (Wasm.Values.I32 I32Op.Shl)) ^^
       G.i (Binary (Wasm.Values.I32 I32Op.And))

  (* Code points occupy 21 bits, no alloc needed in vanilla SR. *)
  let unbox_codepoint = compile_shrU_const 8l
  let box_codepoint = compile_shl_const 8l

  (* Checks (n < 0xD800 || 0xE000 ≤ n ≤ 0x10FFFF),
     ensuring the codepoint range and the absence of surrogates. *)
  let check_and_box_codepoint env get_n =
    get_n ^^ compile_unboxed_const 0xD800l ^^
    G.i (Compare (Wasm.Values.I32 I32Op.GeU)) ^^
    get_n ^^ compile_unboxed_const 0xE000l ^^
    G.i (Compare (Wasm.Values.I32 I32Op.LtU)) ^^
    G.i (Binary (Wasm.Values.I32 I32Op.And)) ^^
    get_n ^^ compile_unboxed_const 0x10FFFFl ^^
    G.i (Compare (Wasm.Values.I32 I32Op.GtU)) ^^
    G.i (Binary (Wasm.Values.I32 I32Op.Or)) ^^
    E.then_trap_with env "codepoint out of range" ^^
    get_n ^^ box_codepoint

  (* Two utilities for dealing with utf-8 encoded bytes. *)
  let compile_load_byte get_ptr offset =
    get_ptr ^^ G.i (Load {ty = I32Type; align = 0; offset; sz = Some (Wasm.Memory.Pack8, Wasm.Memory.ZX)})

  let compile_6bit_mask = compile_bitand_const 0b00111111l

  (* Examines the byte pointed to the address on the stack
   * and following bytes,
   * building an unboxed Unicode code point, and passing it to set_res.
   * and finally returning the number of bytes consumed on the stack.
   * Inspired by https://rosettacode.org/wiki/UTF-8_encode_and_decode#C
   *)
  let len_UTF8_head env set_res =
    let (set_ptr, get_ptr) = new_local env "ptr" in
    let (set_byte, get_byte) = new_local env "byte" in
    let if_under thres mk_then mk_else =
      get_byte ^^ compile_unboxed_const thres ^^ G.i (Compare (Wasm.Values.I32 I32Op.LtU)) ^^
      G.if_ (ValBlockType (Some I32Type)) mk_then mk_else in
    let or_follower offset =
      compile_shl_const 6l ^^
      compile_load_byte get_ptr offset ^^
      compile_6bit_mask ^^
      G.i (Binary (Wasm.Values.I32 I32Op.Or)) in
    set_ptr ^^
    compile_load_byte get_ptr 0l ^^ set_byte ^^
    if_under 0x80l
      ( get_byte ^^
        set_res ^^
        compile_unboxed_const 1l)
      (if_under 0xe0l
         (get_byte ^^ compile_bitand_const 0b00011111l ^^
          or_follower 1l ^^
          set_res ^^
          compile_unboxed_const 2l)
         (if_under 0xf0l
            (get_byte ^^ compile_bitand_const 0b00001111l ^^
             or_follower 1l ^^
             or_follower 2l ^^
             set_res ^^
             compile_unboxed_const 3l)
            (get_byte ^^ compile_bitand_const 0b00000111l ^^
             or_follower 1l ^^
             or_follower 2l^^
             or_follower 3l ^^
             set_res ^^
             compile_unboxed_const 4l)))

  let lit env ty v =
    compile_unboxed_const Int32.(shift_left (of_int v) (to_int (shift_of_type ty)))

  (* Wrapping implementation for multiplication and exponentiation. *)

  let compile_word_mul env ty =
    lsb_adjust ty ^^
    G.i (Binary (Wasm.Values.I32 I32Op.Mul))

  let compile_word_power env ty =
    let rec pow () = Func.share_code2 env (name_of_type ty "pow")
                       (("n", I32Type), ("exp", I32Type)) [I32Type]
                       Wasm.Values.(fun env get_n get_exp ->
        let one = compile_unboxed_const (const_of_type ty 1l) in
        let (set_res, get_res) = new_local env "res" in
        let mul = compile_word_mul env ty in
        let square_recurse_with_shifted sanitize =
          get_n ^^ get_exp ^^ compile_shrU_const 1l ^^ sanitize ^^
          pow () ^^ set_res ^^ get_res ^^ get_res ^^ mul
        in get_exp ^^ G.i (Test (I32 I32Op.Eqz)) ^^
           G.if_ (ValBlockType (Some I32Type))
             one
             (get_exp ^^ one ^^ G.i (Binary (I32 I32Op.And)) ^^ G.i (Test (I32 I32Op.Eqz)) ^^
              G.if_ (ValBlockType (Some I32Type))
                (square_recurse_with_shifted G.nop)
                (get_n ^^
                 square_recurse_with_shifted (sanitize_word_result ty) ^^
                 mul)))
    in pow ()

end (* UnboxedSmallWord *)

module ReadBuf = struct
  (*
  Combinators to safely read from a dynamic buffer.

  We represent a buffer by a pointer to two words in memory (usually allocated
  on the shadow stack): The first is a pointer to the current position of the buffer,
  the second one a pointer to the end (to check out-of-bounds).

  Code that reads from this buffer will update the former, i.e. it is mutable.

  The format is compatible with C (pointer to a struct) and avoids the need for the
  multi-value extension that we used before to return both parse result _and_
  updated pointer.

  All pointers here are unskewed!

  This module is mostly for serialization, but because there are bits of
  serialization code in the BigNumType implementations, we put it here.
  *)

  let get_ptr get_buf =
    get_buf ^^ G.i (Load {ty = I32Type; align = 2; offset = 0l; sz = None})
  let get_end get_buf =
    get_buf ^^ G.i (Load {ty = I32Type; align = 2; offset = Heap.word_size; sz = None})
  let set_ptr get_buf new_val =
    get_buf ^^ new_val ^^ G.i (Store {ty = I32Type; align = 2; offset = 0l; sz = None})
  let set_end get_buf new_val =
    get_buf ^^ new_val ^^ G.i (Store {ty = I32Type; align = 2; offset = Heap.word_size; sz = None})
  let set_size get_buf get_size =
    set_end get_buf
      (get_ptr get_buf ^^ get_size ^^ G.i (Binary (Wasm.Values.I32 I32Op.Add)))

  let alloc env f = Stack.with_words env "buf" 2l f

  let advance get_buf get_delta =
    set_ptr get_buf (get_ptr get_buf ^^ get_delta ^^ G.i (Binary (Wasm.Values.I32 I32Op.Add)))

  let read_leb128 env get_buf =
    get_buf ^^ E.call_import env "rts" "read_u32_of_leb128"

  let read_sleb128 env get_buf =
    get_buf ^^ E.call_import env "rts" "read_i32_of_sleb128"

  let check_space env get_buf get_delta =
    get_delta ^^
    get_end get_buf ^^ get_ptr get_buf ^^ G.i (Binary (Wasm.Values.I32 I32Op.Sub)) ^^
    G.i (Compare (Wasm.Values.I32 I64Op.LeU)) ^^
    E.else_trap_with env "IDL error: out of bounds read"

  let is_empty env get_buf =
    get_end get_buf ^^ get_ptr get_buf ^^
    G.i (Compare (Wasm.Values.I32 I64Op.Eq))

  let read_byte env get_buf =
    check_space env get_buf (compile_unboxed_const 1l) ^^
    get_ptr get_buf ^^
    G.i (Load {ty = I32Type; align = 0; offset = 0l; sz = Some (Wasm.Memory.Pack8, Wasm.Memory.ZX)}) ^^
    advance get_buf (compile_unboxed_const 1l)

  let read_word16 env get_buf =
    check_space env get_buf (compile_unboxed_const 2l) ^^
    get_ptr get_buf ^^
    G.i (Load {ty = I32Type; align = 0; offset = 0l; sz = Some (Wasm.Memory.Pack16, Wasm.Memory.ZX)}) ^^
    advance get_buf (compile_unboxed_const 2l)

  let read_word32 env get_buf =
    check_space env get_buf (compile_unboxed_const 4l) ^^
    get_ptr get_buf ^^
    G.i (Load {ty = I32Type; align = 0; offset = 0l; sz = None}) ^^
    advance get_buf (compile_unboxed_const 4l)

  let read_word64 env get_buf =
    check_space env get_buf (compile_unboxed_const 8l) ^^
    get_ptr get_buf ^^
    G.i (Load {ty = I64Type; align = 0; offset = 0l; sz = None}) ^^
    advance get_buf (compile_unboxed_const 8l)

  let read_blob env get_buf get_len =
    check_space env get_buf get_len ^^
    (* Already has destination address on the stack *)
    get_ptr get_buf ^^
    get_len ^^
    Heap.memcpy env ^^
    advance get_buf get_len

end (* Buf *)


type comparator = Lt | Le | Ge | Gt

module type BigNumType =
sig
  (* word from SR.Vanilla, trapping, unsigned semantics *)
  val to_word32 : E.t -> G.t
  val to_word64 : E.t -> G.t

  (* word from SR.Vanilla, lossy, raw bits *)
  val truncate_to_word32 : E.t -> G.t
  val truncate_to_word64 : E.t -> G.t

  (* unsigned word to SR.Vanilla *)
  val from_word32 : E.t -> G.t
  val from_word64 : E.t -> G.t

  (* signed word to SR.Vanilla *)
  val from_signed_word32 : E.t -> G.t
  val from_signed_word64 : E.t -> G.t

  (* buffers *)
  (* given a numeric object on stack (vanilla),
     push the number (i32) of bytes necessary
     to externalize the numeric object *)
  val compile_data_size_signed : E.t -> G.t
  val compile_data_size_unsigned : E.t -> G.t
  (* given on stack
     - numeric object (vanilla, TOS)
     - data buffer
    store the binary representation of the numeric object into the data buffer,
    and push the number (i32) of bytes stored onto the stack
   *)
  val compile_store_to_data_buf_signed : E.t -> G.t
  val compile_store_to_data_buf_unsigned : E.t -> G.t
  (* given a ReadBuf on stack, consume bytes from it,
     deserializing to a numeric object
     and leave it on the stack (vanilla).
     The boolean argument is true if the value to be read is signed.
   *)
  val compile_load_from_data_buf : E.t -> bool -> G.t

  (* literals *)
  val compile_lit : E.t -> Big_int.big_int -> G.t

  (* arithmetic *)
  val compile_abs : E.t -> G.t
  val compile_neg : E.t -> G.t
  val compile_add : E.t -> G.t
  val compile_signed_sub : E.t -> G.t
  val compile_unsigned_sub : E.t -> G.t
  val compile_mul : E.t -> G.t
  val compile_signed_div : E.t -> G.t
  val compile_signed_mod : E.t -> G.t
  val compile_unsigned_div : E.t -> G.t
  val compile_unsigned_rem : E.t -> G.t
  val compile_unsigned_pow : E.t -> G.t

  (* comparisons *)
  val compile_eq : E.t -> G.t
  val compile_is_negative : E.t -> G.t
  val compile_relop : E.t -> comparator -> G.t

  (* representation checks *)
  (* given a numeric object on the stack as skewed pointer, check whether
     it can be faithfully stored in N bits, including a leading sign bit
     leaves boolean result on the stack
     N must be 2..64
   *)
  val fits_signed_bits : E.t -> int -> G.t
  (* given a numeric object on the stack as skewed pointer, check whether
     it can be faithfully stored in N unsigned bits
     leaves boolean result on the stack
     N must be 1..64
   *)
  val fits_unsigned_bits : E.t -> int -> G.t
end

let i64op_from_relop = function
  | Lt -> I64Op.LtS
  | Le -> I64Op.LeS
  | Ge -> I64Op.GeS
  | Gt -> I64Op.GtS

let name_from_relop = function
  | Lt -> "B_lt"
  | Le -> "B_le"
  | Ge -> "B_ge"
  | Gt -> "B_gt"

(* helper, measures the dynamics of the unsigned i32, returns (32 - effective bits) *)
let unsigned_dynamics get_x =
  get_x ^^
  G.i (Unary (Wasm.Values.I32 I32Op.Clz))

(* helper, measures the dynamics of the signed i32, returns (32 - effective bits) *)
let signed_dynamics get_x =
  get_x ^^ compile_shl_const 1l ^^
  get_x ^^
  G.i (Binary (Wasm.Values.I32 I32Op.Xor)) ^^
  G.i (Unary (Wasm.Values.I32 I32Op.Clz))

module I32Leb = struct
  let compile_size dynamics get_x =
    get_x ^^ G.if_ (ValBlockType (Some I32Type))
      begin
        compile_unboxed_const 38l ^^
        dynamics get_x ^^
        G.i (Binary (Wasm.Values.I32 I32Op.Sub)) ^^
        compile_divU_const 7l
      end
      compile_unboxed_one

  let compile_leb128_size get_x = compile_size unsigned_dynamics get_x
  let compile_sleb128_size get_x = compile_size signed_dynamics get_x

  let compile_store_to_data_buf_unsigned env get_x get_buf =
    get_x ^^ get_buf ^^ E.call_import env "rts" "leb128_encode" ^^
    compile_leb128_size get_x

  let compile_store_to_data_buf_signed env get_x get_buf =
    get_x ^^ get_buf ^^ E.call_import env "rts" "sleb128_encode" ^^
    compile_sleb128_size get_x

end

module MakeCompact (Num : BigNumType) : BigNumType = struct

  (* Compact BigNums are a representation of signed 31-bit bignums (of the
     underlying boxed representation `Num`), that fit into an i32.
     The bits are encoded as

       ┌──────────┬───┬──────┐
       │ mantissa │ 0 │ sign │  = i32
       └──────────┴───┴──────┘
     The 2nd LSBit makes unboxed bignums distinguishable from boxed ones,
     the latter always being skewed pointers.

     By a right rotation one obtains the signed (right-zero-padded) representation,
     which is usable for arithmetic (e.g. addition-like operators). For some
     operations (e.g. multiplication) the second argument needs to be furthermore
     right-shifted. Similarly, for division the result must be left-shifted.

     Generally all operations begin with checking whether both arguments are
     already in unboxed form. If so, the arithmetic can be performed in machine
     registers (fast path). Otherwise one or both arguments need boxing and the
     arithmetic needs to be carried out on the underlying boxed representation
     (slow path).

     The result appears as a boxed number in the latter case, so a check is
     performed for possible compactification of the result. Conversely in the
     former case the 64-bit result is either compactable or needs to be boxed.

     Manipulation of the result is unnecessary for the comparison predicates.

     For the `pow` operation the check that both arguments are unboxed is not
     sufficient. Here we count and multiply effective bitwidths to figure out
     whether the operation will overflow 64 bits, and if so, we fall back to the
     slow path.
   *)

  (* TODO: There is some unnecessary result shifting when the div result needs
     to be boxed. Is this possible at all to happen? With (/-1) maybe! *)

  (* TODO: Does the result of the rem/mod fast path ever needs boxing? *)

  (* examine the skewed pointer and determine if number fits into 31 bits *)
  let fits_in_vanilla env = Num.fits_signed_bits env 31

  (* input right-padded with 0 *)
  let extend =
    compile_rotr_const 1l

  (* input right-padded with 0 *)
  let extend64 =
    extend ^^
    G.i (Convert (Wasm.Values.I64 I64Op.ExtendSI32))

  (* predicate for i64 signed value, checking whether
     the compact representation is viable;
     bits should be 31 for right-aligned
     and 32 for right-0-padded values *)
  let speculate_compact64 bits =
    compile_shl64_const 1L ^^
    G.i (Binary (Wasm.Values.I64 I64Op.Xor)) ^^
    compile_const_64 Int64.(shift_left minus_one bits) ^^
    G.i (Binary (Wasm.Values.I64 I64Op.And)) ^^
    G.i (Test (Wasm.Values.I64 I64Op.Eqz))

  (* input is right-padded with 0 *)
  let compress32 = compile_rotl_const 1l

  (* input is right-padded with 0
     precondition: upper 32 bits must be same as 32-bit sign,
     i.e. speculate_compact64 is valid
   *)
  let compress64 =
    G.i (Convert (Wasm.Values.I32 I32Op.WrapI64)) ^^
    compress32

  let speculate_compact =
    compile_shl_const 1l ^^
    G.i (Binary (Wasm.Values.I32 I32Op.Xor)) ^^
    compile_unboxed_const Int32.(shift_left minus_one 31) ^^
    G.i (Binary (Wasm.Values.I32 I32Op.And)) ^^
    G.i (Test (Wasm.Values.I32 I32Op.Eqz))

  let compress =
    compile_shl_const 1l ^^ compress32

  (* creates a boxed bignum from a right-0-padded signed i64 *)
  let box64 env = compile_shrS64_const 1L ^^ Num.from_signed_word64 env

  (* creates a boxed bignum from an unboxed 31-bit signed (and rotated) value *)
  let extend_and_box64 env = extend64 ^^ box64 env

  (* check if both arguments are compact (i.e. unboxed),
     if so, promote to signed i64 (with right bit (i.e. LSB) zero) and perform the fast path.
     Otherwise make sure that both arguments are in heap representation,
     and run the slow path on them.
     In both cases bring the results into normal form.
   *)
  let try_unbox2 name fast slow env =
    Func.share_code2 env name (("a", I32Type), ("b", I32Type)) [I32Type]
      (fun env get_a get_b ->
        let set_res, get_res = new_local env "res" in
        let set_res64, get_res64 = new_local64 env "res64" in
        get_a ^^ get_b ^^
        BitTagged.if_both_unboxed env (ValBlockType (Some I32Type))
          begin
            get_a ^^ extend64 ^^
            get_b ^^ extend64 ^^
            fast env ^^ set_res64 ^^
            get_res64 ^^ get_res64 ^^ speculate_compact64 32 ^^
            G.if_ (ValBlockType (Some I32Type))
              (get_res64 ^^ compress64)
              (get_res64 ^^ box64 env)
          end
          begin
            get_a ^^ BitTagged.if_unboxed env (ValBlockType (Some I32Type))
              (get_a ^^ extend_and_box64 env)
              get_a ^^
            get_b ^^ BitTagged.if_unboxed env (ValBlockType (Some I32Type))
              (get_b ^^ extend_and_box64 env)
              get_b ^^
            slow env ^^ set_res ^^ get_res ^^
            fits_in_vanilla env ^^
            G.if_ (ValBlockType (Some I32Type))
              (get_res ^^ Num.truncate_to_word32 env ^^ compress)
              get_res
          end)

  let compile_add = try_unbox2 "B_add" BoxedWord64.compile_add Num.compile_add

  let adjust_arg2 code env = compile_shrS64_const 1L ^^ code env
  let adjust_result code env = code env ^^ compile_shl64_const 1L

  let compile_mul = try_unbox2 "B_mul" (adjust_arg2 BoxedWord64.compile_mul) Num.compile_mul
  let compile_signed_sub = try_unbox2 "B+sub" BoxedWord64.compile_signed_sub Num.compile_signed_sub
  let compile_signed_div = try_unbox2 "B+div" (adjust_result BoxedWord64.compile_signed_div) Num.compile_signed_div
  let compile_signed_mod = try_unbox2 "B_mod" BoxedWord64.compile_signed_mod Num.compile_signed_mod
  let compile_unsigned_div = try_unbox2 "B_div" (adjust_result BoxedWord64.compile_unsigned_div) Num.compile_unsigned_div
  let compile_unsigned_rem = try_unbox2 "B_rem" BoxedWord64.compile_unsigned_rem Num.compile_unsigned_rem
  let compile_unsigned_sub = try_unbox2 "B_sub" BoxedWord64.compile_unsigned_sub Num.compile_unsigned_sub

  let compile_unsigned_pow env =
    Func.share_code2 env "B_pow" (("a", I32Type), ("b", I32Type)) [I32Type]
    (fun env get_a get_b ->
    let set_res, get_res = new_local env "res" in
    let set_a64, get_a64 = new_local64 env "a64" in
    let set_b64, get_b64 = new_local64 env "b64" in
    let set_res64, get_res64 = new_local64 env "res64" in
    get_a ^^ get_b ^^
    BitTagged.if_both_unboxed env (ValBlockType (Some I32Type))
      begin
        (* estimate bitcount of result: `bits(a) * b <= 65` guarantees
           the absence of overflow in 64-bit arithmetic *)
        get_a ^^ extend64 ^^ set_a64 ^^ compile_const_64 64L ^^
        get_a64 ^^ get_a64 ^^ compile_shrS64_const 1L ^^
        G.i (Binary (Wasm.Values.I64 I64Op.Xor)) ^^
        G.i (Unary (Wasm.Values.I64 I64Op.Clz)) ^^ G.i (Binary (Wasm.Values.I64 I64Op.Sub)) ^^
        get_b ^^ extend64 ^^ set_b64 ^^ get_b64 ^^
        G.i (Binary (Wasm.Values.I64 I64Op.Mul)) ^^
        compile_const_64 130L ^^ G.i (Compare (Wasm.Values.I64 I64Op.LeU)) ^^
        G.if_ (ValBlockType (Some I32Type))
          begin
            get_a64 ^^ compile_shrS64_const 1L ^^
            get_b64 ^^ compile_shrS64_const 1L ^^
            BoxedWord64.compile_unsigned_pow env ^^
            compile_shl64_const 1L ^^ set_res64 ^^
            get_res64 ^^ get_res64 ^^ speculate_compact64 32 ^^
            G.if_ (ValBlockType (Some I32Type))
              (get_res64 ^^ compress64)
              (get_res64 ^^ box64 env)
          end
          begin
            get_a64 ^^ box64 env ^^
            get_b64 ^^ box64 env ^^
            Num.compile_unsigned_pow env ^^ set_res ^^ get_res ^^
            fits_in_vanilla env ^^
            G.if_ (ValBlockType (Some I32Type))
              (get_res ^^ Num.truncate_to_word32 env ^^ compress)
              get_res
          end
      end
      begin
        get_a ^^ BitTagged.if_unboxed env (ValBlockType (Some I32Type))
          (get_a ^^ extend_and_box64 env)
          get_a ^^
        get_b ^^ BitTagged.if_unboxed env (ValBlockType (Some I32Type))
          (get_b ^^ extend_and_box64 env)
          get_b ^^
        Num.compile_unsigned_pow env ^^ set_res ^^ get_res ^^
        fits_in_vanilla env ^^
        G.if_ (ValBlockType (Some I32Type))
          (get_res ^^ Num.truncate_to_word32 env ^^ compress)
          get_res
      end)

  let compile_is_negative env =
    let set_n, get_n = new_local env "n" in
    set_n ^^ get_n ^^
    BitTagged.if_unboxed env (ValBlockType (Some I32Type))
      (get_n ^^ compile_bitand_const 1l)
      (get_n ^^ Num.compile_is_negative env)

  let compile_lit env = function
    | n when Big_int.(is_int_big_int n
                      && int_of_big_int n >= Int32.(to_int (shift_left 3l 30))
                      && int_of_big_int n <= Int32.(to_int (shift_right_logical minus_one 2))) ->
      let i = Int32.of_int (Big_int.int_of_big_int n) in
      compile_unboxed_const Int32.(logor (shift_left i 2) (shift_right_logical i 31))
    | n -> Num.compile_lit env n

  let compile_neg env =
    Func.share_code1 env "B_neg" ("n", I32Type) [I32Type] (fun env get_n ->
      get_n ^^ BitTagged.if_unboxed env (ValBlockType (Some I32Type))
        begin
          get_n ^^ compile_unboxed_one ^^
          G.i (Compare (Wasm.Values.I32 I32Op.Eq)) ^^
          G.if_ (ValBlockType (Some I32Type))
            (compile_lit env (Big_int.big_int_of_int 0x40000000))
            begin
              compile_unboxed_zero ^^
              get_n ^^ extend ^^
              G.i (Binary (Wasm.Values.I32 I32Op.Sub)) ^^
              compress32
            end
        end
        (get_n ^^ Num.compile_neg env)
    )

  let try_comp_unbox2 name fast slow env =
    Func.share_code2 env name (("a", I32Type), ("b", I32Type)) [I32Type]
      (fun env get_a get_b ->
        get_a ^^ get_b ^^
        BitTagged.if_both_unboxed env (ValBlockType (Some I32Type))
          begin
            get_a ^^ extend64 ^^
            get_b ^^ extend64 ^^
            fast env
          end
          begin
            get_a ^^ BitTagged.if_unboxed env (ValBlockType (Some I32Type))
              (get_a ^^ extend_and_box64 env)
              get_a ^^
            get_b ^^ BitTagged.if_unboxed env (ValBlockType (Some I32Type))
              (get_b ^^ extend_and_box64 env)
              get_b ^^
            slow env
          end)

  let compile_eq = try_comp_unbox2 "B_eq" BoxedWord64.compile_eq Num.compile_eq
  let compile_relop env bigintop =
    try_comp_unbox2 (name_from_relop bigintop)
      (fun env' -> BoxedWord64.compile_relop env' (i64op_from_relop bigintop))
      (fun env' -> Num.compile_relop env' bigintop)
      env

  let try_unbox iN fast slow env =
    let set_a, get_a = new_local env "a" in
    set_a ^^ get_a ^^
    BitTagged.if_unboxed env (ValBlockType (Some iN))
      (get_a ^^ fast env)
      (get_a ^^ slow env)

  let fits_unsigned_bits env n =
    try_unbox I32Type
      (fun _ -> match n with
                | _ when n >= 31 -> G.i Drop ^^ Bool.lit true
                | 30 -> compile_bitand_const 1l ^^ G.i (Test (Wasm.Values.I32 I32Op.Eqz))
                | _ ->
                  compile_bitand_const
                    Int32.(logor 1l (shift_left minus_one (n + 2))) ^^
                  G.i (Test (Wasm.Values.I32 I32Op.Eqz)))
      (fun env -> Num.fits_unsigned_bits env n)
      env

  let fits_signed_bits env n =
    let set_a, get_a = new_local env "a" in
    try_unbox I32Type
      (fun _ -> match n with
                | _ when n >= 31 -> G.i Drop ^^ Bool.lit true
                | 30 ->
                  set_a ^^ get_a ^^ compile_shrU_const 31l ^^
                    get_a ^^ compile_bitand_const 1l ^^
                    G.i (Binary (Wasm.Values.I32 I32Op.And)) ^^
                    G.i (Test (Wasm.Values.I32 I32Op.Eqz))
                | _ -> set_a ^^ get_a ^^ compile_rotr_const 1l ^^ set_a ^^
                       get_a ^^ get_a ^^ compile_shrS_const 1l ^^
                       G.i (Binary (Wasm.Values.I32 I32Op.Xor)) ^^
                       compile_bitand_const
                         Int32.(shift_left minus_one n) ^^
                       G.i (Test (Wasm.Values.I32 I32Op.Eqz)))
      (fun env -> Num.fits_signed_bits env n)
      env

  let compile_abs env =
    try_unbox I32Type
      begin
        fun _ ->
        let set_a, get_a = new_local env "a" in
        set_a ^^ get_a ^^
        compile_bitand_const 1l ^^
        G.if_ (ValBlockType (Some I32Type))
          begin
            get_a ^^
            compile_unboxed_one ^^ (* i.e. -(2**30) == -1073741824 *)
            G.i (Compare (Wasm.Values.I32 I32Op.Eq)) ^^
            G.if_ (ValBlockType (Some I32Type))
              (compile_unboxed_const 0x40000000l ^^ Num.from_word32 env) (* is non-representable *)
              begin
                get_a ^^
                compile_unboxed_const Int32.minus_one ^^ G.i (Binary (Wasm.Values.I32 I32Op.Xor)) ^^
                compile_unboxed_const 2l ^^ G.i (Binary (Wasm.Values.I32 I32Op.Add))
              end
          end
          get_a
      end
      Num.compile_abs
      env

  let compile_load_from_data_buf env signed =
    let set_res, get_res = new_local env "res" in
    Num.compile_load_from_data_buf env signed ^^
    set_res ^^
    get_res ^^ fits_in_vanilla env ^^
    G.if_ (ValBlockType (Some I32Type))
      (get_res ^^ Num.truncate_to_word32 env ^^ compress)
      get_res

  let compile_store_to_data_buf_unsigned env =
    let set_x, get_x = new_local env "x" in
    let set_buf, get_buf = new_local env "buf" in
    set_x ^^ set_buf ^^
    get_x ^^
    try_unbox I32Type
      (fun env ->
        extend ^^ compile_shrS_const 1l ^^ set_x ^^
        I32Leb.compile_store_to_data_buf_unsigned env get_x get_buf
      )
      (fun env -> G.i Drop ^^ get_buf ^^ get_x ^^ Num.compile_store_to_data_buf_unsigned env)
      env

  let compile_store_to_data_buf_signed env =
    let set_x, get_x = new_local env "x" in
    let set_buf, get_buf = new_local env "buf" in
    set_x ^^ set_buf ^^
    get_x ^^
    try_unbox I32Type
      (fun env ->
        extend ^^ compile_shrS_const 1l ^^ set_x ^^
        I32Leb.compile_store_to_data_buf_signed env get_x get_buf
      )
      (fun env -> G.i Drop ^^ get_buf ^^ get_x ^^ Num.compile_store_to_data_buf_signed env)
      env

  let compile_data_size_unsigned env =
    try_unbox I32Type
      (fun _ ->
        let set_x, get_x = new_local env "x" in
        extend ^^ compile_shrS_const 1l ^^ set_x ^^
        I32Leb.compile_leb128_size get_x
      )
      (fun env -> Num.compile_data_size_unsigned env)
      env

  let compile_data_size_signed env =
    try_unbox I32Type
      (fun _ ->
        let set_x, get_x = new_local env "x" in
        extend ^^ compile_shrS_const 1l ^^ set_x ^^
        I32Leb.compile_sleb128_size get_x
      )
      (fun env -> Num.compile_data_size_unsigned env)
      env

  let from_signed_word32 env =
    let set_a, get_a = new_local env "a" in
    set_a ^^ get_a ^^ get_a ^^
    speculate_compact ^^
    G.if_ (ValBlockType (Some I32Type))
      (get_a ^^ compress)
      (get_a ^^ Num.from_signed_word32 env)

  let from_signed_word64 env =
    let set_a, get_a = new_local64 env "a" in
    set_a ^^ get_a ^^ get_a ^^
    speculate_compact64 31 ^^
    G.if_ (ValBlockType (Some I32Type))
      (get_a ^^ compile_shl64_const 1L ^^ compress64)
      (get_a ^^ Num.from_signed_word64 env)

  let from_word32 env =
    let set_a, get_a = new_local env "a" in
    set_a ^^ get_a ^^
    compile_unboxed_const Int32.(shift_left minus_one 30) ^^
    G.i (Binary (Wasm.Values.I32 I32Op.And)) ^^
    G.i (Test (Wasm.Values.I32 I32Op.Eqz)) ^^
    G.if_ (ValBlockType (Some I32Type))
      (get_a ^^ compile_rotl_const 2l)
      (get_a ^^ G.i (Convert (Wasm.Values.I64 I64Op.ExtendUI32)) ^^ Num.from_word64 env)

  let from_word64 env =
    let set_a, get_a = new_local64 env "a" in
    set_a ^^ get_a ^^
    compile_const_64 Int64.(shift_left minus_one 30) ^^
    G.i (Binary (Wasm.Values.I64 I64Op.And)) ^^
    G.i (Test (Wasm.Values.I64 I64Op.Eqz)) ^^
    G.if_ (ValBlockType (Some I32Type))
      (get_a ^^ G.i (Convert (Wasm.Values.I32 I32Op.WrapI64)) ^^ compile_rotl_const 2l)
      (get_a ^^ Num.from_word64 env)

  let truncate_to_word64 env =
    let set_a, get_a = new_local env "a" in
    set_a ^^ get_a ^^
    BitTagged.if_unboxed env (ValBlockType (Some I64Type))
      begin
        get_a ^^ extend ^^ compile_unboxed_one ^^
        G.i (Binary (Wasm.Values.I32 I32Op.ShrS)) ^^
        G.i (Convert (Wasm.Values.I64 I64Op.ExtendSI32))
      end
      (get_a ^^ Num.truncate_to_word64 env)
  let truncate_to_word32 env =
    let set_a, get_a = new_local env "a" in
    set_a ^^ get_a ^^
    BitTagged.if_unboxed env (ValBlockType (Some I32Type))
      (get_a ^^ extend ^^ compile_unboxed_one ^^ G.i (Binary (Wasm.Values.I32 I32Op.ShrS)))
      (get_a ^^ Num.truncate_to_word32 env)

  let to_word64 env =
    let set_a, get_a = new_local env "a" in
    set_a ^^ get_a ^^
    BitTagged.if_unboxed env (ValBlockType (Some I64Type))
      (get_a ^^ extend64 ^^ compile_shrS64_const 1L)
      (get_a ^^ Num.to_word64 env)
  let to_word32 env =
    let set_a, get_a = new_local env "a" in
    set_a ^^ get_a ^^
    BitTagged.if_unboxed env (ValBlockType (Some I32Type))
      (get_a ^^ extend ^^ compile_unboxed_one ^^ G.i (Binary (Wasm.Values.I32 I32Op.ShrS)))
      (get_a ^^ Num.to_word32 env)
end

module BigNumLibtommath : BigNumType = struct

  let to_word32 env = E.call_import env "rts" "bigint_to_word32_trap"
  let to_word64 env = E.call_import env "rts" "bigint_to_word64_trap"

  let truncate_to_word32 env = E.call_import env "rts" "bigint_to_word32_wrap"
  let truncate_to_word64 env = E.call_import env "rts" "bigint_to_word64_wrap"

  let from_word32 env = E.call_import env "rts" "bigint_of_word32"
  let from_word64 env = E.call_import env "rts" "bigint_of_word64"
  let from_signed_word32 env = E.call_import env "rts" "bigint_of_word32_signed"
  let from_signed_word64 env = E.call_import env "rts" "bigint_of_word64_signed"

  let compile_data_size_unsigned env = E.call_import env "rts" "bigint_leb128_size"
  let compile_data_size_signed env = E.call_import env "rts" "bigint_sleb128_size"

  let compile_store_to_data_buf_unsigned env =
    let (set_buf, get_buf) = new_local env "buf" in
    let (set_n, get_n) = new_local env "n" in
    set_n ^^ set_buf ^^
    get_n ^^ get_buf ^^ E.call_import env "rts" "bigint_leb128_encode" ^^
    get_n ^^ E.call_import env "rts" "bigint_leb128_size"
  let compile_store_to_data_buf_signed env =
    let (set_buf, get_buf) = new_local env "buf" in
    let (set_n, get_n) = new_local env "n" in
    set_n ^^ set_buf ^^
    get_n ^^ get_buf ^^ E.call_import env "rts" "bigint_sleb128_encode" ^^
    get_n ^^ E.call_import env "rts" "bigint_sleb128_size"

  let compile_load_from_data_buf env = function
    | false -> E.call_import env "rts" "bigint_leb128_decode"
    | true -> E.call_import env "rts" "bigint_sleb128_decode"

  let compile_lit env n =
    let limb_size = 31 in
    let twoto = Big_int.power_int_positive_int 2 limb_size in

    compile_unboxed_const 0l ^^
    E.call_import env "rts" "bigint_of_word32" ^^

    let rec go n =
      if Big_int.sign_big_int n = 0
      then G.nop
      else
        let (a, b) = Big_int.quomod_big_int n twoto in
        go a ^^
        compile_unboxed_const (Int32.of_int limb_size) ^^
        E.call_import env "rts" "bigint_lsh" ^^
        compile_unboxed_const (Big_int.int32_of_big_int b) ^^
        E.call_import env "rts" "bigint_of_word32" ^^
        E.call_import env "rts" "bigint_add" in

    go (Big_int.abs_big_int n) ^^

    if Big_int.sign_big_int n < 0
      then E.call_import env "rts" "bigint_neg"
      else G.nop

  let assert_nonneg env =
    Func.share_code1 env "assert_nonneg" ("n", I32Type) [I32Type] (fun env get_n ->
      get_n ^^
      E.call_import env "rts" "bigint_isneg" ^^
      E.then_trap_with env "Natural subtraction underflow" ^^
      get_n
    )

  let compile_abs env = E.call_import env "rts" "bigint_abs"
  let compile_neg env = E.call_import env "rts" "bigint_neg"
  let compile_add env = E.call_import env "rts" "bigint_add"
  let compile_mul env = E.call_import env "rts" "bigint_mul"
  let compile_signed_sub env = E.call_import env "rts" "bigint_sub"
  let compile_signed_div env = E.call_import env "rts" "bigint_div"
  let compile_signed_mod env = E.call_import env "rts" "bigint_rem"
  let compile_unsigned_sub env = E.call_import env "rts" "bigint_sub" ^^ assert_nonneg env
  let compile_unsigned_rem env = E.call_import env "rts" "bigint_rem"
  let compile_unsigned_div env = E.call_import env "rts" "bigint_div"
  let compile_unsigned_pow env = E.call_import env "rts" "bigint_pow"

  let compile_eq env = E.call_import env "rts" "bigint_eq"
  let compile_is_negative env = E.call_import env "rts" "bigint_isneg"
  let compile_relop env = function
      | Lt -> E.call_import env "rts" "bigint_lt"
      | Le -> E.call_import env "rts" "bigint_le"
      | Ge -> E.call_import env "rts" "bigint_ge"
      | Gt -> E.call_import env "rts" "bigint_gt"

  let fits_signed_bits env bits =
    E.call_import env "rts" "bigint_2complement_bits" ^^
    compile_unboxed_const (Int32.of_int bits) ^^
    G.i (Compare (Wasm.Values.I32 I32Op.LeU))
  let fits_unsigned_bits env bits =
    E.call_import env "rts" "bigint_count_bits" ^^
    compile_unboxed_const (Int32.of_int bits) ^^
    G.i (Compare (Wasm.Values.I32 I32Op.LeU))

end (* BigNumLibtommath *)

module BigNum = MakeCompact(BigNumLibtommath)

(* Primitive functions *)
module Prim = struct
  (* The Word8 and Word16 bits sit in the MSBs of the i32, in this manner
     we can perform almost all operations, with the exception of
     - Mul (needs shr of one operand)
     - Shr (needs masking of result)
     - Rot (needs duplication into LSBs, masking of amount and masking of result)
     - ctz (needs shr of operand or sub from result)

     Both Word8/16 easily fit into the vanilla stackrep, so no boxing is necessary.
     This MSB-stored schema is also essentially what the interpreter is using.
  *)
  let prim_word32toNat env = BigNum.from_word32 env
  let prim_shiftWordNtoUnsigned env b =
    compile_shrU_const b ^^
    prim_word32toNat env
  let prim_word32toInt env = BigNum.from_signed_word32 env
  let prim_shiftWordNtoSigned env b =
    compile_shrS_const b ^^
    prim_word32toInt env
  let prim_intToWord32 env = BigNum.truncate_to_word32 env
  let prim_shiftToWordN env b =
    prim_intToWord32 env ^^
    UnboxedSmallWord.shift_leftWordNtoI32 b
end (* Prim *)

module Object = struct
  (* An object has the following heap layout:

    ┌─────┬──────────┬─────────────┬─────────────┬───┐
    │ tag │ n_fields │ field_hash1 │ field_data1 │ … │
    └─────┴──────────┴─────────────┴─────────────┴───┘

    The field_data for immutable fields simply point to the value.

    The field_data for mutable fields are pointers to either an ObjInd, or a
    MutBox (they have the same layout). This indirection is a consequence of
    how we compile object literals with `await` instructions, as these mutable
    fields need to be able to alias local mutal variables.

    We could alternatively switch to an allocate-first approach in the
    await-translation of objects, and get rid of this indirection.
  *)

  let header_size = Int32.add Tagged.header_size 1l

  (* Number of object fields *)
  let size_field = Int32.add Tagged.header_size 0l

  module FieldEnv = Env.Make(String)

  (* This is for non-recursive objects, i.e. ObjNewE *)
  (* The instructions in the field already create the indirection if needed *)
  let lit_raw env fs =
    let name_pos_map =
      fs |>
      (* We could store only public fields in the object, but
         then we need to allocate separate boxes for the non-public ones:
         List.filter (fun (_, vis, f) -> vis.it = Public) |>
      *)
      List.map (fun (n,_) -> (Mo_types.Hash.hash n, n)) |>
      List.sort compare |>
      List.mapi (fun i (_h,n) -> (n,Int32.of_int i)) |>
      List.fold_left (fun m (n,i) -> FieldEnv.add n i m) FieldEnv.empty in

     let sz = Int32.of_int (FieldEnv.cardinal name_pos_map) in

     (* Allocate memory *)
     let (set_ri, get_ri, ri) = new_local_ env I32Type "obj" in
     Heap.alloc env (Int32.add header_size (Int32.mul 2l sz)) ^^
     set_ri ^^

     (* Set tag *)
     get_ri ^^
     Tagged.store Tagged.Object ^^

     (* Set size *)
     get_ri ^^
     compile_unboxed_const sz ^^
     Heap.store_field size_field ^^

     let hash_position env n =
         let i = FieldEnv.find n name_pos_map in
         Int32.add header_size (Int32.mul 2l i) in
     let field_position env n =
         let i = FieldEnv.find n name_pos_map in
         Int32.add header_size (Int32.add (Int32.mul 2l i) 1l) in

     (* Write all the fields *)
     let init_field (name, mk_is) : G.t =
       (* Write the hash *)
       get_ri ^^
       compile_unboxed_const (Mo_types.Hash.hash name) ^^
       Heap.store_field (hash_position env name) ^^
       (* Write the pointer to the indirection *)
       get_ri ^^
       mk_is () ^^
       Heap.store_field (field_position env name)
     in
     G.concat_map init_field fs ^^

     (* Return the pointer to the object *)
     get_ri

  (* Returns a pointer to the object field (without following the indirection) *)
  let idx_hash_raw env =
    Func.share_code2 env "obj_idx" (("x", I32Type), ("hash", I32Type)) [I32Type] (fun env get_x get_hash ->
      let (set_f, get_f) = new_local env "f" in
      let (set_r, get_r) = new_local env "r" in

      get_x ^^
      Heap.load_field size_field ^^
      (* Linearly scan through the fields (binary search can come later) *)
      from_0_to_n env (fun get_i ->
        get_i ^^
        compile_mul_const 2l ^^
        compile_add_const header_size ^^
        compile_mul_const Heap.word_size  ^^
        get_x ^^
        G.i (Binary (Wasm.Values.I32 I32Op.Add)) ^^
        set_f ^^

        get_f ^^
        Heap.load_field 0l ^^ (* the hash field *)
        get_hash ^^
        G.i (Compare (Wasm.Values.I32 I32Op.Eq)) ^^
        G.if_ (ValBlockType None)
          ( get_f ^^
            compile_add_const Heap.word_size ^^
            set_r
          ) G.nop
      ) ^^
      get_r
    )

  (* Returns a pointer to the object field (possibly following the indirection) *)
  let idx_hash env indirect =
    if indirect
    then Func.share_code2 env "obj_idx_ind" (("x", I32Type), ("hash", I32Type)) [I32Type] (fun env get_x get_hash ->
      get_x ^^ get_hash ^^
      idx_hash_raw env ^^
      load_ptr ^^ compile_add_const Heap.word_size
    )
    else idx_hash_raw env

  (* Determines whether the field is mutable (and thus needs an indirection) *)
  let is_mut_field env obj_type s =
    (* TODO: remove try once array and text accessors are separated *)
    try
      let _, fields = Type.as_obj_sub [s] obj_type in
      Type.is_mut (Type.lookup_val_field s fields)
    with Invalid_argument _ -> false

  let idx env obj_type name =
    compile_unboxed_const (Mo_types.Hash.hash name) ^^
    idx_hash env (is_mut_field env obj_type name)

  let load_idx env obj_type f =
    idx env obj_type f ^^
    load_ptr

end (* Object *)


module Iterators = struct
  (*
    We have to synthesize iterators for various functions in Text and Array.
    This is the common code for that.
  *)

  (*
  Parameters:
    name: base name for this built-in function (needs to be unique)
    mk_stop get_x: counter value at which to stop (unboxed)
    mk_next env get_i get_x: pushes onto the stack:
     * how much to increase the counter (unboxed)
     * the thing to return, Vanilla stackrep.
    get_x: The thing to put in the closure, and pass to mk_next

  Return code that takes the object (array or text) on the stack and puts a
  the iterator onto the stack.
  *)
  let create outer_env name mk_stop mk_next =
    Func.share_code1 outer_env name ("x", I32Type) [I32Type] (fun env get_x ->
      (* Register functions as needed *)
      let next_funid = E.add_fun env (name ^ "_next") (
        Func.of_body env ["clos", I32Type] [I32Type] (fun env ->
          let (set_n, get_n) = new_local env "n" in
          let (set_x, get_x) = new_local env "x" in
          let (set_ret, get_ret) = new_local env "ret" in

          (* Get pointer to counter from closure *)
          Closure.get ^^ Closure.load_data 0l ^^
          MutBox.load ^^ BoxedSmallWord.unbox env ^^ set_n ^^

          (* Get pointer to object in closure *)
          Closure.get ^^ Closure.load_data 1l ^^ set_x ^^

          get_n ^^
          (* Get counter end *)
          mk_stop env get_x ^^
          G.i (Compare (Wasm.Values.I32 I32Op.GeU)) ^^
          G.if_ (ValBlockType (Some I32Type))
            (* Then *)
            Opt.null
            (* Else *)
            begin (* Return stuff *)
              Opt.inject env (
                (* Put address of conter on the stack, for the store *)
                Closure.get ^^ Closure.load_data 0l ^^
                (* Get value and increase *)
                mk_next env get_n get_x ^^
                set_ret ^^ (* put return value aside *)
                (* Advance counter *)
                get_n ^^ G.i (Binary (Wasm.Values.I32 I32Op.Add)) ^^
                BoxedSmallWord.box env ^^ MutBox.store ^^
                (* Return new value *)
                get_ret)
            end
        )
      ) in

      let (set_ni, get_ni) = new_local env "next" in
      Closure.fixed_closure env next_funid
        [ Tagged.obj env Tagged.MutBox [ compile_unboxed_zero ]
        ; get_x
        ] ^^
      set_ni ^^

      Object.lit_raw env [ "next", fun _ -> get_ni ]
    )

end (* Iterators *)

module Blob = struct
  (* The layout of a blob object is

     ┌─────┬─────────┬──────────────────┐
     │ tag │ n_bytes │ bytes (padded) … │
     └─────┴─────────┴──────────────────┘

    This heap object is used for various kinds of binary, non-pointer data.

    When used for Text values, the bytes are UTF-8 encoded code points from
    Unicode.
  *)

  let header_size = Int32.add Tagged.header_size 1l

  let len_field = Int32.add Tagged.header_size 0l

  let lit env s =
    let tag = bytes_of_int32 (Tagged.int_of_tag Tagged.Blob) in
    let len = bytes_of_int32 (Int32.of_int (String.length s)) in
    let data = tag ^ len ^ s in
    let ptr = E.add_static_bytes env data in
    compile_unboxed_const ptr

  let alloc env = Func.share_code1 env "blob_alloc" ("len", I32Type) [I32Type] (fun env get_len ->
      let (set_x, get_x) = new_local env "x" in
      compile_unboxed_const (Int32.mul Heap.word_size header_size) ^^
      get_len ^^
      G.i (Binary (Wasm.Values.I32 I32Op.Add)) ^^
      Heap.dyn_alloc_bytes env ^^
      set_x ^^

      get_x ^^ Tagged.store Tagged.Blob ^^
      get_x ^^ get_len ^^ Heap.store_field len_field ^^
      get_x
   )

  let unskewed_payload_offset = Int32.(add ptr_unskew (mul Heap.word_size header_size))
  let payload_ptr_unskewed = compile_add_const unskewed_payload_offset

  let as_ptr_len env = Func.share_code1 env "as_ptr_size" ("x", I32Type) [I32Type; I32Type] (
    fun env get_x ->
      get_x ^^ payload_ptr_unskewed ^^
      get_x ^^ Heap.load_field len_field
    )

  (* Blob concatenation. Expects two strings on stack *)
  let concat env = Func.share_code2 env "concat" (("x", I32Type), ("y", I32Type)) [I32Type] (fun env get_x get_y ->
      let (set_z, get_z) = new_local env "z" in
      let (set_len1, get_len1) = new_local env "len1" in
      let (set_len2, get_len2) = new_local env "len2" in

      get_x ^^ Heap.load_field len_field ^^ set_len1 ^^
      get_y ^^ Heap.load_field len_field ^^ set_len2 ^^

      (* allocate memory *)
      get_len1 ^^
      get_len2 ^^
      G.i (Binary (Wasm.Values.I32 I32Op.Add)) ^^
      alloc env ^^
      set_z ^^

      (* Copy first string *)
      get_z ^^ payload_ptr_unskewed ^^
      get_x ^^ payload_ptr_unskewed ^^
      get_len1 ^^
      Heap.memcpy env ^^

      (* Copy second string *)
      get_z ^^ payload_ptr_unskewed ^^ get_len1 ^^ G.i (Binary (Wasm.Values.I32 I32Op.Add)) ^^
      get_y ^^ payload_ptr_unskewed ^^
      get_len2 ^^
      Heap.memcpy env ^^

      (* Done *)
      get_z
    )


  (* Lexicographic blob comparison. Expects two blobs on the stack *)
  let rec compare env op =
    let open Operator in
    let name = match op with
        | LtOp -> "Blob.compare_lt"
        | LeOp -> "Blob.compare_le"
        | GeOp -> "Blob.compare_ge"
        | GtOp -> "Blob.compare_gt"
        | EqOp -> "Blob.compare_eq"
        | NeqOp -> "Blob.compare_ne" in
    Func.share_code2 env name (("x", I32Type), ("y", I32Type)) [I32Type] (fun env get_x get_y ->
      match op with
        (* Some operators can be reduced to the negation of other operators *)
        | LtOp ->  get_x ^^ get_y ^^ compare env GeOp ^^ Bool.neg
        | GtOp ->  get_x ^^ get_y ^^ compare env LeOp ^^ Bool.neg
        | NeqOp -> get_x ^^ get_y ^^ compare env EqOp ^^ Bool.neg
        | _ ->
      begin
        let (set_len1, get_len1) = new_local env "len1" in
        let (set_len2, get_len2) = new_local env "len2" in
        let (set_len, get_len) = new_local env "len" in
        let (set_a, get_a) = new_local env "a" in
        let (set_b, get_b) = new_local env "b" in

        get_x ^^ Heap.load_field len_field ^^ set_len1 ^^
        get_y ^^ Heap.load_field len_field ^^ set_len2 ^^

        (* Find mininum length *)
        begin if op = EqOp then
          (* Early exit for equality *)
          get_len1 ^^ get_len2 ^^ G.i (Compare (Wasm.Values.I32 I32Op.Eq)) ^^
          G.if_ (ValBlockType None) G.nop (Bool.lit false ^^ G.i Return) ^^

          get_len1 ^^ set_len
        else
          get_len1 ^^ get_len2 ^^ G.i (Compare (Wasm.Values.I32 I32Op.LeU)) ^^
          G.if_ (ValBlockType None)
            (get_len1 ^^ set_len)
            (get_len2 ^^ set_len)
        end ^^

        (* We could do word-wise comparisons if we know that the trailing bytes
           are zeroed *)
        get_len ^^
        from_0_to_n env (fun get_i ->
          get_x ^^
          payload_ptr_unskewed ^^
          get_i ^^
          G.i (Binary (Wasm.Values.I32 I32Op.Add)) ^^
          G.i (Load {ty = I32Type; align = 0; offset = 0l; sz = Some (Wasm.Memory.Pack8, Wasm.Memory.ZX)}) ^^
          set_a ^^


          get_y ^^
          payload_ptr_unskewed ^^
          get_i ^^
          G.i (Binary (Wasm.Values.I32 I32Op.Add)) ^^
          G.i (Load {ty = I32Type; align = 0; offset = 0l; sz = Some (Wasm.Memory.Pack8, Wasm.Memory.ZX)}) ^^
          set_b ^^

          get_a ^^ get_b ^^ G.i (Compare (Wasm.Values.I32 I32Op.Eq)) ^^
          G.if_ (ValBlockType None) G.nop (
            (* first non-equal elements *)
            begin match op with
            | LeOp -> get_a ^^ get_b ^^ G.i (Compare (Wasm.Values.I32 I32Op.LeU))
            | GeOp -> get_a ^^ get_b ^^ G.i (Compare (Wasm.Values.I32 I32Op.GeU))
            | EqOp -> Bool.lit false
            |_ -> assert false
            end ^^
            G.i Return
          )
        ) ^^
        (* Common prefix is same *)
        match op with
        | LeOp -> get_len1 ^^ get_len2 ^^ G.i (Compare (Wasm.Values.I32 I32Op.LeU))
        | GeOp -> get_len1 ^^ get_len2 ^^ G.i (Compare (Wasm.Values.I32 I32Op.GeU))
        | EqOp -> Bool.lit true
        |_ -> assert false
      end
  )

  let dyn_alloc_scratch env = alloc env ^^ payload_ptr_unskewed

end (* Blob *)

module Text = struct

  let prim_decodeUTF8 env =
    Func.share_code1 env "decodeUTF8" ("string", I32Type)
      [I32Type; I32Type] (fun env get_string ->
        let (set_res, get_res) = new_local env "res" in
        get_string ^^ Blob.payload_ptr_unskewed ^^
        UnboxedSmallWord.len_UTF8_head env set_res ^^
        BoxedSmallWord.box env ^^
        get_res ^^ UnboxedSmallWord.box_codepoint
      )

  let text_chars_direct env =
    Iterators.create env "text_chars_direct"
      (fun env get_x -> get_x ^^ Heap.load_field Blob.len_field)
      (fun env get_i get_x ->
          let (set_char, get_char) = new_local env "char" in
          get_x ^^ Blob.payload_ptr_unskewed ^^
          get_i ^^ G.i (Binary (Wasm.Values.I32 I32Op.Add)) ^^
          UnboxedSmallWord.len_UTF8_head env set_char ^^
          get_char ^^ UnboxedSmallWord.box_codepoint
      )

  let len env =
    Func.share_code1 env "text_len" ("x", I32Type) [I32Type] (fun env get_x ->
      let (set_max, get_max) = new_local env "max" in
      let (set_n, get_n) = new_local env "n" in
      let (set_len, get_len) = new_local env "len" in
      compile_unboxed_zero ^^ set_n ^^
      compile_unboxed_zero ^^ set_len ^^
      get_x ^^ Heap.load_field Blob.len_field ^^ set_max ^^
      compile_while
        (get_n ^^ get_max ^^ G.i (Compare (Wasm.Values.I32 I32Op.LtU)))
        begin
          get_x ^^ Blob.payload_ptr_unskewed ^^ get_n ^^
            G.i (Binary (Wasm.Values.I32 I32Op.Add)) ^^
          UnboxedSmallWord.len_UTF8_head env (G.i Drop) ^^
          get_n ^^ G.i (Binary (Wasm.Values.I32 I32Op.Add)) ^^ set_n ^^
          get_len ^^ compile_add_const 1l ^^ set_len
        end ^^
      get_len ^^
      BigNum.from_word32 env
    )

  let prim_showChar env =
    let (set_c, get_c) = new_local env "c" in
    let (set_utf8, get_utf8) = new_local env "utf8" in
    let storeLeader bitpat shift =
      get_c ^^ compile_shrU_const shift ^^ compile_bitor_const bitpat ^^
      G.i (Store {ty = I32Type; align = 0;
                  offset = Blob.unskewed_payload_offset;
                  sz = Some Wasm.Memory.Pack8}) in
    let storeFollower offset shift =
      get_c ^^ compile_shrU_const shift ^^ UnboxedSmallWord.compile_6bit_mask ^^
        compile_bitor_const 0b10000000l ^^
      G.i (Store {ty = I32Type; align = 0;
                  offset = Int32.add offset Blob.unskewed_payload_offset;
                  sz = Some Wasm.Memory.Pack8}) in
    let allocPayload n = compile_unboxed_const n ^^ Blob.alloc env ^^ set_utf8 ^^ get_utf8 in
    UnboxedSmallWord.unbox_codepoint ^^
    set_c ^^
    get_c ^^
    compile_unboxed_const 0x80l ^^
    G.i (Compare (Wasm.Values.I32 I32Op.LtU)) ^^
    G.if_ (ValBlockType None)
      (allocPayload 1l ^^ storeLeader 0b00000000l 0l)
      begin
        get_c ^^
        compile_unboxed_const 0x800l ^^
        G.i (Compare (Wasm.Values.I32 I32Op.LtU)) ^^
        G.if_ (ValBlockType None)
          begin
            allocPayload 2l ^^ storeFollower 1l 0l ^^
            get_utf8 ^^ storeLeader 0b11000000l 6l
          end
          begin
            get_c ^^
            compile_unboxed_const 0x10000l ^^
            G.i (Compare (Wasm.Values.I32 I32Op.LtU)) ^^
            G.if_ (ValBlockType None)
            begin
              allocPayload 3l ^^ storeFollower 2l 0l ^^
              get_utf8 ^^ storeFollower 1l 6l ^^
              get_utf8 ^^ storeLeader 0b11100000l 12l
            end
            begin
              allocPayload 4l ^^ storeFollower 3l 0l ^^
              get_utf8 ^^ storeFollower 2l 6l ^^
              get_utf8 ^^ storeFollower 1l 12l ^^
              get_utf8 ^^ storeLeader 0b11110000l 18l
            end
          end
      end ^^
    get_utf8

end (* Text *)

module Arr = struct
  (* Object layout:

     ┌─────┬──────────┬────────┬───┐
     │ tag │ n_fields │ field1 │ … │
     └─────┴──────────┴────────┴───┘

     No difference between mutable and immutable arrays.
  *)

  let header_size = Int32.add Tagged.header_size 1l
  let element_size = 4l
  let len_field = Int32.add Tagged.header_size 0l

  (* Static array access. No checking *)
  let load_field n = Heap.load_field Int32.(add n header_size)

  (* Dynamic array access. Returns the address (not the value) of the field.
     Does bounds checking *)
  let idx env =
    Func.share_code2 env "Array.idx" (("array", I32Type), ("idx", I32Type)) [I32Type] (fun env get_array get_idx ->
      (* No need to check the lower bound, we interpret is as unsigned *)
      (* Check the upper bound *)
      get_idx ^^
      get_array ^^ Heap.load_field len_field ^^
      G.i (Compare (Wasm.Values.I32 I32Op.LtU)) ^^
      E.else_trap_with env "Array index out of bounds" ^^

      get_idx ^^
      compile_add_const header_size ^^
      compile_mul_const element_size ^^
      get_array ^^
      G.i (Binary (Wasm.Values.I32 I32Op.Add))
    )

  (* Compile an array literal. *)
  let lit env element_instructions =
    Tagged.obj env Tagged.Array
     ([ compile_unboxed_const (Wasm.I32.of_int_u (List.length element_instructions))
      ] @ element_instructions)

  (* Does not initialize the fields! *)
  let alloc env =
    let (set_len, get_len) = new_local env "len" in
    let (set_r, get_r) = new_local env "r" in
    set_len ^^

    (* Check size (should not be larger than half the memory space) *)
    get_len ^^
    compile_unboxed_const Int32.(shift_left 1l (32-2-1)) ^^
    G.i (Compare (Wasm.Values.I32 I32Op.LtU)) ^^
    E.else_trap_with env "Array allocation too large" ^^

    (* Allocate *)
    get_len ^^
    compile_add_const header_size ^^
    Heap.dyn_alloc_words env ^^
    set_r ^^

    (* Write header *)
    get_r ^^
    Tagged.store Tagged.Array ^^
    get_r ^^
    get_len ^^
    Heap.store_field len_field ^^

    get_r

  (* The primitive operations *)
  (* No need to wrap them in RTS functions: They occur only once, in the prelude. *)
  let init env =
    let (set_len, get_len) = new_local env "len" in
    let (set_x, get_x) = new_local env "x" in
    let (set_r, get_r) = new_local env "r" in
    set_x ^^
    BigNum.to_word32 env ^^
    set_len ^^

    (* Allocate *)
    get_len ^^
    alloc env ^^
    set_r ^^

    (* Write fields *)
    get_len ^^
    from_0_to_n env (fun get_i ->
      get_r ^^
      get_i ^^
      idx env ^^
      get_x ^^
      store_ptr
    ) ^^
    get_r

  let tabulate env =
    let (set_len, get_len) = new_local env "len" in
    let (set_f, get_f) = new_local env "f" in
    let (set_r, get_r) = new_local env "r" in
    set_f ^^
    BigNum.to_word32 env ^^
    set_len ^^

    (* Allocate *)
    get_len ^^
    alloc env ^^
    set_r ^^

    (* Write fields *)
    get_len ^^
    from_0_to_n env (fun get_i ->
      (* Where to store *)
      get_r ^^ get_i ^^ idx env ^^
      (* The closure *)
      get_f ^^
      (* The arg *)
      get_i ^^
      BigNum.from_word32 env ^^
      (* The closure again *)
      get_f ^^
      (* Call *)
      Closure.call_closure env 1 1 ^^
      store_ptr
    ) ^^
    get_r

end (* Array *)

module Tuple = struct
  (* Tuples use the same object representation (and same tag) as arrays.
     Even though we know the size statically, we still need the size
     information for the GC.

     One could introduce tags for small tuples, to save one word.
  *)

  (* We represent the boxed empty tuple as the unboxed scalar 0, i.e. simply as
     number (but really anything is fine, we never look at this) *)
  let compile_unit = compile_unboxed_one

  (* Expects on the stack the pointer to the array. *)
  let load_n n = Heap.load_field (Int32.add Arr.header_size n)

  (* Takes n elements of the stack and produces an argument tuple *)
  let from_stack env n =
    if n = 0 then compile_unit
    else
      let name = Printf.sprintf "to_%i_tuple" n in
      let args = Lib.List.table n (fun i -> Printf.sprintf "arg%i" i, I32Type) in
      Func.share_code env name args [I32Type] (fun env ->
        Arr.lit env (Lib.List.table n (fun i -> G.i (LocalGet (nr (Int32.of_int i)))))
      )

  (* Takes an argument tuple and puts the elements on the stack: *)
  let to_stack env n =
    if n = 0 then G.i Drop else
    begin
      let name = Printf.sprintf "from_%i_tuple" n in
      let retty = Lib.List.make n I32Type in
      Func.share_code1 env name ("tup", I32Type) retty (fun env get_tup ->
        G.table n (fun i -> get_tup ^^ load_n (Int32.of_int i))
      )
    end

end (* Tuple *)

module Dfinity = struct
  (* Dfinity-specific stuff: System imports, databufs etc. *)

  let system_imports env =
    let i32s n = Lib.List.make n I32Type in
    match E.mode env with
    | Flags.ICMode ->
      E.add_func_import env "debug" "print" [I32Type; I32Type] [];
      E.add_func_import env "msg" "arg_data_size" [] [I32Type];
      E.add_func_import env "msg" "arg_data_copy" [I32Type; I32Type; I32Type] [];
      E.add_func_import env "msg" "reply" [I32Type; I32Type] [];
      E.add_func_import env "msg" "reject" [I32Type; I32Type] [];
      E.add_func_import env "msg" "reject_code" [] [I32Type];
      E.add_func_import env "ic" "trap" [I32Type; I32Type] [];
      ()
    | Flags.StubMode  ->
      E.add_func_import env "ic0" "call_simple" (i32s 10) [I32Type];
      E.add_func_import env "ic0" "canister_self_copy" (i32s 3) [];
      E.add_func_import env "ic0" "canister_self_size" [] [I32Type];
      E.add_func_import env "ic0" "debug_print" (i32s 2) [];
      E.add_func_import env "ic0" "msg_arg_data_copy" (i32s 3) [];
      E.add_func_import env "ic0" "msg_arg_data_size" [] [I32Type];
      E.add_func_import env "ic0" "msg_reject_code" [] [I32Type];
      E.add_func_import env "ic0" "msg_reject" (i32s 2) [];
      E.add_func_import env "ic0" "msg_reply_data_append" (i32s 2) [];
      E.add_func_import env "ic0" "msg_reply" [] [];
      E.add_func_import env "ic0" "trap" (i32s 2) [];
      E.add_func_import env "stub" "create_canister" (i32s 4) [I32Type];
      E.add_func_import env "stub" "created_canister_id_size" (i32s 1) [I32Type];
      E.add_func_import env "stub" "created_canister_id_copy" (i32s 4) [];
      ()
    | Flags.WASIMode ->
      E.add_func_import env "wasi_unstable" "fd_write" [I32Type; I32Type; I32Type; I32Type] [I32Type];
    | Flags.WasmMode -> ()

  let system_call env modname funcname = E.call_import env modname funcname

  let print_ptr_len env =
    match E.mode env with
    | Flags.WasmMode -> G.i Drop ^^ G.i Drop
    | Flags.ICMode -> system_call env "debug" "print"
    | Flags.StubMode -> system_call env "ic0" "debug_print"
    | Flags.WASIMode ->
      Func.share_code2 env "print_ptr" (("ptr", I32Type), ("len", I32Type)) [] (fun env get_ptr get_len ->
        Stack.with_words env "io_vec" 6l (fun get_iovec_ptr ->
          (* We use the iovec functionality to append a newline *)
          get_iovec_ptr ^^
          get_ptr ^^
          G.i (Store {ty = I32Type; align = 2; offset = 0l; sz = None}) ^^

          get_iovec_ptr ^^
          get_len ^^
          G.i (Store {ty = I32Type; align = 2; offset = 4l; sz = None}) ^^

          get_iovec_ptr ^^
          get_iovec_ptr ^^ compile_add_const 16l ^^
          G.i (Store {ty = I32Type; align = 2; offset = 8l; sz = None}) ^^

          get_iovec_ptr ^^
          compile_unboxed_const 1l ^^
          G.i (Store {ty = I32Type; align = 2; offset = 12l; sz = None}) ^^

          get_iovec_ptr ^^
          compile_unboxed_const (Int32.of_int (Char.code '\n')) ^^
          G.i (Store {ty = I32Type; align = 0; offset = 16l; sz = Some Wasm.Memory.Pack8}) ^^

          (* Call fd_write twice to work around
             https://github.com/bytecodealliance/wasmtime/issues/629
          *)

          compile_unboxed_const 1l (* stdout *) ^^
          get_iovec_ptr ^^
          compile_unboxed_const 1l (* one string segments (2 doesnt work) *) ^^
          get_iovec_ptr ^^ compile_add_const 20l ^^ (* out for bytes written, we ignore that *)
          E.call_import env "wasi_unstable" "fd_write" ^^
          G.i Drop ^^

          compile_unboxed_const 1l (* stdout *) ^^
          get_iovec_ptr ^^ compile_add_const 8l ^^
          compile_unboxed_const 1l (* one string segments *) ^^
          get_iovec_ptr ^^ compile_add_const 20l ^^ (* out for bytes written, we ignore that *)
          E.call_import env "wasi_unstable" "fd_write" ^^
          G.i Drop
        )
      )

  let print_text env =
    Func.share_code1 env "print_text" ("str", I32Type) [] (fun env get_str ->
      get_str ^^ Blob.payload_ptr_unskewed ^^
      get_str ^^ Heap.load_field (Blob.len_field) ^^
      print_ptr_len env
    )

  (* For debugging *)
  let compile_static_print env s =
    Blob.lit env s ^^ print_text env

  let _compile_println_int env =
    system_call env "test" "show_i32" ^^
    system_call env "test" "print" ^^
    compile_static_print env "\n"

  let ic_trap env =
      match E.mode env with
      | Flags.ICMode -> system_call env "ic" "trap"
      | Flags.StubMode -> system_call env "ic0" "trap"
      | _ -> assert false

  let ic_trap_str env =
      Func.share_code1 env "ic_trap" ("str", I32Type) [] (fun env get_str ->
        get_str ^^ Blob.payload_ptr_unskewed ^^
        get_str ^^ Heap.load_field (Blob.len_field) ^^
        ic_trap env
      )

  let trap_with env s =
    match E.mode env with
    | Flags.WasmMode -> G.i Unreachable
    | Flags.WASIMode -> compile_static_print env (s ^ "\n") ^^ G.i Unreachable
    | Flags.ICMode | Flags.StubMode -> Blob.lit env s ^^ ic_trap_str env ^^ G.i Unreachable

  let default_exports env =
    (* these exports seem to be wanted by the hypervisor/v8 *)
    E.add_export env (nr {
      name = Wasm.Utf8.decode (
        match E.mode env with
        | Flags.WASIMode -> "memory"
        | _  -> "mem"
      );
      edesc = nr (MemoryExport (nr 0l))
    });
    E.add_export env (nr {
      name = Wasm.Utf8.decode "table";
      edesc = nr (TableExport (nr 0l))
    })

  let export_start env start_fi =
    assert (E.mode env = Flags.ICMode || E.mode env = Flags.StubMode);
    (* Create an empty message *)
    let empty_f = Func.of_body env [] [] (fun env1 ->
      G.i (Call (nr start_fi)) ^^
      (* Collect garbage *)
      G.i (Call (nr (E.built_in env1 "collect")))
    ) in
    let fi = E.add_fun env "start_stub" empty_f in
    E.add_export env (nr {
      name = Wasm.Utf8.decode "canister_init";
      edesc = nr (FuncExport (nr fi))
    })

  let get_self_reference env =
    match E.mode env with
    | Flags.StubMode ->
      Func.share_code0 env "canister_self" [I32Type] (fun env ->
        let (set_len, get_len) = new_local env "len" in
        let (set_blob, get_blob) = new_local env "blob" in
        system_call env "ic0" "canister_self_size" ^^
        set_len ^^

        get_len ^^ Blob.alloc env ^^ set_blob ^^
        get_blob ^^ Blob.payload_ptr_unskewed ^^
        compile_unboxed_const 0l ^^
        get_len ^^
        system_call env "ic0" "canister_self_copy" ^^

        get_blob
      )
    | _ ->
      assert false

  let reject env arg_instrs =
    match E.mode env with
    | Flags.ICMode | Flags.StubMode ->
      let (set_text, get_text) = new_local env "text" in
      arg_instrs ^^
      set_text ^^
      get_text ^^ Blob.payload_ptr_unskewed ^^
      get_text ^^ Heap.load_field (Blob.len_field) ^^
      begin match E.mode env with
      | Flags.ICMode -> system_call env "msg" "reject"
      | Flags.StubMode -> system_call env "ic0" "msg_reject"
      | _ -> assert false
      end
    | _ ->
      assert false

  let error_code env =
      SR.UnboxedWord32,
      match E.mode env with
      | Flags.ICMode ->
        system_call env "msg" "reject_code"
      | Flags.StubMode ->
        system_call env "ic" "msg_reject_code"
      | _ -> assert false

  let reply_with_data env =
    Func.share_code2 env "reply_with_data" (("start", I32Type), ("size", I32Type)) [] (
      fun env get_data_start get_data_size ->
        get_data_start ^^
        get_data_size ^^
        match E.mode env with
        | Flags.ICMode -> system_call env "msg" "reply"
        | Flags.StubMode ->
          system_call env "ic0" "msg_reply_data_append" ^^
          system_call env "ic0" "msg_reply"
        | _ -> assert false
    )

  (* Actor reference on the stack *)
  let actor_public_field env name =
    match E.mode env with
    | Flags.ICMode | Flags.StubMode ->
      (* simply tuple canister name and function name *)
      Blob.lit env name ^^
      Tuple.from_stack env 2
    | Flags.WasmMode | Flags.WASIMode -> assert false

  let fail_assert env at =
    E.trap_with env (Printf.sprintf "assertion failed at %s" (string_of_region at))

  let async_method_name = "__motoko_async_helper"

end (* Dfinity *)

module RTS_Exports = struct
  let system_exports env =
    E.add_export env (nr {
      name = Wasm.Utf8.decode "alloc_bytes";
      edesc = nr (FuncExport (nr (E.built_in env "alloc_bytes")))
    });
    E.add_export env (nr {
      name = Wasm.Utf8.decode "alloc_words";
      edesc = nr (FuncExport (nr (E.built_in env "alloc_words")))
    });
    let bigint_trap_fi = E.add_fun env "bigint_trap" (
      Func.of_body env [] [] (fun env ->
        E.trap_with env "bigint function error"
      )
    ) in
    E.add_export env (nr {
      name = Wasm.Utf8.decode "bigint_trap";
      edesc = nr (FuncExport (nr bigint_trap_fi))
    });
    let rts_trap_fi = E.add_fun env "rts_trap" (
      Func.of_body env ["str", I32Type; "len", I32Type] [] (fun env ->
        let get_str = G.i (LocalGet (nr 0l)) in
        let get_len = G.i (LocalGet (nr 1l)) in
        get_str ^^ get_len ^^ Dfinity.print_ptr_len env ^^
        G.i Unreachable
      )
    ) in
    E.add_export env (nr {
      name = Wasm.Utf8.decode "rts_trap";
      edesc = nr (FuncExport (nr rts_trap_fi))
    })

end (* RTS_Exports *)


module HeapTraversal = struct
  (* Returns the object size (in words) *)
  let object_size env =
    Func.share_code1 env "object_size" ("x", I32Type) [I32Type] (fun env get_x ->
      get_x ^^
      Tagged.branch env (ValBlockType (Some I32Type))
        [ Tagged.Int,
          compile_unboxed_const 3l
        ; Tagged.SmallWord,
          compile_unboxed_const 2l
        ; Tagged.BigInt,
          compile_unboxed_const 5l (* HeapTag + sizeof(mp_int) *)
        ; Tagged.Some,
          compile_unboxed_const 2l
        ; Tagged.Variant,
          compile_unboxed_const 3l
        ; Tagged.ObjInd,
          compile_unboxed_const 2l
        ; Tagged.MutBox,
          compile_unboxed_const 2l
        ; Tagged.Array,
          get_x ^^
          Heap.load_field Arr.len_field ^^
          compile_add_const Arr.header_size
        ; Tagged.Blob,
          get_x ^^
          Heap.load_field Blob.len_field ^^
          compile_add_const 3l ^^
          compile_divU_const Heap.word_size ^^
          compile_add_const Blob.header_size
        ; Tagged.Object,
          get_x ^^
          Heap.load_field Object.size_field ^^
          compile_mul_const 2l ^^
          compile_add_const Object.header_size
        ; Tagged.Closure,
          get_x ^^
          Heap.load_field Closure.len_field ^^
          compile_add_const Closure.header_size
        ]
        (* Indirections have unknown size. *)
    )

  let walk_heap_from_to env compile_from compile_to mk_code =
      let (set_x, get_x) = new_local env "x" in
      compile_from ^^ set_x ^^
      compile_while
        (* While we have not reached the end of the area *)
        ( get_x ^^
          compile_to ^^
          G.i (Compare (Wasm.Values.I32 I32Op.LtU))
        )
        ( mk_code get_x ^^
          get_x ^^
          get_x ^^ object_size env ^^ compile_mul_const Heap.word_size ^^
          G.i (Binary (Wasm.Values.I32 I32Op.Add)) ^^
          set_x
        )

  (* Calls mk_code for each pointer in the object pointed to by get_x,
     passing code get the address of the pointer,
     and code to get the offset of the pointer (for the BigInt payload field). *)
  let for_each_pointer env get_x mk_code mk_code_offset =
    let (set_ptr_loc, get_ptr_loc) = new_local env "ptr_loc" in
    let code = mk_code get_ptr_loc in
    let code_offset = mk_code_offset get_ptr_loc in
    get_x ^^
    Tagged.branch_default env (ValBlockType None) G.nop
      [ Tagged.MutBox,
        get_x ^^
        compile_add_const (Int32.mul Heap.word_size MutBox.field) ^^
        set_ptr_loc ^^
        code
      ; Tagged.BigInt,
        get_x ^^
        compile_add_const (Int32.mul Heap.word_size 4l) ^^
        set_ptr_loc ^^
        code_offset Blob.unskewed_payload_offset
      ; Tagged.Some,
        get_x ^^
        compile_add_const (Int32.mul Heap.word_size Opt.payload_field) ^^
        set_ptr_loc ^^
        code
      ; Tagged.Variant,
        get_x ^^
        compile_add_const (Int32.mul Heap.word_size Variant.payload_field) ^^
        set_ptr_loc ^^
        code
      ; Tagged.ObjInd,
        get_x ^^
        compile_add_const (Int32.mul Heap.word_size 1l) ^^
        set_ptr_loc ^^
        code
      ; Tagged.Array,
        get_x ^^
        Heap.load_field Arr.len_field ^^
        (* Adjust fields *)
        from_0_to_n env (fun get_i ->
          get_x ^^
          get_i ^^
          Arr.idx env ^^
          set_ptr_loc ^^
          code
        )
      ; Tagged.Object,
        get_x ^^
        Heap.load_field Object.size_field ^^

        from_0_to_n env (fun get_i ->
          get_i ^^
          compile_mul_const 2l ^^
          compile_add_const 1l ^^
          compile_add_const Object.header_size ^^
          compile_mul_const Heap.word_size ^^
          get_x ^^
          G.i (Binary (Wasm.Values.I32 I32Op.Add)) ^^
          set_ptr_loc ^^
          code
        )
      ; Tagged.Closure,
        get_x ^^
        Heap.load_field Closure.len_field ^^

        from_0_to_n env (fun get_i ->
          get_i ^^
          compile_add_const Closure.header_size ^^
          compile_mul_const Heap.word_size ^^
          get_x ^^
          G.i (Binary (Wasm.Values.I32 I32Op.Add)) ^^
          set_ptr_loc ^^
          code
        )
      ]

end (* HeapTraversal *)

module Serialization = struct
  (*
    The general serialization strategy is as follows:
    * We statically generate the IDL type description header.
    * We traverse the data to calculate the size needed for the data buffer and the
      reference buffer.
    * We allocate memory for the data buffer and the reference buffer
      (this memory area is not referenced, so will be dead with the next GC)
    * We copy the IDL type header to the data buffer.
    * We traverse the data and serialize it into the data buffer.
      This is type driven, and we use the `share_code` machinery and names that
      properly encode the type to resolve loops in a convenient way.
    * We externalize all that new data space into a databuf
    * We externalize the reference space into a elembuf
    * We pass both databuf and elembuf to shared functions
      (this mimicks the future system API)

    The deserialization is analogous:
    * We allocate some scratch space, and internalize the databuf and elembuf into it.
    * We parse the data, in a type-driven way, using normal construction and
      allocation, while keeping tabs on the type description header for subtyping.
    * At the end, the scratch space is a hole in the heap, and will be reclaimed
      by the next GC.
  *)

  (* A type identifier *)

  (*
    This needs to map types to some identifier with the following properties:
     - Its domain are normalized types that do not mention any type parameters
     - It needs to be injective wrt. type equality
     - It needs to terminate, even for recursive types
     - It may fail upon type parameters (i.e. no polymorphism)
    We can use string_of_typ here for now, it seems, but eventually we
    want something more efficient and compact and less fragile.
  *)
  let typ_id : Type.typ -> string = Type.string_of_typ

  let sort_by_hash fs =
    List.sort
      (fun (h1,_) (h2,_) -> Lib.Uint32.compare h1 h2)
      (List.map (fun f -> (Idllib.Escape.unescape_hash f.Type.lab, f)) fs)

  (* The code below does not work on all Motoko types, but only certain “raw
     types”. In particular, type definitions have to be removed (using Type.normalize).
     But also, at least for now, actor and function references are represented
     as data, https://github.com/dfinity-lab/motoko/pull/883
   *)
  let raw_type env : Type.typ -> Type.typ = fun t ->
    let open Type in
    match normalize t with
    | Obj (Actor, _) -> Prim Blob
    | Func _  -> Tup [Prim Blob; Prim Text]
    | t -> t


  (* The IDL serialization prefaces the data with a type description.
     We can statically create the type description in Ocaml code,
     store it in the program, and just copy it to the beginning of the message.

     At some point this can be factored into a function from AS type to IDL type,
     and a function like this for IDL types. But due to recursion handling
     it is easier to start like this.
  *)

  module TM = Map.Make (struct type t = Type.typ let compare = compare end)
  let to_idl_prim = let open Type in function
    | Prim Null | Tup [] -> Some 1
    | Prim Bool -> Some 2
    | Prim Nat -> Some 3
    | Prim Int -> Some 4
    | Prim (Nat8|Word8) -> Some 5
    | Prim (Nat16|Word16) -> Some 6
    | Prim (Nat32|Word32|Char) -> Some 7
    | Prim (Nat64|Word64) -> Some 8
    | Prim Int8 -> Some 9
    | Prim Int16 -> Some 10
    | Prim Int32 -> Some 11
    | Prim Int64 -> Some 12
    | Prim Float -> Some 14
    | Prim Text -> Some 15
    (* NB: Prim Blob does not map to a primitive IDL type *)
    | Any -> Some 16
    | Non -> Some 17
    | _ -> None

  let type_desc env ts : string =
    let open Type in

    (* Type traversal *)
    (* We do a first traversal to find out the indices of non-primitive types *)
    let (typs, idx) =
      let typs = ref [] in
      let idx = ref TM.empty in
      let rec go t =
        let t = raw_type env t in
        if to_idl_prim t <> None then () else
        if TM.mem t !idx then () else begin
          idx := TM.add t (List.length !typs) !idx;
          typs := !typs @ [ t ];
          match t with
          | Tup ts -> List.iter go ts
          | Obj (_, fs) ->
            List.iter (fun f -> go f.typ) fs
          | Array t -> go t
          | Opt t -> go t
          | Variant vs -> List.iter (fun f -> go f.typ) vs
          | Func (s, c, tbs, ts1, ts2) ->
            List.iter go ts1; List.iter go ts2
          | Prim Blob -> ()
          | _ ->
            Printf.eprintf "type_desc: unexpected type %s\n" (string_of_typ t);
            assert false
        end
      in
      List.iter go ts;
      (!typs, !idx)
    in

    (* buffer utilities *)
    let buf = Buffer.create 16 in

    let add_u8 i =
      Buffer.add_char buf (Char.chr (i land 0xff)) in

    let rec add_leb128_32 (i : Lib.Uint32.t) =
      let open Lib.Uint32 in
      let b = logand i (of_int32 0x7fl) in
      if of_int32 0l <= i && i < of_int32 128l
      then add_u8 (to_int b)
      else begin
        add_u8 (to_int (logor b (of_int32 0x80l)));
        add_leb128_32 (shift_right_logical i 7)
      end in

    let add_leb128 i =
      assert (i >= 0);
      add_leb128_32 (Lib.Uint32.of_int i) in

    let rec add_sleb128 i =
      let b = i land 0x7f in
      if -64 <= i && i < 64
      then add_u8 b
      else begin
        add_u8 (b lor 0x80);
        add_sleb128 (i asr 7)
      end in

    (* Actual binary data *)

    let add_idx t =
      let t = raw_type env t in
      match to_idl_prim t with
      | Some i -> add_sleb128 (-i)
      | None -> add_sleb128 (TM.find (normalize t) idx) in

    let rec add_typ t =
      match t with
      | Non -> assert false
      | Prim Blob ->
        add_typ Type.(Array (Prim Word8))
      | Prim _ -> assert false
      | Tup ts ->
        add_sleb128 (-20);
        add_leb128 (List.length ts);
        List.iteri (fun i t ->
          add_leb128 i;
          add_idx t;
        ) ts
      | Obj (Object, fs) ->
        add_sleb128 (-20);
        add_leb128 (List.length fs);
        List.iter (fun (h, f) ->
          add_leb128_32 h;
          add_idx f.typ
        ) (sort_by_hash fs)
      | Obj (Actor, fs) ->
        assert false;
      | Array t ->
        add_sleb128 (-19); add_idx t
      | Opt t ->
        add_sleb128 (-18); add_idx t
      | Variant vs ->
        add_sleb128 (-21);
        add_leb128 (List.length vs);
        List.iter (fun (h, f) ->
          add_leb128_32 h;
          add_idx f.typ
        ) (sort_by_hash vs)
      | Func _ ->
        assert false
      | _ -> assert false in

    Buffer.add_string buf "DIDL";
    add_leb128 (List.length typs);
    List.iter add_typ typs;
    add_leb128 (List.length ts);
    List.iter add_idx ts;
    Buffer.contents buf

  (* Returns data (in bytes) and reference buffer size (in entries) needed *)
  let rec buffer_size env t =
    let open Type in
    let t = raw_type env t in
    let name = "@buffer_size<" ^ typ_id t ^ ">" in
    Func.share_code1 env name ("x", I32Type) [I32Type; I32Type]
    (fun env get_x ->

      (* Some combinators for writing values *)
      let (set_data_size, get_data_size) = new_local env "data_size" in
      let (set_ref_size, get_ref_size) = new_local env "ref_size" in
      compile_unboxed_const 0l ^^ set_data_size ^^
      compile_unboxed_const 0l ^^ set_ref_size ^^

      let inc_data_size code =
        get_data_size ^^ code ^^
        G.i (Binary (Wasm.Values.I32 I32Op.Add)) ^^
        set_data_size
      in

      let size_word env code =
        let (set_word, get_word) = new_local env "word" in
        code ^^ set_word ^^
        inc_data_size (I32Leb.compile_leb128_size get_word)
      in

      let size env t =
        buffer_size env t ^^
        get_ref_size ^^ G.i (Binary (Wasm.Values.I32 I32Op.Add)) ^^ set_ref_size ^^
        get_data_size ^^ G.i (Binary (Wasm.Values.I32 I32Op.Add)) ^^ set_data_size
      in

      (* Now the actual type-dependent code *)
      begin match t with
      | Prim Nat -> inc_data_size (get_x ^^ BigNum.compile_data_size_unsigned env)
      | Prim Int -> inc_data_size (get_x ^^ BigNum.compile_data_size_signed env)
      | Prim (Int8|Nat8|Word8) -> inc_data_size (compile_unboxed_const 1l)
      | Prim (Int16|Nat16|Word16) -> inc_data_size (compile_unboxed_const 2l)
      | Prim (Int32|Nat32|Word32|Char) -> inc_data_size (compile_unboxed_const 4l)
      | Prim (Int64|Nat64|Word64) -> inc_data_size (compile_unboxed_const 8l)
      | Prim Bool -> inc_data_size (compile_unboxed_const 1l)
      | Prim Null -> G.nop
      | Any -> G.nop
      | Tup [] -> G.nop (* e(()) = null *)
      | Tup ts ->
        G.concat_mapi (fun i t ->
          get_x ^^ Tuple.load_n (Int32.of_int i) ^^
          size env t
        ) ts
      | Obj (Object, fs) ->
        G.concat_map (fun (_h, f) ->
          get_x ^^ Object.load_idx env t f.Type.lab ^^
          size env f.typ
        ) (sort_by_hash fs)
      | Array t ->
        size_word env (get_x ^^ Heap.load_field Arr.len_field) ^^
        get_x ^^ Heap.load_field Arr.len_field ^^
        from_0_to_n env (fun get_i ->
          get_x ^^ get_i ^^ Arr.idx env ^^ load_ptr ^^
          size env t
        )
      | Prim (Text | Blob) ->
        let (set_len, get_len) = new_local env "len" in
        get_x ^^ Heap.load_field Blob.len_field ^^ set_len ^^
        size_word env get_len ^^
        inc_data_size get_len
      | Opt t ->
        inc_data_size (compile_unboxed_const 1l) ^^ (* one byte tag *)
        get_x ^^ Opt.is_some env ^^
        G.if_ (ValBlockType None) (get_x ^^ Opt.project ^^ size env t) G.nop
      | Variant vs ->
        List.fold_right (fun (i, {lab = l; typ = t}) continue ->
            get_x ^^
            Variant.test_is env l ^^
            G.if_ (ValBlockType None)
              ( size_word env (compile_unboxed_const (Int32.of_int i)) ^^
                get_x ^^ Variant.project ^^ size env t
              ) continue
          )
          ( List.mapi (fun i (_h, f) -> (i,f)) (sort_by_hash vs) )
          ( E.trap_with env "buffer_size: unexpected variant" )
      | (Func _ | Obj (Actor, _)) ->
        assert false
      | Non ->
        E.trap_with env "buffer_size called on value of type None"
      | _ -> todo "buffer_size" (Arrange_ir.typ t) G.nop
      end ^^
      get_data_size ^^
      get_ref_size
    )

  (* Copies x to the data_buffer, storing references after ref_count entries in ref_base *)
  let rec serialize_go env t =
    let open Type in
    let t = raw_type env t in
    let name = "@serialize_go<" ^ typ_id t ^ ">" in
    Func.share_code3 env name (("x", I32Type), ("data_buffer", I32Type), ("ref_buffer", I32Type)) [I32Type; I32Type]
    (fun env get_x get_data_buf get_ref_buf ->
      let set_data_buf = G.i (LocalSet (nr 1l)) in
      let set_ref_buf = G.i (LocalSet (nr 2l)) in

      (* Some combinators for writing values *)

      let advance_data_buf =
        get_data_buf ^^ G.i (Binary (Wasm.Values.I32 I32Op.Add)) ^^ set_data_buf in

      let write_word code =
        let (set_word, get_word) = new_local env "word" in
        code ^^ set_word ^^
        I32Leb.compile_store_to_data_buf_unsigned env get_word get_data_buf ^^
        advance_data_buf
      in

      let write_byte code =
        get_data_buf ^^ code ^^
        G.i (Store {ty = I32Type; align = 0; offset = 0l; sz = Some Wasm.Memory.Pack8}) ^^
        compile_unboxed_const 1l ^^ advance_data_buf
      in

      let write env t =
        get_data_buf ^^
        get_ref_buf ^^
        serialize_go env t ^^
        set_ref_buf ^^
        set_data_buf
      in


      (* Now the actual serialization *)

      begin match t with
      | Prim Nat ->
        get_data_buf ^^
        get_x ^^
        BigNum.compile_store_to_data_buf_unsigned env ^^
        advance_data_buf
      | Prim Int ->
        get_data_buf ^^
        get_x ^^
        BigNum.compile_store_to_data_buf_signed env ^^
        advance_data_buf
      | Prim (Int64|Nat64|Word64) ->
        get_data_buf ^^
        get_x ^^ BoxedWord64.unbox env ^^
        G.i (Store {ty = I64Type; align = 0; offset = 0l; sz = None}) ^^
        compile_unboxed_const 8l ^^ advance_data_buf
      | Prim (Int32|Nat32|Word32) ->
        get_data_buf ^^
        get_x ^^ BoxedSmallWord.unbox env ^^
        G.i (Store {ty = I32Type; align = 0; offset = 0l; sz = None}) ^^
        compile_unboxed_const 4l ^^ advance_data_buf
      | Prim Char ->
        get_data_buf ^^
        get_x ^^ UnboxedSmallWord.unbox_codepoint ^^
        G.i (Store {ty = I32Type; align = 0; offset = 0l; sz = None}) ^^
        compile_unboxed_const 4l ^^ advance_data_buf
      | Prim (Int16|Nat16|Word16) ->
        get_data_buf ^^
        get_x ^^ UnboxedSmallWord.lsb_adjust Word16 ^^
        G.i (Store {ty = I32Type; align = 0; offset = 0l; sz = Some Wasm.Memory.Pack16}) ^^
        compile_unboxed_const 2l ^^ advance_data_buf
      | Prim (Int8|Nat8|Word8) ->
        get_data_buf ^^
        get_x ^^ UnboxedSmallWord.lsb_adjust Word8 ^^
        G.i (Store {ty = I32Type; align = 0; offset = 0l; sz = Some Wasm.Memory.Pack8}) ^^
        compile_unboxed_const 1l ^^ advance_data_buf
      | Prim Bool ->
        get_data_buf ^^
        get_x ^^
        G.i (Store {ty = I32Type; align = 0; offset = 0l; sz = Some Wasm.Memory.Pack8}) ^^
        compile_unboxed_const 1l ^^ advance_data_buf
      | Tup [] -> (* e(()) = null *)
        G.nop
      | Tup ts ->
        G.concat_mapi (fun i t ->
          get_x ^^ Tuple.load_n (Int32.of_int i) ^^
          write env t
        ) ts
      | Obj (Object, fs) ->
        G.concat_map (fun (_h,f) ->
          get_x ^^ Object.load_idx env t f.Type.lab ^^
          write env f.typ
        ) (sort_by_hash fs)
      | Array t ->
        write_word (get_x ^^ Heap.load_field Arr.len_field) ^^
        get_x ^^ Heap.load_field Arr.len_field ^^
        from_0_to_n env (fun get_i ->
          get_x ^^ get_i ^^ Arr.idx env ^^ load_ptr ^^
          write env t
        )
      | Prim Null -> G.nop
      | Any -> G.nop
      | Opt t ->
        get_x ^^
        Opt.is_some env ^^
        G.if_ (ValBlockType None)
          ( write_byte (compile_unboxed_const 1l) ^^ get_x ^^ Opt.project ^^ write env t )
          ( write_byte (compile_unboxed_const 0l) )
      | Variant vs ->
        List.fold_right (fun (i, {lab = l; typ = t}) continue ->
            get_x ^^
            Variant.test_is env l ^^
            G.if_ (ValBlockType None)
              ( write_word (compile_unboxed_const (Int32.of_int i)) ^^
                get_x ^^ Variant.project ^^ write env t)
              continue
          )
          ( List.mapi (fun i (_h, f) -> (i,f)) (sort_by_hash vs) )
          ( E.trap_with env "serialize_go: unexpected variant" )
      | Prim (Text | Blob )->
        (* Serializes to text or vec word8 respectively, but same data format *)
        let (set_len, get_len) = new_local env "len" in
        get_x ^^ Heap.load_field Blob.len_field ^^ set_len ^^
        write_word get_len ^^
        get_data_buf ^^
        get_x ^^ Blob.payload_ptr_unskewed ^^
        get_len ^^
        Heap.memcpy env ^^
        get_len ^^ advance_data_buf
      | (Func _ | Obj (Actor, _)) ->
        assert false
      | Non ->
        E.trap_with env "serializing value of type None"
      | _ -> todo "serialize" (Arrange_ir.typ t) G.nop
      end ^^
      get_data_buf ^^
      get_ref_buf
    )

  let rec deserialize_go env t =
    let open Type in
    let t = raw_type env t in
    let name = "@deserialize_go<" ^ typ_id t ^ ">" in
    Func.share_code4 env name
      (("data_buffer", I32Type),
       ("ref_buffer", I32Type),
       ("typtbl", I32Type),
       ("idltyp", I32Type)
      ) [I32Type]
    (fun env get_data_buf get_ref_buf get_typtbl get_idltyp ->

      let go env t =
        let (set_idlty, get_idlty) = new_local env "idl_ty" in
        set_idlty ^^
        get_data_buf ^^
        get_ref_buf ^^
        get_typtbl ^^
        get_idlty ^^
        deserialize_go env t
      in

      let check_prim_typ t =
        get_idltyp ^^
        compile_eq_const (Int32.of_int (- (Lib.Option.value (to_idl_prim t))))
      in

      let assert_prim_typ t =
        check_prim_typ t ^^
        E.else_trap_with env ("IDL error: unexpected IDL type when parsing " ^ string_of_typ t)
      in

      let read_blob validate =
        let (set_len, get_len) = new_local env "len" in
        let (set_x, get_x) = new_local env "x" in
        ReadBuf.read_leb128 env get_data_buf ^^ set_len ^^

        get_len ^^ Blob.alloc env ^^ set_x ^^
        get_x ^^ Blob.payload_ptr_unskewed ^^
        ReadBuf.read_blob env get_data_buf get_len ^^
        begin if validate then
          get_x ^^ Blob.payload_ptr_unskewed ^^ get_len ^^
          E.call_import env "rts" "utf8_validate"
        else G.nop end ^^
        get_x
      in

      (* checks that idltyp is positive, looks it up in the table, updates the typ_buf,
         reads the type constructor index and traps if it is the wrong one.
         typ_buf left in place to read the type constructor arguments *)
      let with_composite_typ idl_tycon_id f =
        (* make sure index is not negative *)
        get_idltyp ^^
        compile_unboxed_const 0l ^^ G.i (Compare (Wasm.Values.I32 I32Op.GeS)) ^^
        E.else_trap_with env ("IDL error: expected composite type when parsing " ^ string_of_typ t) ^^
        ReadBuf.alloc env (fun get_typ_buf ->
          (* Update typ_buf *)
          ReadBuf.set_ptr get_typ_buf (
            get_typtbl ^^
            get_idltyp ^^ compile_mul_const Heap.word_size ^^
            G.i (Binary (Wasm.Values.I32 I32Op.Add)) ^^
            load_unskewed_ptr
          ) ^^
          ReadBuf.set_end get_typ_buf (ReadBuf.get_end get_data_buf) ^^
          (* read sleb128 *)
          ReadBuf.read_sleb128 env get_typ_buf ^^
          (* Check it is the expected value *)
          compile_eq_const idl_tycon_id ^^
          E.else_trap_with env ("IDL error: wrong composite type when parsing " ^ string_of_typ t) ^^
          (* to the work *)
          f get_typ_buf
        ) in

      let assert_blob_typ env =
        with_composite_typ (-19l) (fun get_typ_buf ->
          ReadBuf.read_sleb128 env get_typ_buf ^^
          compile_eq_const (-5l) (* Nat8 *) ^^
          E.else_trap_with env ("IDL error: blob not a vector of nat8")
        )
      in

      (* Now the actual deserialization *)
      begin match t with
      (* Primitive types *)
      | Prim Nat ->
        assert_prim_typ t ^^
        get_data_buf ^^
        BigNum.compile_load_from_data_buf env false
      | Prim Int ->
        (* Subtyping with nat *)
        check_prim_typ (Prim Nat) ^^
        G.if_ (ValBlockType (Some I32Type))
          begin
            get_data_buf ^^
            BigNum.compile_load_from_data_buf env false
          end
          begin
            assert_prim_typ t ^^
            get_data_buf ^^
            BigNum.compile_load_from_data_buf env true
          end
      | Prim (Int64|Nat64|Word64) ->
        assert_prim_typ t ^^
        ReadBuf.read_word64 env get_data_buf ^^
        BoxedWord64.box env
      | Prim (Int32|Nat32|Word32) ->
        assert_prim_typ t ^^
        ReadBuf.read_word32 env get_data_buf ^^
        BoxedSmallWord.box env
      | Prim Char ->
        let set_n, get_n = new_local env "len" in
        assert_prim_typ t ^^
        ReadBuf.read_word32 env get_data_buf ^^ set_n ^^
        UnboxedSmallWord.check_and_box_codepoint env get_n
      | Prim (Int16|Nat16|Word16) ->
        assert_prim_typ t ^^
        ReadBuf.read_word16 env get_data_buf ^^
        UnboxedSmallWord.msb_adjust Word16
      | Prim (Int8|Nat8|Word8) ->
        assert_prim_typ t ^^
        ReadBuf.read_byte env get_data_buf ^^
        UnboxedSmallWord.msb_adjust Word8
      | Prim Bool ->
        assert_prim_typ t ^^
        ReadBuf.read_byte env get_data_buf
      | Prim Null ->
        assert_prim_typ t ^^
        Opt.null
      | Any ->
        (* Skip values of any possible type *)
        get_data_buf ^^ get_typtbl ^^ get_idltyp ^^ compile_unboxed_const 0l ^^
        E.call_import env "rts" "skip_any" ^^

        (* Any vanilla value works here *)
        Opt.null
      | Prim Text ->
        assert_prim_typ t ^^
        read_blob true
      | Prim Blob ->
        assert_blob_typ env ^^
        read_blob false
      | Tup [] -> (* e(()) = null *)
        assert_prim_typ t ^^
        Tuple.from_stack env 0
      (* Composite types *)
      | Tup ts ->
        with_composite_typ (-20l) (fun get_typ_buf ->
          let (set_n, get_n) = new_local env "record_fields" in
          ReadBuf.read_leb128 env get_typ_buf ^^ set_n ^^

          G.concat_mapi (fun i t ->
            (* skip all possible intermediate extra fields *)
            get_typ_buf ^^ get_data_buf ^^ get_typtbl ^^ compile_unboxed_const (Int32.of_int i) ^^ get_n ^^
            E.call_import env "rts" "find_field" ^^ set_n ^^

            ReadBuf.read_sleb128 env get_typ_buf ^^ go env t
          ) ts ^^

          (* skip all possible trailing extra fields *)
          get_typ_buf ^^ get_data_buf ^^ get_typtbl ^^ get_n ^^
          E.call_import env "rts" "skip_fields" ^^

          Tuple.from_stack env (List.length ts)
        )
      | Obj (Object, fs) ->
        with_composite_typ (-20l) (fun get_typ_buf ->
          let (set_n, get_n) = new_local env "record_fields" in
          ReadBuf.read_leb128 env get_typ_buf ^^ set_n ^^

          Object.lit_raw env (List.map (fun (h,f) ->
            f.Type.lab, fun () ->
              (* skip all possible intermediate extra fields *)
              get_typ_buf ^^ get_data_buf ^^ get_typtbl ^^ compile_unboxed_const (Lib.Uint32.to_int32 h) ^^ get_n ^^
              E.call_import env "rts" "find_field" ^^ set_n ^^

              ReadBuf.read_sleb128 env get_typ_buf ^^ go env f.typ
          ) (sort_by_hash fs)) ^^

          (* skip all possible trailing extra fields *)
          get_typ_buf ^^ get_data_buf ^^ get_typtbl ^^ get_n ^^
          E.call_import env "rts" "skip_fields"
        )
      | Array t ->
        let (set_len, get_len) = new_local env "len" in
        let (set_x, get_x) = new_local env "x" in
        let (set_idltyp, get_idltyp) = new_local env "idltyp" in
        with_composite_typ (-19l) (fun get_typ_buf ->
          ReadBuf.read_sleb128 env get_typ_buf ^^ set_idltyp ^^
          ReadBuf.read_leb128 env get_data_buf ^^ set_len ^^
          get_len ^^ Arr.alloc env ^^ set_x ^^
          get_len ^^ from_0_to_n env (fun get_i ->
            get_x ^^ get_i ^^ Arr.idx env ^^
            get_idltyp ^^ go env t ^^
            store_ptr
          ) ^^
          get_x
        )
      | Opt t ->
        check_prim_typ (Prim Null) ^^
        G.if_ (ValBlockType (Some I32Type))
          begin
                Opt.null
          end
          begin
            let (set_idltyp, get_idltyp) = new_local env "idltyp" in
            with_composite_typ (-18l) (fun get_typ_buf ->
              ReadBuf.read_sleb128 env get_typ_buf ^^ set_idltyp ^^
              ReadBuf.read_byte env get_data_buf ^^
              let (set_b, get_b) = new_local env "b" in
              set_b ^^
              get_b ^^
              compile_eq_const 0l ^^
              G.if_ (ValBlockType (Some I32Type))
              begin
                Opt.null
              end begin
                get_b ^^ compile_eq_const 1l ^^
                E.else_trap_with env "IDL error: opt tag not 0 or 1" ^^
                Opt.inject env (get_idltyp ^^ go env t)
              end
            )
          end
      | Variant vs ->
        with_composite_typ (-21l) (fun get_typ_buf ->
          (* Find the tag *)
          let (set_n, get_n) = new_local env "len" in
          ReadBuf.read_leb128 env get_typ_buf ^^ set_n ^^

          let (set_tagidx, get_tagidx) = new_local env "tagidx" in
          ReadBuf.read_leb128 env get_data_buf ^^ set_tagidx ^^

          get_tagidx ^^ get_n ^^
          G.i (Compare (Wasm.Values.I32 I32Op.LtU)) ^^
          E.else_trap_with env "IDL error: variant index out of bounds" ^^

          (* Zoom past the previous entries *)
          get_tagidx ^^ from_0_to_n env (fun _ ->
            get_typ_buf ^^ E.call_import env "rts" "skip_leb128" ^^
            get_typ_buf ^^ E.call_import env "rts" "skip_leb128"
          ) ^^

          (* Now read the tag *)
          let (set_tag, get_tag) = new_local env "tag" in
          ReadBuf.read_leb128 env get_typ_buf ^^ set_tag ^^
          let (set_idltyp, get_idltyp) = new_local env "idltyp" in
          ReadBuf.read_sleb128 env get_typ_buf ^^ set_idltyp ^^

          List.fold_right (fun (h, {lab = l; typ = t}) continue ->
              get_tag ^^ compile_eq_const (Lib.Uint32.to_int32 h) ^^
              G.if_ (ValBlockType (Some I32Type))
                ( Variant.inject env l (get_idltyp ^^ go env t) )
                continue
            )
            ( sort_by_hash vs )
            ( E.trap_with env "IDL error: unexpected variant tag" )
        )
      | (Func _ | Obj (Actor, _)) ->
        assert false;
      | Non ->
        E.trap_with env "IDL error: deserializing value of type None"
      | _ -> todo_trap env "deserialize" (Arrange_ir.typ t)
      end
    )

  let argument_data_size env =
    match E.mode env with
    | Flags.ICMode ->
      Dfinity.system_call env "msg" "arg_data_size"
    | Flags.StubMode ->
      Dfinity.system_call env "ic0" "msg_arg_data_size"
    | _ -> assert false

  let argument_data_copy env get_dest get_length =
    match E.mode env with
    | Flags.ICMode ->
      get_dest ^^
      get_length ^^
      (compile_unboxed_const 0l) ^^
      Dfinity.system_call env "msg" "arg_data_copy"
    | Flags.StubMode ->
      get_dest ^^
      (compile_unboxed_const 0l) ^^
      get_length ^^
      Dfinity.system_call env "ic0" "msg_arg_data_copy"
    | _ -> assert false

  let serialize env ts : G.t =
    let ts_name = String.concat "," (List.map typ_id ts) in
    let name = "@serialize<" ^ ts_name ^ ">" in
    (* returns data/length pointers (will be GC’ed next time!) *)
    Func.share_code1 env name ("x", I32Type) [I32Type; I32Type] (fun env get_x ->
      let (set_data_size, get_data_size) = new_local env "data_size" in
      let (set_refs_size, get_refs_size) = new_local env "refs_size" in

      let tydesc = type_desc env ts in
      let tydesc_len = Int32.of_int (String.length tydesc) in

      (* Get object sizes *)
      get_x ^^
      buffer_size env (Type.seq ts) ^^
      set_refs_size ^^

      compile_add_const tydesc_len  ^^
      set_data_size ^^

      let (set_data_start, get_data_start) = new_local env "data_start" in
      let (set_refs_start, get_refs_start) = new_local env "refs_start" in

      get_data_size ^^ Blob.dyn_alloc_scratch env ^^ set_data_start ^^
      get_refs_size ^^ compile_mul_const Heap.word_size ^^ Blob.dyn_alloc_scratch env ^^ set_refs_start ^^

      (* Write ty desc *)
      get_data_start ^^
      Blob.lit env tydesc ^^ Blob.payload_ptr_unskewed ^^
      compile_unboxed_const tydesc_len ^^
      Heap.memcpy env ^^

      (* Serialize x into the buffer *)
      get_x ^^
      get_data_start ^^ compile_add_const tydesc_len ^^
      get_refs_start ^^
      serialize_go env (Type.seq ts) ^^

      (* Sanity check: Did we fill exactly the buffer *)
      get_refs_start ^^ get_refs_size ^^ compile_mul_const Heap.word_size ^^ G.i (Binary (Wasm.Values.I32 I32Op.Add)) ^^
      G.i (Compare (Wasm.Values.I32 I32Op.Eq)) ^^
      E.else_trap_with env "reference buffer not filled " ^^

      get_data_start ^^ get_data_size ^^ G.i (Binary (Wasm.Values.I32 I32Op.Add)) ^^
      G.i (Compare (Wasm.Values.I32 I32Op.Eq)) ^^
      E.else_trap_with env "data buffer not filled " ^^

      match E.mode env with
      | Flags.ICMode | Flags.StubMode ->
        get_refs_size ^^
        compile_unboxed_const 0l ^^
        G.i (Compare (Wasm.Values.I32 I32Op.Eq)) ^^
        E.else_trap_with env "cannot send references on IC System API" ^^

        get_data_start ^^
        get_data_size
      | Flags.WasmMode | Flags.WASIMode -> assert false
    )

  let deserialize env ts =
    let ts_name = String.concat "," (List.map typ_id ts) in
    let name = "@deserialize<" ^ ts_name ^ ">" in
    Func.share_code env name [] (List.map (fun _ -> I32Type) ts) (fun env ->
      let (set_data_size, get_data_size) = new_local env "data_size" in
      let (set_refs_size, get_refs_size) = new_local env "refs_size" in
      let (set_data_start, get_data_start) = new_local env "data_start" in
      let (set_refs_start, get_refs_start) = new_local env "refs_start" in
      let (set_arg_count, get_arg_count) = new_local env "arg_count" in

      (* Allocate space for the data buffer and copy it *)
      argument_data_size env ^^ set_data_size ^^
      get_data_size ^^ Blob.dyn_alloc_scratch env ^^ set_data_start ^^
      argument_data_copy env get_data_start get_data_size ^^

      (* Allocate space for the reference buffer and copy it *)
      compile_unboxed_const 0l ^^ set_refs_size (* none yet *) ^^

      (* Allocate space for out parameters of parse_idl_header *)
      Stack.with_words env "get_typtbl_ptr" 1l (fun get_typtbl_ptr ->
      Stack.with_words env "get_maintyps_ptr" 1l (fun get_maintyps_ptr ->

      (* Set up read buffers *)
      ReadBuf.alloc env (fun get_data_buf -> ReadBuf.alloc env (fun get_ref_buf ->

      ReadBuf.set_ptr get_data_buf get_data_start ^^
      ReadBuf.set_size get_data_buf get_data_size ^^
      ReadBuf.set_ptr get_ref_buf get_refs_start ^^
      ReadBuf.set_size get_ref_buf (get_refs_size ^^ compile_mul_const Heap.word_size) ^^

      (* Go! *)
      get_data_buf ^^ get_typtbl_ptr ^^ get_maintyps_ptr ^^
      E.call_import env "rts" "parse_idl_header" ^^

      (* set up a dedicated read buffer for the list of main types *)
      ReadBuf.alloc env (fun get_main_typs_buf ->
        ReadBuf.set_ptr get_main_typs_buf (get_maintyps_ptr ^^ load_unskewed_ptr) ^^
        ReadBuf.set_end get_main_typs_buf (ReadBuf.get_end get_data_buf) ^^

        ReadBuf.read_leb128 env get_main_typs_buf ^^ set_arg_count ^^

        get_arg_count ^^
        compile_rel_const I32Op.GeU (Int32.of_int (List.length ts)) ^^
        E.else_trap_with env ("IDL error: too few arguments " ^ ts_name) ^^

        G.concat_map (fun t ->
          get_data_buf ^^ get_ref_buf ^^
          get_typtbl_ptr ^^ load_unskewed_ptr ^^
          ReadBuf.read_sleb128 env get_main_typs_buf ^^
          deserialize_go env t
        ) ts ^^

        get_arg_count ^^ compile_eq_const (Int32.of_int (List.length ts)) ^^
        G.if_ (ValBlockType None)
          begin
            ReadBuf.is_empty env get_data_buf ^^
            E.else_trap_with env ("IDL error: left-over bytes " ^ ts_name) ^^
            ReadBuf.is_empty env get_ref_buf ^^
            E.else_trap_with env ("IDL error: left-over references " ^ ts_name)
          end G.nop
      )
    )))))

end (* Serialization *)

module GC = struct
  (* This is a very simple GC:
     It copies everything live to the to-space beyond the bump pointer,
     then it memcpies it back, over the from-space (so that we still neatly use
     the beginning of memory).

     Roots are:
     * All objects in the static part of the memory.
     * the closure_table (see module ClosureTable)
  *)

  let gc_enabled = true

  (* If the pointer at ptr_loc points after begin_from_space, copy
     to after end_to_space, and replace it with a pointer, adjusted for where
     the object will be finally. *)
  (* Returns the new end of to_space *)
  (* Invariant: Must not be called on the same pointer twice. *)
  (* All pointers, including ptr_loc and space end markers, are skewed *)

  let evacuate_common env
        get_obj update_ptr
        get_begin_from_space get_begin_to_space get_end_to_space
        =

    let (set_len, get_len) = new_local env "len" in

    (* If this is static, ignore it *)
    get_obj ^^
    get_begin_from_space ^^
    G.i (Compare (Wasm.Values.I32 I32Op.LtU)) ^^
    G.if_ (ValBlockType None) (get_end_to_space ^^ G.i Return) G.nop ^^

    (* If this is an indirection, just use that value *)
    get_obj ^^
    Tagged.branch_default env (ValBlockType None) G.nop [
      Tagged.Indirection,
      update_ptr (get_obj ^^ Heap.load_field 1l) ^^
      get_end_to_space ^^ G.i Return
    ] ^^

    (* Get object size *)
    get_obj ^^ HeapTraversal.object_size env ^^ set_len ^^

    (* Grow memory if needed *)
    get_end_to_space ^^
    get_len ^^ compile_mul_const Heap.word_size ^^
    G.i (Binary (Wasm.Values.I32 I32Op.Add)) ^^
    Heap.grow_memory env ^^

    (* Copy the referenced object to to space *)
    get_obj ^^ HeapTraversal.object_size env ^^ set_len ^^

    get_end_to_space ^^ get_obj ^^ get_len ^^ Heap.memcpy_words_skewed env ^^

    let (set_new_ptr, get_new_ptr) = new_local env "new_ptr" in

    (* Calculate new pointer *)
    get_end_to_space ^^
    get_begin_to_space ^^
    G.i (Binary (Wasm.Values.I32 I32Op.Sub)) ^^
    get_begin_from_space ^^
    G.i (Binary (Wasm.Values.I32 I32Op.Add)) ^^
    set_new_ptr ^^

    (* Set indirection *)
    get_obj ^^
    Tagged.store Tagged.Indirection ^^
    get_obj ^^
    get_new_ptr ^^
    Heap.store_field 1l ^^

    (* Update pointer *)
    update_ptr get_new_ptr ^^

    (* Calculate new end of to space *)
    get_end_to_space ^^
    get_len ^^ compile_mul_const Heap.word_size ^^
    G.i (Binary (Wasm.Values.I32 I32Op.Add))

  (* Used for normal skewed pointers *)
  let evacuate env = Func.share_code4 env "evacuate" (("begin_from_space", I32Type), ("begin_to_space", I32Type), ("end_to_space", I32Type), ("ptr_loc", I32Type)) [I32Type] (fun env get_begin_from_space get_begin_to_space get_end_to_space get_ptr_loc ->

    let get_obj = get_ptr_loc ^^ load_ptr in

    (* If this is an unboxed scalar, ignore it *)
    get_obj ^^
    BitTagged.if_unboxed env (ValBlockType None) (get_end_to_space ^^ G.i Return) G.nop ^^

    let update_ptr new_val_code =
      get_ptr_loc ^^ new_val_code ^^ store_ptr in

    evacuate_common env
        get_obj update_ptr
        get_begin_from_space get_begin_to_space get_end_to_space
  )

  (* A variant for pointers that point into the payload (used for the bignum objects).
     These are never scalars. *)
  let evacuate_offset env offset =
    let name = Printf.sprintf "evacuate_offset_%d" (Int32.to_int offset) in
    Func.share_code4 env name (("begin_from_space", I32Type), ("begin_to_space", I32Type), ("end_to_space", I32Type), ("ptr_loc", I32Type)) [I32Type] (fun env get_begin_from_space get_begin_to_space get_end_to_space get_ptr_loc ->
    let get_obj = get_ptr_loc ^^ load_ptr ^^ compile_sub_const offset in

    let update_ptr new_val_code =
      get_ptr_loc ^^ new_val_code ^^ compile_add_const offset ^^ store_ptr in

    evacuate_common env
        get_obj update_ptr
        get_begin_from_space get_begin_to_space get_end_to_space
  )

  let register env (end_of_static_space : int32) =
    Func.define_built_in env "get_heap_size" [] [I32Type] (fun env ->
      Heap.get_heap_ptr env ^^
      Heap.get_heap_base env ^^
      G.i (Binary (Wasm.Values.I32 I32Op.Sub))
    );

    Func.define_built_in env "collect" [] [] (fun env ->
      if not gc_enabled then G.nop else

      (* Copy all roots. *)
      let (set_begin_from_space, get_begin_from_space) = new_local env "begin_from_space" in
      let (set_begin_to_space, get_begin_to_space) = new_local env "begin_to_space" in
      let (set_end_to_space, get_end_to_space) = new_local env "end_to_space" in

      Heap.get_heap_base env ^^ compile_add_const ptr_skew ^^ set_begin_from_space ^^
      Heap.get_skewed_heap_ptr env ^^ set_begin_to_space ^^
      Heap.get_skewed_heap_ptr env ^^ set_end_to_space ^^


      (* Common arguments for evacuate *)
      let evac get_ptr_loc =
          get_begin_from_space ^^
          get_begin_to_space ^^
          get_end_to_space ^^
          get_ptr_loc ^^
          evacuate env ^^
          set_end_to_space in

      let evac_offset get_ptr_loc offset =
          get_begin_from_space ^^
          get_begin_to_space ^^
          get_end_to_space ^^
          get_ptr_loc ^^
          evacuate_offset env offset ^^
          set_end_to_space in

      (* Go through the roots, and evacuate them *)
      evac (ClosureTable.root env) ^^
      HeapTraversal.walk_heap_from_to env
        (compile_unboxed_const Int32.(add Stack.end_of_stack ptr_skew))
        (compile_unboxed_const Int32.(add end_of_static_space ptr_skew))
        (fun get_x -> HeapTraversal.for_each_pointer env get_x evac evac_offset) ^^

      (* Go through the to-space, and evacuate that.
         Note that get_end_to_space changes as we go, but walk_heap_from_to can handle that.
       *)
      HeapTraversal.walk_heap_from_to env
        get_begin_to_space
        get_end_to_space
        (fun get_x -> HeapTraversal.for_each_pointer env get_x evac evac_offset) ^^

      (* Copy the to-space to the beginning of memory. *)
      get_begin_from_space ^^ compile_add_const ptr_unskew ^^
      get_begin_to_space ^^ compile_add_const ptr_unskew ^^
      get_end_to_space ^^ get_begin_to_space ^^ G.i (Binary (Wasm.Values.I32 I32Op.Sub)) ^^
      Heap.memcpy env ^^

      (* Reset the heap pointer *)
      get_begin_from_space ^^ compile_add_const ptr_unskew ^^
      get_end_to_space ^^ get_begin_to_space ^^ G.i (Binary (Wasm.Values.I32 I32Op.Sub)) ^^
      G.i (Binary (Wasm.Values.I32 I32Op.Add)) ^^
      Heap.set_heap_ptr env
  )

  let get_heap_size env =
    G.i (Call (nr (E.built_in env "get_heap_size")))

end (* GC *)

module VarLoc = struct
  (* Most names are stored in heap locations or in locals.
     But some are special (static functions, the current actor, static messages of
     the current actor). These have no real location (yet), but we still need to
     produce a value on demand:
   *)

  type deferred_loc =
    { stack_rep : SR.t
    ; materialize : E.t -> G.t
    ; is_local : bool (* Only valid within the current function *)
    }

  (* A type to record where Motoko names are stored. *)
  type varloc =
    (* A Wasm Local of the current function, directly containing the value
       (note that most values are pointers, but not all)
       Used for immutable and mutable, non-captured data *)
    | Local of int32
    (* A Wasm Local of the current function, that points to memory location,
       with an offset (in words) to value.
       Used for mutable captured data *)
    | HeapInd of (int32 * int32)
    (* A static mutable memory location (static address of a MutBox field) *)
    | Static of int32
    (* Dynamic code to put the value on the heap.
       May be local to the current function or module (see is_local) *)
    | Deferred of deferred_loc

  let is_non_local : varloc -> bool = function
    | Local _ -> false
    | HeapInd _ -> false
    | Static _ -> true
    | Deferred d -> not d.is_local
end

module StackRep = struct
  open SR

  (*
     Most expressions have a “preferred”, most optimal, form. Hence,
     compile_exp put them on the stack in that form, and also returns
     the form it chose.

     But the users of compile_exp usually want a specific form as well.
     So they use compile_exp_as, indicating the form they expect.
     compile_exp_as then does the necessary coercions.
   *)

  let of_arity n =
    if n = 1 then Vanilla else UnboxedTuple n

  (* The stack rel of a primitive type, i.e. what the binary operators expect *)
  let of_type t =
    let open Type in
    match normalize t with
    | Prim Bool -> SR.bool
    | Prim (Nat | Int) -> Vanilla
    | Prim (Nat64 | Int64 | Word64) -> UnboxedWord64
    | Prim (Nat32 | Int32 | Word32) -> UnboxedWord32
    | Prim (Nat8 | Nat16 | Int8 | Int16 | Word8 | Word16 | Char) -> Vanilla
    | Prim Text -> Vanilla
    | p -> todo "of_type" (Arrange_ir.typ p) Vanilla

  let to_block_type env = function
    | Vanilla -> ValBlockType (Some I32Type)
    | UnboxedWord64 -> ValBlockType (Some I64Type)
    | UnboxedWord32 -> ValBlockType (Some I32Type)
    | UnboxedTuple 0 -> ValBlockType None
    | UnboxedTuple 1 -> ValBlockType (Some I32Type)
    | UnboxedTuple n when not !Flags.multi_value -> assert false
    | UnboxedTuple n -> VarBlockType (nr (E.func_type env (FuncType ([], Lib.List.make n I32Type))))
    | StaticThing _ -> ValBlockType None
    | Unreachable -> ValBlockType None

  let to_string = function
    | Vanilla -> "Vanilla"
    | UnboxedWord64 -> "UnboxedWord64"
    | UnboxedWord32 -> "UnboxedWord32"
    | UnboxedTuple n -> Printf.sprintf "UnboxedTuple %d" n
    | Unreachable -> "Unreachable"
    | StaticThing _ -> "StaticThing"

  let join (sr1 : t) (sr2 : t) = match sr1, sr2 with
    | _, _ when sr1 = sr2 -> sr1
    | Unreachable, sr2 -> sr2
    | sr1, Unreachable -> sr1
    | UnboxedWord64, UnboxedWord64 -> UnboxedWord64
    | UnboxedTuple n, UnboxedTuple m when n = m -> sr1
    | _, Vanilla -> Vanilla
    | Vanilla, _ -> Vanilla
    | StaticThing _, StaticThing _ -> Vanilla
    | _, _ ->
      Printf.eprintf "Invalid stack rep join (%s, %s)\n"
        (to_string sr1) (to_string sr2); sr1

  (* This is used when two blocks join, e.g. in an if. In that
     case, they cannot return multiple values. *)
  let relax =
    if !Flags.multi_value
    then fun sr -> sr
    else function
      | UnboxedTuple n when n > 1 -> Vanilla
      | sr -> sr

  let drop env (sr_in : t) =
    match sr_in with
    | Vanilla -> G.i Drop
    | UnboxedWord64 -> G.i Drop
    | UnboxedWord32 -> G.i Drop
    | UnboxedTuple n -> G.table n (fun _ -> G.i Drop)
    | StaticThing _ -> G.nop
    | Unreachable -> G.nop

  let materialize env = function
    | StaticFun fi ->
      (* When accessing a variable that is a static function, then we need to
         create a heap-allocated closure-like thing on the fly. *)
      Tagged.obj env Tagged.Closure [
        compile_unboxed_const fi;
        compile_unboxed_zero (* number of parameters: none *)
      ]
    | StaticMessage fi ->
      assert false
    | PublicMethod (_, name) ->
      Dfinity.get_self_reference env ^^
      Dfinity.actor_public_field env name

  let adjust env (sr_in : t) sr_out =
    if sr_in = sr_out
    then G.nop
    else match sr_in, sr_out with
    | Unreachable, Unreachable -> G.nop
    | Unreachable, _ -> G.i Unreachable

    | UnboxedTuple n, Vanilla -> Tuple.from_stack env n
    | Vanilla, UnboxedTuple n -> Tuple.to_stack env n

    | UnboxedWord64, Vanilla -> BoxedWord64.box env
    | Vanilla, UnboxedWord64 -> BoxedWord64.unbox env

    | UnboxedWord32, Vanilla -> BoxedSmallWord.box env
    | Vanilla, UnboxedWord32 -> BoxedSmallWord.unbox env

    | StaticThing s, Vanilla -> materialize env s
    | StaticThing s, UnboxedTuple 0 -> G.nop

    | _, _ ->
      Printf.eprintf "Unknown stack_rep conversion %s -> %s\n"
        (to_string sr_in) (to_string sr_out);
      G.nop

end (* StackRep *)

module VarEnv = struct
  (*
  The source variable environment:
  In scope variables and in-scope jump labels
  *)

  module NameEnv = Env.Make(String)
  type t = {
    vars : VarLoc.varloc NameEnv.t; (* variables ↦ their location *)
    labels : G.depth NameEnv.t; (* jump label ↦ their depth *)
  }

  let empty_ae = {
    vars = NameEnv.empty;
    labels = NameEnv.empty;
  }

  (* Creating a local environment, resetting the local fields,
     and removing bindings for local variables (unless they are at global locations)
  *)

  let mk_fun_ae ae = { ae with
    vars = NameEnv.filter (fun _ -> VarLoc.is_non_local) ae.vars;
  }
  let lookup_var ae var =
    match NameEnv.find_opt var ae.vars with
      | Some l -> Some l
      | None   -> Printf.eprintf "Could not find %s\n" var; None

  let needs_capture ae var = match lookup_var ae var with
    | Some l -> not (VarLoc.is_non_local l)
    | None -> assert false

  let reuse_local_with_offset (ae : t) name i off =
      { ae with vars = NameEnv.add name (VarLoc.HeapInd (i, off)) ae.vars }

  let add_local_with_offset env (ae : t) name off =
      let i = E.add_anon_local env I32Type in
      E.add_local_name env i name;
      (reuse_local_with_offset ae name i off, i)

  let add_local_static (ae : t) name ptr =
      { ae with vars = NameEnv.add name (VarLoc.Static ptr) ae.vars }

  let add_local_deferred (ae : t) name stack_rep materialize is_local =
      let open VarLoc in
      let d = {stack_rep; materialize; is_local} in
      { ae with vars = NameEnv.add name (VarLoc.Deferred d) ae.vars }

  let add_direct_local env (ae : t) name =
      let i = E.add_anon_local env I32Type in
      E.add_local_name env i name;
      ({ ae with vars = NameEnv.add name (VarLoc.Local i) ae.vars }, i)

  (* Adds the names to the environment and returns a list of setters *)
  let rec add_argument_locals env (ae : t) = function
    | [] -> (ae, [])
    | (name :: names) ->
      let i = E.add_anon_local env I32Type in
      E.add_local_name env i name;
      let ae' = { ae with vars = NameEnv.add name (VarLoc.Local i) ae.vars } in
      let (ae_final, setters) = add_argument_locals env ae' names
      in (ae_final, G.i (LocalSet (nr i)) :: setters)

  let in_scope_set (ae : t) =
    NameEnv.fold (fun k _ -> Freevars.S.add k) ae.vars Freevars.S.empty

  let add_label (ae : t) name (d : G.depth) =
      { ae with labels = NameEnv.add name d ae.labels }

  let get_label_depth (ae : t) name : G.depth  =
    match NameEnv.find_opt name ae.labels with
      | Some d -> d
      | None   -> Printf.eprintf "Could not find %s\n" name; raise Not_found

end (* VarEnv *)

module Var = struct
  (* This module is all about looking up Motoko variables in the environment,
     and dealing with mutable variables *)

  open VarLoc

  (* Stores the payload (which is found on the stack) *)
  let set_val env ae var = match VarEnv.lookup_var ae var with
    | Some (Local i) ->
      G.i (LocalSet (nr i))
    | Some (HeapInd (i, off)) ->
      let (set_new_val, get_new_val) = new_local env "new_val" in
      set_new_val ^^
      G.i (LocalGet (nr i)) ^^
      get_new_val ^^
      Heap.store_field off
    | Some (Static ptr) ->
      let (set_new_val, get_new_val) = new_local env "new_val" in
      set_new_val ^^
      compile_unboxed_const ptr ^^
      get_new_val ^^
      Heap.store_field 1l
    | Some (Deferred d) -> assert false
    | None   -> assert false

  (* Returns the payload (optimized representation) *)
  let get_val (env : E.t) (ae : VarEnv.t) var = match VarEnv.lookup_var ae var with
    | Some (Local i) ->
      SR.Vanilla, G.i (LocalGet (nr i))
    | Some (HeapInd (i, off)) ->
      SR.Vanilla, G.i (LocalGet (nr i)) ^^ Heap.load_field off
    | Some (Static i) ->
      SR.Vanilla, compile_unboxed_const i ^^ Heap.load_field 1l
    | Some (Deferred d) ->
      d.stack_rep, d.materialize env
    | None -> assert false

  (* Returns the payload (vanilla representation) *)
  let get_val_vanilla (env : E.t) (ae : VarEnv.t) var =
    let sr, code = get_val env ae var in
    code ^^ StackRep.adjust env sr SR.Vanilla

  (* Returns the value to put in the closure,
     and code to restore it, including adding to the environment
  *)
  let capture old_env ae0 var : G.t * (E.t -> VarEnv.t -> (VarEnv.t * G.t)) =
    match VarEnv.lookup_var ae0 var with
    | Some (Local i) ->
      ( G.i (LocalGet (nr i))
      , fun new_env ae1 ->
        let (ae2, j) = VarEnv.add_direct_local new_env ae1 var in
        let restore_code = G.i (LocalSet (nr j))
        in (ae2, restore_code)
      )
    | Some (HeapInd (i, off)) ->
      ( G.i (LocalGet (nr i))
      , fun new_env ae1 ->
        let (ae2, j) = VarEnv.add_local_with_offset new_env ae1 var off in
        let restore_code = G.i (LocalSet (nr j))
        in (ae2, restore_code)
      )
    | Some (Deferred d) ->
      assert d.is_local;
      ( d.materialize old_env ^^
        StackRep.adjust old_env d.stack_rep SR.Vanilla
      , fun new_env ae1 ->
        let (ae2, j) = VarEnv.add_direct_local new_env ae1 var in
        let restore_code = G.i (LocalSet (nr j))
        in (ae2, restore_code)
      )
    | _ -> assert false

  (* Returns a pointer to a heap allocated box for this.
     (either a mutbox, if already mutable, or a freshly allocated box)
  *)
  let field_box env code =
    Tagged.obj env Tagged.ObjInd [ code ]

  let get_val_ptr env ae var = match VarEnv.lookup_var ae var with
    | Some (HeapInd (i, 1l)) -> G.i (LocalGet (nr i))
    | Some (Static _) -> assert false (* we never do this on the toplevel *)
    | _  -> field_box env (get_val_vanilla env ae var)

end (* Var *)

(* This comes late because it also deals with messages *)
module FuncDec = struct
  let bind_args ae0 first_arg as_ bind_arg =
    let rec go i ae = function
    | [] -> ae
    | a::as_ ->
      let get = G.i (LocalGet (nr (Int32.of_int i))) in
      let ae' = bind_arg ae a get in
      go (i+1) ae' as_ in
    go first_arg ae0 as_

  (* Create a WebAssembly func from a pattern (for the argument) and the body.
   Parameter `captured` should contain the, well, captured local variables that
   the function will find in the closure. *)
  let compile_local_function outer_env outer_ae restore_env args mk_body ret_tys at =
    let arg_names = List.map (fun a -> a.it, I32Type) args in
    let return_arity = List.length ret_tys in
    let retty = Lib.List.make return_arity I32Type in
    let ae0 = VarEnv.mk_fun_ae outer_ae in
    Func.of_body outer_env (["clos", I32Type] @ arg_names) retty (fun env -> G.with_region at (
      let get_closure = G.i (LocalGet (nr 0l)) in

      let (ae1, closure_code) = restore_env env ae0 get_closure in

      (* Add arguments to the environment *)
      let ae2 = bind_args ae1 1 args (fun env a get ->
        VarEnv.add_local_deferred env a.it SR.Vanilla (fun _ -> get) true
      ) in

      closure_code ^^
      mk_body env ae2
    ))

  let message_cleanup env sort = match sort with
      | Type.Shared Type.Write -> G.i (Call (nr (E.built_in env "collect")))
      | Type.Shared Type.Query -> G.i Nop
      | _ -> assert false

  let compile_static_message outer_env outer_ae sort control args mk_body ret_tys at : E.func_with_names =
    match E.mode outer_env, control with
    | Flags.ICMode, _ ->
      let ae0 = VarEnv.mk_fun_ae outer_ae in
      Func.of_body outer_env [] [] (fun env -> G.with_region at (
        (* reply early for a oneway *)
        (if control = Type.Returns
         then
           Tuple.compile_unit ^^
           Serialization.serialize env [] ^^
           Dfinity.reply_with_data env
         else G.nop) ^^
        (* Deserialize argument and add params to the environment *)
        let arg_names = List.map (fun a -> a.it) args in
        let arg_tys = List.map (fun a -> a.note) args in
        let (ae1, setters) = VarEnv.add_argument_locals env ae0 arg_names in
        Serialization.deserialize env arg_tys ^^
        G.concat (List.rev setters) ^^
        mk_body env ae1 ^^
        message_cleanup env sort
      ))
    | Flags.StubMode, _ ->
      let ae0 = VarEnv.mk_fun_ae outer_ae in
      Func.of_body outer_env [] [] (fun env -> G.with_region at (
        (* Deserialize argument and add params to the environment *)
        let arg_names = List.map (fun a -> a.it) args in
        let arg_tys = List.map (fun a -> a.note) args in
        let (ae1, setters) = VarEnv.add_argument_locals env ae0 arg_names in
        Serialization.deserialize env arg_tys ^^
        G.concat (List.rev setters) ^^
        mk_body env ae1 ^^
        message_cleanup env sort
      ))
    | (Flags.WasmMode | Flags.WASIMode), _ -> assert false

  (* Compile a closed function declaration (captures no local variables) *)
  let closed pre_env sort control name args mk_body ret_tys at =
    let (fi, fill) = E.reserve_fun pre_env name in
    if Type.is_shared_sort sort
    then begin
      ( SR.StaticMessage fi, fun env ae ->
        fill (compile_static_message env ae sort control args mk_body ret_tys at)
      )
    end else begin
      assert (control = Type.Returns);
      ( SR.StaticFun fi, fun env ae ->
        let restore_no_env _env ae _ = (ae, G.nop) in
        fill (compile_local_function env ae restore_no_env args mk_body ret_tys at)
      )
    end

  (* Compile a closure declaration (captures local variables) *)
  let closure env ae sort control name captured args mk_body ret_tys at =
      let is_local = sort = Type.Local in

      let (set_clos, get_clos) = new_local env (name ^ "_clos") in

      let len = Wasm.I32.of_int_u (List.length captured) in
      let (store_env, restore_env) =
        let rec go i = function
          | [] -> (G.nop, fun _env ae1 _ -> (ae1, G.nop))
          | (v::vs) ->
              let (store_rest, restore_rest) = go (i+1) vs in
              let (store_this, restore_this) = Var.capture env ae v in
              let store_env =
                get_clos ^^
                store_this ^^
                Closure.store_data (Wasm.I32.of_int_u i) ^^
                store_rest in
              let restore_env env ae1 get_env =
                let (ae2, code) = restore_this env ae1 in
                let (ae3, code_rest) = restore_rest env ae2 get_env in
                (ae3,
                 get_env ^^
                 Closure.load_data (Wasm.I32.of_int_u i) ^^
                 code ^^
                 code_rest
                )
              in (store_env, restore_env) in
        go 0 captured in

      let f =
        if is_local
        then compile_local_function env ae restore_env args mk_body ret_tys at
        else assert false (* no first class shared functions yet *) in

      let fi = E.add_fun env name f in

      let code =
        (* Allocate a heap object for the closure *)
        Heap.alloc env (Int32.add Closure.header_size len) ^^
        set_clos ^^

        (* Store the tag *)
        get_clos ^^
        Tagged.store Tagged.Closure ^^

        (* Store the function number: *)
        get_clos ^^
        compile_unboxed_const fi ^^
        Heap.store_field Closure.funptr_field ^^

        (* Store the length *)
        get_clos ^^
        compile_unboxed_const len ^^
        Heap.store_field Closure.len_field ^^

        (* Store all captured values *)
        store_env
      in

      if is_local
      then
        SR.Vanilla,
        code ^^
        get_clos
      else assert false (* no first class shared functions *)

  let lit env ae name sort control free_vars args mk_body ret_tys at =

    let captured = List.filter (VarEnv.needs_capture ae) free_vars in

    if captured = []
    then
      let (st, fill) = closed env sort control name args mk_body ret_tys at in
      fill env ae;
      (SR.StaticThing st, G.nop)
    else closure env ae sort control name captured args mk_body ret_tys at

  (* Returns the index of a saved closure *)
  let async_body env ae ts free_vars mk_body at =
    (* We compile this as a local, returning function, so set return type to [] *)
    let sr, code = lit env ae "anon_async" Type.Local Type.Returns free_vars [] mk_body [] at in
    code ^^
    StackRep.adjust env sr SR.Vanilla ^^
    ClosureTable.remember env

  (* Takes the reply and reject callbacks, tuples them up,
     add them to the closure table, and returns the two callbacks expected by
     call_simple.

     The tupling is necesary because we want to free _both_ closures when
     one is called.

     The reply callback function exists once per type (it has to do
     serialization); the reject callback function is unique.
  *)

  let closures_to_reply_reject_callbacks env ts =
    assert (E.mode env = Flags.StubMode);
    let reply_name = "@callback<" ^ Serialization.typ_id (Type.Tup ts) ^ ">" in
    Func.define_built_in env reply_name ["env", I32Type] [] (fun env ->
        (* Look up closure *)
        let (set_closure, get_closure) = new_local env "closure" in
        G.i (LocalGet (nr 0l)) ^^
        ClosureTable.recall env ^^
        Arr.load_field 0l ^^ (* get the reply closure *)
        set_closure ^^
        get_closure ^^

        (* Deserialize arguments  *)
        Serialization.deserialize env ts ^^

        get_closure ^^
        Closure.call_closure env (List.length ts) 0 ^^

        message_cleanup env (Type.Shared Type.Write)
      );

    let reject_name = "@reject_callback" in
    Func.define_built_in env reject_name ["env", I32Type] [] (fun env ->
        (* Look up closure *)
        let (set_closure, get_closure) = new_local env "closure" in
        G.i (LocalGet (nr 0l)) ^^
        ClosureTable.recall env ^^
        Arr.load_field 1l ^^ (* get the reject closure *)
        set_closure ^^
        get_closure ^^

        (* Synthesize value of type `Error` *)
        E.trap_with env "reject_callback" ^^

        get_closure ^^
        Closure.call_closure env 1 0 ^^

        message_cleanup env (Type.Shared Type.Write)
      );

    (* The upper half of this function must not depend on the get_k and get_r
       parameters, so hide them from above (cute trick) *)
    fun get_k get_r ->
      let (set_cb_index, get_cb_index) = new_local env "cb_index" in
      (* store the tuple away *)
      Arr.lit env [get_k; get_r] ^^
      ClosureTable.remember env ^^
      set_cb_index ^^

      (* return arguments for the ic.call *)
      compile_unboxed_const (E.built_in env reply_name) ^^
      get_cb_index ^^
      compile_unboxed_const (E.built_in env reject_name) ^^
      get_cb_index

  let ignoring_callback env =
    assert (E.mode env = Flags.StubMode);
    let name = "@ignore_callback" in
    Func.define_built_in env name ["env", I32Type] [] (fun env -> G.nop);
    compile_unboxed_const (E.built_in env name)

  let ic_call env ts1 ts2 get_meth_pair get_arg get_k get_r =
    match E.mode env with
    | Flags.ICMode | Flags.StubMode ->

      (* The callee *)
      get_meth_pair ^^ Arr.load_field 0l ^^ Blob.as_ptr_len env ^^
      (* The method name *)
      get_meth_pair ^^ Arr.load_field 1l ^^ Blob.as_ptr_len env ^^
      (* The reply and reject callback *)
      closures_to_reply_reject_callbacks env ts2 get_k get_r ^^
      (* the data *)
      get_arg ^^ Serialization.serialize env ts1 ^^
      (* done! *)
      Dfinity.system_call env "ic0" "call_simple" ^^
      (* TODO: Check error code *)
      G.i Drop
    | _ -> assert false

  let ic_call_one_shot env ts get_meth_pair get_arg =
    match E.mode env with
    | Flags.ICMode | Flags.StubMode ->

      (* The callee *)
      get_meth_pair ^^ Arr.load_field 0l ^^ Blob.as_ptr_len env ^^
      (* The method name *)
      get_meth_pair ^^ Arr.load_field 1l ^^ Blob.as_ptr_len env ^^
      (* The reply callback *)
      ignoring_callback env ^^
      compile_unboxed_zero ^^
      (* The reject callback *)
      ignoring_callback env ^^
      compile_unboxed_zero ^^
      (* the data *)
      get_arg ^^ Serialization.serialize env ts ^^
      (* done! *)
      Dfinity.system_call env "ic0" "call_simple" ^^
      (* TODO: Check error code *)
      G.i Drop
    | _ -> assert false

  let export_async_method env =
    let name = Dfinity.async_method_name in
    begin match E.mode env with
    | Flags.ICMode | Flags.StubMode ->
      Func.define_built_in env name [] [] (fun env ->
        let (set_closure, get_closure) = new_local env "closure" in

        (* TODO: Check that it is us that is calling this *)

        (* Deserialize and look up closure argument *)
        Serialization.deserialize env [Type.Prim Type.Word32] ^^
        BoxedSmallWord.unbox env ^^
        ClosureTable.recall env ^^
        set_closure ^^ get_closure ^^ get_closure ^^
        Closure.call_closure env 0 0 ^^
        message_cleanup env (Type.Shared Type.Write)
      );

      let fi = E.built_in env name in
      E.add_export env (nr {
        name = Wasm.Utf8.decode ("canister_update " ^ name);
        edesc = nr (FuncExport (nr fi))
      })
    | _ -> ()
    end

end (* FuncDec *)


module PatCode = struct
  (* Pattern failure code on demand.

  Patterns in general can fail, so we want a block around them with a
  jump-label for the fail case. But many patterns cannot fail, in particular
  function arguments that are simple variables. In these cases, we do not want
  to create the block and the (unused) jump label. So we first generate the
  code, either as plain code (CannotFail) or as code with hole for code to fun
  in case of failure (CanFail).
  *)

  type patternCode =
    | CannotFail of G.t
    | CanFail of (G.t -> G.t)

  let (^^^) : patternCode -> patternCode -> patternCode = function
    | CannotFail is1 ->
      begin function
      | CannotFail is2 -> CannotFail (is1 ^^ is2)
      | CanFail is2 -> CanFail (fun k -> is1 ^^ is2 k)
      end
    | CanFail is1 ->
      begin function
      | CannotFail is2 -> CanFail (fun k ->  is1 k ^^ is2)
      | CanFail is2 -> CanFail (fun k -> is1 k ^^ is2 k)
      end

  let with_fail (fail_code : G.t) : patternCode -> G.t = function
    | CannotFail is -> is
    | CanFail is -> is fail_code

  let orElse : patternCode -> patternCode -> patternCode = function
    | CannotFail is1 -> fun _ -> CannotFail is1
    | CanFail is1 -> function
      | CanFail is2 -> CanFail (fun fail_code ->
          let inner_fail = G.new_depth_label () in
          let inner_fail_code = Bool.lit false ^^ G.branch_to_ inner_fail in
          G.labeled_block_ (ValBlockType (Some I32Type)) inner_fail (is1 inner_fail_code ^^ Bool.lit true) ^^
          G.if_ (ValBlockType None) G.nop (is2 fail_code)
        )
      | CannotFail is2 -> CannotFail (
          let inner_fail = G.new_depth_label () in
          let inner_fail_code = Bool.lit false ^^ G.branch_to_ inner_fail in
          G.labeled_block_ (ValBlockType (Some I32Type)) inner_fail (is1 inner_fail_code ^^ Bool.lit true) ^^
          G.if_ (ValBlockType None) G.nop is2
        )

  let orTrap env : patternCode -> G.t = function
    | CannotFail is -> is
    | CanFail is -> is (E.trap_with env "pattern failed")

  let with_region at = function
    | CannotFail is -> CannotFail (G.with_region at is)
    | CanFail is -> CanFail (fun k -> G.with_region at (is k))

end (* PatCode *)
open PatCode


(* All the code above is independent of the IR *)
open Ir

(* Compiling Error primitives *)
module Error = struct

  (* Opaque type `Error` is represented as concrete type `(ErrorCode,Text)` *)

  let compile_error env arg_instrs =
      SR.UnboxedTuple 2,
      Variant.inject env "error" Tuple.compile_unit ^^
      arg_instrs

  let compile_errorCode arg_instrs =
      SR.Vanilla,
      arg_instrs ^^
      Tuple.load_n (Int32.of_int 0)

  let compile_errorMessage arg_instrs =
      SR.Vanilla,
      arg_instrs ^^
      Tuple.load_n (Int32.of_int 1)

  let compile_make_error arg_instrs1 arg_instrs2 =
      SR.UnboxedTuple 2,
      arg_instrs1 ^^
      arg_instrs2

end

module AllocHow = struct
  (*
  When compiling a (recursive) block, we need to do a dependency analysis, to
  find out which names need to be heap-allocated, which local-allocated and which
  are simply static functions. The goal is to avoid dynamic allocation where
  possible (and use locals), and to avoid turning function references into closures.

  The rules for non-top-level-blocks are:
  - functions are static, unless they capture something that is not a static
    function or a static heap allocation.
  - everything that is captured before it is defined needs to be dynamically
    heap-allocated, unless it is a static function
  - everything that is mutable and captured needs to be dynamically heap-allocated
  - the rest can be local (immutable things can be put into closures by values)

  These rules require a fixed-point analysis.

  For the top-level blocks the rules are simpler
  - all functions are static
  - everything that is captured in a function is statically heap allocated
  - everything else is a local

  We represent this as a lattice as follows:
  *)

  module M = Freevars.M
  module S = Freevars.S

  type nonStatic = LocalImmut | LocalMut | StoreHeap | StoreStatic
  type allocHow = nonStatic M.t (* absent means static *)

  let join : allocHow -> allocHow -> allocHow =
    M.union (fun _ x y -> Some (match x, y with
      | StoreStatic, StoreHeap -> assert false
      | StoreHeap, StoreStatic -> assert false
      | _, StoreHeap -> StoreHeap
      | StoreHeap, _  -> StoreHeap
      | _, StoreStatic -> StoreStatic
      | StoreStatic, _  -> StoreStatic
      | LocalMut, _ -> LocalMut
      | _, LocalMut -> LocalMut
      | LocalImmut, LocalImmut -> LocalImmut
    ))

  type lvl = TopLvl | NotTopLvl

  let map_of_set x s = S.fold (fun v m -> M.add v x m) s M.empty
  let set_of_map m = M.fold (fun v _ m -> S.add v m) m S.empty

  let is_static ae how f =
    (* Does this capture nothing from outside? *)
    (S.is_empty (S.inter
      (Freevars.captured_vars f)
      (set_of_map (M.filter (fun _ x -> not (VarLoc.is_non_local x)) (ae.VarEnv.vars))))) &&
    (* Does this capture nothing non-static from here? *)
    (S.is_empty (S.inter
      (Freevars.captured_vars f)
      (set_of_map (M.filter (fun _ h -> h != StoreStatic) how))))

  let is_func_exp exp = match exp.it with
    | FuncE _ -> true
    | _ -> false

  let is_static_exp env how0 exp =
    (* Functions are static when they do not capture anything *)
    if is_func_exp exp
    then is_static env how0 (Freevars.exp exp)
    else false

  let is_local_mut _ = function
    | LocalMut -> true
    | _ -> false

  let dec_local env (seen, how0) dec =
    let (f,d) = Freevars.dec dec in
    let captured = Freevars.captured_vars f in

    (* Which allocation is required for the things defined here? *)
    let how1 = match dec.it with
      (* Mutable variables are, well, mutable *)
      | VarD _ ->
      map_of_set LocalMut d
      (* Static functions in an let-expression *)
      | LetD ({it = VarP _; _}, e) when is_static_exp env how0 e ->
      M.empty
      (* Everything else needs at least a local *)
      | _ ->
      map_of_set LocalImmut d in

    (* Do we capture anything unseen, but non-static?
       These need to be heap-allocated.
    *)
    let how2 =
      map_of_set StoreHeap
        (S.inter
          (set_of_map how0)
          (S.diff (Freevars.captured_vars f) seen)) in

    (* Do we capture anything else?
       For local blocks, mutable things must be heap allocated.
    *)
    let how3 =
      map_of_set StoreHeap
        (S.inter (set_of_map (M.filter is_local_mut how0)) captured) in

    let how = List.fold_left join M.empty [how0; how1; how2; how3] in
    let seen' = S.union seen d
    in (seen', how)

  let decs_local env decs captured_in_body : allocHow =
    let rec go how =
      let _seen, how1 = List.fold_left (dec_local env) (S.empty, how) decs in
      let how2 = map_of_set StoreHeap
        (S.inter (set_of_map (M.filter is_local_mut how1)) captured_in_body) in
      let how' = join how1 how2 in
      if M.equal (=) how how' then how else go how' in
    go M.empty

  let decs_top_lvl env decs captured_in_body : allocHow =
    let how0 = M.empty in
    (* All non-function are at least locals *)
    let how1 =
      let go how dec =
        let (f,d) = Freevars.dec dec in
        match dec.it with
          | LetD ({it = VarP _; _}, e) when is_func_exp e -> how
          | _ -> join how (map_of_set LocalMut d) in
      List.fold_left go how0 decs in
    (* All captured non-functions are heap allocated *)
    let how2 = join how1 (map_of_set StoreStatic (S.inter (set_of_map how1) captured_in_body)) in
    let how3 =
      let go how dec =
        let (f,d) = Freevars.dec dec in
        let captured = Freevars.captured_vars f in
        join how (map_of_set StoreStatic (S.inter (set_of_map how1) captured)) in
      List.fold_left go how2 decs in
    how3

  let decs env lvl decs captured_in_body : allocHow = match lvl with
    | TopLvl -> decs_top_lvl env decs captured_in_body
    | NotTopLvl -> decs_local env decs captured_in_body

  (* Functions to extend the environment (and possibly allocate memory)
     based on how we want to store them. *)
  let add_how env ae name : nonStatic option -> VarEnv.t * G.t = function
    | Some LocalImmut | Some LocalMut ->
      let (ae1, i) = VarEnv.add_direct_local env ae name in
      (ae1, G.nop)
    | Some StoreHeap ->
      let (ae1, i) = VarEnv.add_local_with_offset env ae name 1l in
      let alloc_code =
        Tagged.obj env Tagged.MutBox [ compile_unboxed_zero ] ^^
        G.i (LocalSet (nr i)) in
      (ae1, alloc_code)
    | Some StoreStatic ->
      let tag = bytes_of_int32 (Tagged.int_of_tag Tagged.MutBox) in
      let zero = bytes_of_int32 0l in
      let ptr = E.add_mutable_static_bytes env (tag ^ zero) in
      let ae1 = VarEnv.add_local_static ae name ptr in
      (ae1, G.nop)
    | None -> (ae, G.nop)

  let add_local env ae how name =
    add_how env ae name (M.find_opt name how)

end (* AllocHow *)

(* The actual compiler code that looks at the AST *)

let nat64_to_int64 n =
  let open Big_int in
  let twoRaised63 = power_int_positive_int 2 63 in
  let q, r = quomod_big_int (Value.Nat64.to_big_int n) twoRaised63 in
  if sign_big_int q = 0 then r else sub_big_int r twoRaised63

let compile_lit env lit =
  try match lit with
    (* Booleans are directly in Vanilla representation *)
    | BoolLit false -> SR.bool, Bool.lit false
    | BoolLit true ->  SR.bool, Bool.lit true
    | IntLit n
    | NatLit n      -> SR.Vanilla, BigNum.compile_lit env n
    | Word8Lit n    -> SR.Vanilla, compile_unboxed_const (Value.Word8.to_bits n)
    | Word16Lit n   -> SR.Vanilla, compile_unboxed_const (Value.Word16.to_bits n)
    | Word32Lit n   -> SR.UnboxedWord32, compile_unboxed_const n
    | Word64Lit n   -> SR.UnboxedWord64, compile_const_64 n
    | Int8Lit n     -> SR.Vanilla, UnboxedSmallWord.lit env Type.Int8 (Value.Int_8.to_int n)
    | Nat8Lit n     -> SR.Vanilla, UnboxedSmallWord.lit env Type.Nat8 (Value.Nat8.to_int n)
    | Int16Lit n    -> SR.Vanilla, UnboxedSmallWord.lit env Type.Int16 (Value.Int_16.to_int n)
    | Nat16Lit n    -> SR.Vanilla, UnboxedSmallWord.lit env Type.Nat16 (Value.Nat16.to_int n)
    | Int32Lit n    -> SR.UnboxedWord32, compile_unboxed_const (Int32.of_int (Value.Int_32.to_int n))
    | Nat32Lit n    -> SR.UnboxedWord32, compile_unboxed_const (Int32.of_int (Value.Nat32.to_int n))
    | Int64Lit n    -> SR.UnboxedWord64, compile_const_64 (Big_int.int64_of_big_int (Value.Int_64.to_big_int n))
    | Nat64Lit n    -> SR.UnboxedWord64, compile_const_64 (Big_int.int64_of_big_int (nat64_to_int64 n))
    | CharLit c     -> SR.Vanilla, compile_unboxed_const Int32.(shift_left (of_int c) 8)
    | NullLit       -> SR.Vanilla, Opt.null
    | TextLit t     -> SR.Vanilla, Blob.lit env t
    | _ -> todo_trap_SR env "compile_lit" (Arrange_ir.lit lit)
  with Failure _ ->
    Printf.eprintf "compile_lit: Overflow in literal %s\n" (string_of_lit lit);
    SR.Unreachable, E.trap_with env "static literal overflow"

let compile_lit_as env sr_out lit =
  let sr_in, code = compile_lit env lit in
  code ^^ StackRep.adjust env sr_in sr_out

let prim_of_typ ty = match Type.normalize ty with
  | Type.Prim ty -> ty
  | _ -> assert false

(* helper, traps with message *)
let then_arithmetic_overflow env =
  E.then_trap_with env "arithmetic overflow"

(* The first returned StackRep is for the arguments (expected), the second for the results (produced) *)
let compile_unop env t op =
  let open Operator in
  match op, t with
  | _, Type.Non ->
    SR.Vanilla, SR.Unreachable, G.i Unreachable
  | NegOp, Type.(Prim Int) ->
    SR.Vanilla, SR.Vanilla,
    BigNum.compile_neg env
  | NegOp, Type.(Prim Word64) ->
    SR.UnboxedWord64, SR.UnboxedWord64,
    Func.share_code1 env "neg" ("n", I64Type) [I64Type] (fun env get_n ->
      compile_const_64 0L ^^
      get_n ^^
      G.i (Binary (Wasm.Values.I64 I64Op.Sub))
    )
  | NegOp, Type.(Prim Int64) ->
      SR.UnboxedWord64, SR.UnboxedWord64,
      Func.share_code1 env "neg_trap" ("n", I64Type) [I64Type] (fun env get_n ->
        get_n ^^
        compile_eq64_const 0x8000000000000000L ^^
        then_arithmetic_overflow env ^^
        compile_const_64 0L ^^
        get_n ^^
        G.i (Binary (Wasm.Values.I64 I64Op.Sub))
      )
  | NegOp, Type.(Prim (Word8 | Word16 | Word32)) ->
    StackRep.of_type t, StackRep.of_type t,
    Func.share_code1 env "neg32" ("n", I32Type) [I32Type] (fun env get_n ->
      compile_unboxed_zero ^^
      get_n ^^
      G.i (Binary (Wasm.Values.I32 I32Op.Sub))
    )
  | NegOp, Type.(Prim (Int8 | Int16 | Int32)) ->
    StackRep.of_type t, StackRep.of_type t,
    Func.share_code1 env "neg32_trap" ("n", I32Type) [I32Type] (fun env get_n ->
      get_n ^^
      compile_eq_const 0x80000000l ^^
      then_arithmetic_overflow env ^^
      compile_unboxed_zero ^^
      get_n ^^
      G.i (Binary (Wasm.Values.I32 I32Op.Sub))
    )
  | NotOp, Type.(Prim Word64) ->
     SR.UnboxedWord64, SR.UnboxedWord64,
     compile_const_64 (-1L) ^^
     G.i (Binary (Wasm.Values.I64 I64Op.Xor))
  | NotOp, Type.Prim Type.(Word8 | Word16 | Word32 as ty) ->
     StackRep.of_type t, StackRep.of_type t,
     compile_unboxed_const (UnboxedSmallWord.mask_of_type ty) ^^
     G.i (Binary (Wasm.Values.I32 I32Op.Xor))
  | _ ->
    todo "compile_unop" (Arrange_ops.unop op)
      (SR.Vanilla, SR.Unreachable, E.trap_with env "TODO: compile_unop")

(* Logarithmic helpers for deciding whether we can carry out operations in constant bitwidth *)

(* Compiling Int/Nat64 ops by conversion to/from BigNum. This is currently
   consing a lot, but compact bignums will get back efficiency as soon as
   they are merged. *)

(* helper, traps with message *)
let else_arithmetic_overflow env =
  E.else_trap_with env "arithmetic overflow"

(* helpers to decide if Int64 arithmetic can be carried out on the fast path *)
let additiveInt64_shortcut fast env get_a get_b slow =
  get_a ^^ get_a ^^ compile_shl64_const 1L ^^ G.i (Binary (Wasm.Values.I64 I64Op.Xor)) ^^ compile_shrU64_const 63L ^^
  get_b ^^ get_b ^^ compile_shl64_const 1L ^^ G.i (Binary (Wasm.Values.I64 I64Op.Xor)) ^^ compile_shrU64_const 63L ^^
  G.i (Binary (Wasm.Values.I64 I64Op.Or)) ^^
  G.i (Test (Wasm.Values.I64 I64Op.Eqz)) ^^
  G.if_ (ValBlockType (Some I64Type))
    (get_a ^^ get_b ^^ fast)
    slow

let mulInt64_shortcut fast env get_a get_b slow =
  get_a ^^ get_a ^^ compile_shl64_const 1L ^^ G.i (Binary (Wasm.Values.I64 I64Op.Xor)) ^^ G.i (Unary (Wasm.Values.I64 I64Op.Clz)) ^^
  get_b ^^ get_b ^^ compile_shl64_const 1L ^^ G.i (Binary (Wasm.Values.I64 I64Op.Xor)) ^^ G.i (Unary (Wasm.Values.I64 I64Op.Clz)) ^^
  G.i (Binary (Wasm.Values.I64 I64Op.Add)) ^^
  compile_const_64 65L ^^ G.i (Compare (Wasm.Values.I64 I64Op.GeU)) ^^
  G.if_ (ValBlockType (Some I64Type))
    (get_a ^^ get_b ^^ fast)
    slow

let powInt64_shortcut fast env get_a get_b slow =
  get_b ^^ G.i (Test (Wasm.Values.I64 I64Op.Eqz)) ^^
  G.if_ (ValBlockType (Some I64Type))
    (compile_const_64 1L) (* ^0 *)
    begin (* ^(1+n) *)
      get_a ^^ compile_const_64 (-1L) ^^ G.i (Compare (Wasm.Values.I64 I64Op.Eq)) ^^
      G.if_ (ValBlockType (Some I64Type))
        begin (* -1 ** (1+exp) == if even (1+exp) then 1 else -1 *)
          get_b ^^ compile_const_64 1L ^^
          G.i (Binary (Wasm.Values.I64 I64Op.And)) ^^ G.i (Test (Wasm.Values.I64 I64Op.Eqz)) ^^
          G.if_ (ValBlockType (Some I64Type))
            (compile_const_64 1L)
            get_a
        end
        begin
          get_a ^^ compile_shrS64_const 1L ^^
          G.i (Test (Wasm.Values.I64 I64Op.Eqz)) ^^
          G.if_ (ValBlockType (Some I64Type))
            get_a (* {0,1}^(1+n) *)
            begin
              get_b ^^ compile_const_64 64L ^^
              G.i (Compare (Wasm.Values.I64 I64Op.GeU)) ^^ then_arithmetic_overflow env ^^
              get_a ^^ get_a ^^ compile_shl64_const 1L ^^ G.i (Binary (Wasm.Values.I64 I64Op.Xor)) ^^
              G.i (Unary (Wasm.Values.I64 I64Op.Clz)) ^^ compile_sub64_const 63L ^^
              get_b ^^ G.i (Binary (Wasm.Values.I64 I64Op.Mul)) ^^
              compile_const_64 (-63L) ^^ G.i (Compare (Wasm.Values.I64 I64Op.GeS)) ^^
              G.if_ (ValBlockType (Some I64Type))
                (get_a ^^ get_b ^^ fast)
                slow
            end
        end
    end


(* kernel for Int64 arithmetic, invokes estimator for fast path *)
let compile_Int64_kernel env name op shortcut =
  Func.share_code2 env (UnboxedSmallWord.name_of_type Type.Int64 name)
    (("a", I64Type), ("b", I64Type)) [I64Type]
    BigNum.(fun env get_a get_b ->
    shortcut
      env
      get_a
      get_b
      begin
        let (set_res, get_res) = new_local env "res" in
        get_a ^^ from_signed_word64 env ^^
        get_b ^^ from_signed_word64 env ^^
        op env ^^
        set_res ^^ get_res ^^
        fits_signed_bits env 64 ^^
        else_arithmetic_overflow env ^^
        get_res ^^ truncate_to_word64 env
      end)


(* helpers to decide if Nat64 arithmetic can be carried out on the fast path *)
let additiveNat64_shortcut fast env get_a get_b slow =
  get_a ^^ compile_shrU64_const 62L ^^
  get_b ^^ compile_shrU64_const 62L ^^
  G.i (Binary (Wasm.Values.I64 I64Op.Or)) ^^
  G.i (Test (Wasm.Values.I64 I64Op.Eqz)) ^^
  G.if_ (ValBlockType (Some I64Type))
    (get_a ^^ get_b ^^ fast)
    slow

let mulNat64_shortcut fast env get_a get_b slow =
  get_a ^^ G.i (Unary (Wasm.Values.I64 I64Op.Clz)) ^^
  get_b ^^ G.i (Unary (Wasm.Values.I64 I64Op.Clz)) ^^
  G.i (Binary (Wasm.Values.I64 I64Op.Add)) ^^
  compile_const_64 64L ^^ G.i (Compare (Wasm.Values.I64 I64Op.GeU)) ^^
  G.if_ (ValBlockType (Some I64Type))
    (get_a ^^ get_b ^^ fast)
    slow

let powNat64_shortcut fast env get_a get_b slow =
  get_b ^^ G.i (Test (Wasm.Values.I64 I64Op.Eqz)) ^^
  G.if_ (ValBlockType (Some I64Type))
    (compile_const_64 1L) (* ^0 *)
    begin (* ^(1+n) *)
      get_a ^^ compile_shrU64_const 1L ^^
      G.i (Test (Wasm.Values.I64 I64Op.Eqz)) ^^
      G.if_ (ValBlockType (Some I64Type))
        get_a (* {0,1}^(1+n) *)
        begin
          get_b ^^ compile_const_64 64L ^^ G.i (Compare (Wasm.Values.I64 I64Op.GeU)) ^^ then_arithmetic_overflow env ^^
          get_a ^^ G.i (Unary (Wasm.Values.I64 I64Op.Clz)) ^^ compile_sub64_const 64L ^^
          get_b ^^ G.i (Binary (Wasm.Values.I64 I64Op.Mul)) ^^ compile_const_64 (-64L) ^^ G.i (Compare (Wasm.Values.I64 I64Op.GeS)) ^^
          G.if_ (ValBlockType (Some I64Type))
            (get_a ^^ get_b ^^ fast)
            slow
        end
    end


(* kernel for Nat64 arithmetic, invokes estimator for fast path *)
let compile_Nat64_kernel env name op shortcut =
  Func.share_code2 env (UnboxedSmallWord.name_of_type Type.Nat64 name)
    (("a", I64Type), ("b", I64Type)) [I64Type]
    BigNum.(fun env get_a get_b ->
    shortcut
      env
      get_a
      get_b
      begin
        let (set_res, get_res) = new_local env "res" in
        get_a ^^ from_word64 env ^^
        get_b ^^ from_word64 env ^^
        op env ^^
        set_res ^^ get_res ^^
        fits_unsigned_bits env 64 ^^
        else_arithmetic_overflow env ^^
        get_res ^^ truncate_to_word64 env
      end)


(* Compiling Int/Nat32 ops by conversion to/from i64. *)

(* helper, expects i64 on stack *)
let enforce_32_unsigned_bits env =
  compile_bitand64_const 0xFFFFFFFF00000000L ^^
  G.i (Test (Wasm.Values.I64 I64Op.Eqz)) ^^
  else_arithmetic_overflow env

(* helper, expects two identical i64s on stack *)
let enforce_32_signed_bits env =
  compile_shl64_const 1L ^^
  G.i (Binary (Wasm.Values.I64 I64Op.Xor)) ^^
  enforce_32_unsigned_bits env

let compile_Int32_kernel env name op =
     Func.share_code2 env (UnboxedSmallWord.name_of_type Type.Int32 name)
       (("a", I32Type), ("b", I32Type)) [I32Type]
       (fun env get_a get_b ->
         let (set_res, get_res) = new_local64 env "res" in
         get_a ^^ G.i (Convert (Wasm.Values.I64 I64Op.ExtendSI32)) ^^
         get_b ^^ G.i (Convert (Wasm.Values.I64 I64Op.ExtendSI32)) ^^
         G.i (Binary (Wasm.Values.I64 op)) ^^
         set_res ^^ get_res ^^ get_res ^^
         enforce_32_signed_bits env ^^
         get_res ^^ G.i (Convert (Wasm.Values.I32 I32Op.WrapI64)))

let compile_Nat32_kernel env name op =
     Func.share_code2 env (UnboxedSmallWord.name_of_type Type.Nat32 name)
       (("a", I32Type), ("b", I32Type)) [I32Type]
       (fun env get_a get_b ->
         let (set_res, get_res) = new_local64 env "res" in
         get_a ^^ G.i (Convert (Wasm.Values.I64 I64Op.ExtendUI32)) ^^
         get_b ^^ G.i (Convert (Wasm.Values.I64 I64Op.ExtendUI32)) ^^
         G.i (Binary (Wasm.Values.I64 op)) ^^
         set_res ^^ get_res ^^
         enforce_32_unsigned_bits env ^^
         get_res ^^ G.i (Convert (Wasm.Values.I32 I32Op.WrapI64)))

(* Customisable kernels for 8/16bit arithmetic via 32 bits. *)

(* helper, expects i32 on stack *)
let enforce_unsigned_bits env n =
  compile_bitand_const Int32.(shift_left minus_one n) ^^
  then_arithmetic_overflow env

let enforce_16_unsigned_bits env = enforce_unsigned_bits env 16

(* helper, expects two identical i32s on stack *)
let enforce_signed_bits env n =
  compile_shl_const 1l ^^ G.i (Binary (Wasm.Values.I32 I32Op.Xor)) ^^
  enforce_unsigned_bits env n

let enforce_16_signed_bits env = enforce_signed_bits env 16

let compile_smallInt_kernel' env ty name op =
  Func.share_code2 env (UnboxedSmallWord.name_of_type ty name)
    (("a", I32Type), ("b", I32Type)) [I32Type]
    (fun env get_a get_b ->
      let (set_res, get_res) = new_local env "res" in
      get_a ^^ compile_shrS_const 16l ^^
      get_b ^^ compile_shrS_const 16l ^^
      op ^^
      set_res ^^ get_res ^^ get_res ^^
      enforce_16_signed_bits env ^^
      get_res ^^ compile_shl_const 16l)

let compile_smallInt_kernel env ty name op =
  compile_smallInt_kernel' env ty name (G.i (Binary (Wasm.Values.I32 op)))

let compile_smallNat_kernel' env ty name op =
  Func.share_code2 env (UnboxedSmallWord.name_of_type ty name)
    (("a", I32Type), ("b", I32Type)) [I32Type]
    (fun env get_a get_b ->
      let (set_res, get_res) = new_local env "res" in
      get_a ^^ compile_shrU_const 16l ^^
      get_b ^^ compile_shrU_const 16l ^^
      op ^^
      set_res ^^ get_res ^^
      enforce_16_unsigned_bits env ^^
      get_res ^^ compile_shl_const 16l)

let compile_smallNat_kernel env ty name op =
  compile_smallNat_kernel' env ty name (G.i (Binary (Wasm.Values.I32 op)))

(* The first returned StackRep is for the arguments (expected), the second for the results (produced) *)
let compile_binop env t op =
  if t = Type.Non then SR.Vanilla, SR.Unreachable, G.i Unreachable else
  StackRep.of_type t,
  StackRep.of_type t,
  Operator.(match t, op with
  | Type.(Prim (Nat | Int)),                  AddOp -> BigNum.compile_add env
  | Type.(Prim Word64),                       AddOp -> G.i (Binary (Wasm.Values.I64 I64Op.Add))
  | Type.(Prim Int64),                        AddOp ->
    compile_Int64_kernel env "add" BigNum.compile_add
      (additiveInt64_shortcut (G.i (Binary (Wasm.Values.I64 I64Op.Add))))
  | Type.(Prim Nat64),                        AddOp ->
    compile_Nat64_kernel env "add" BigNum.compile_add
      (additiveNat64_shortcut (G.i (Binary (Wasm.Values.I64 I64Op.Add))))
  | Type.(Prim Nat),                          SubOp -> BigNum.compile_unsigned_sub env
  | Type.(Prim Int),                          SubOp -> BigNum.compile_signed_sub env
  | Type.(Prim (Nat | Int)),                  MulOp -> BigNum.compile_mul env
  | Type.(Prim Word64),                       MulOp -> G.i (Binary (Wasm.Values.I64 I64Op.Mul))
  | Type.(Prim Int64),                        MulOp ->
    compile_Int64_kernel env "mul" BigNum.compile_mul
      (mulInt64_shortcut (G.i (Binary (Wasm.Values.I64 I64Op.Mul))))
  | Type.(Prim Nat64),                        MulOp ->
    compile_Nat64_kernel env "mul" BigNum.compile_mul
      (mulNat64_shortcut (G.i (Binary (Wasm.Values.I64 I64Op.Mul))))
  | Type.(Prim (Nat64|Word64)),               DivOp -> G.i (Binary (Wasm.Values.I64 I64Op.DivU))
  | Type.(Prim (Nat64|Word64)),               ModOp -> G.i (Binary (Wasm.Values.I64 I64Op.RemU))
  | Type.(Prim Int64),                        DivOp -> G.i (Binary (Wasm.Values.I64 I64Op.DivS))
  | Type.(Prim Int64),                        ModOp -> G.i (Binary (Wasm.Values.I64 I64Op.RemS))
  | Type.(Prim Nat),                          DivOp -> BigNum.compile_unsigned_div env
  | Type.(Prim Nat),                          ModOp -> BigNum.compile_unsigned_rem env
  | Type.(Prim Word64),                       SubOp -> G.i (Binary (Wasm.Values.I64 I64Op.Sub))
  | Type.(Prim Int64),                        SubOp ->
    compile_Int64_kernel env "sub" BigNum.compile_signed_sub
      (additiveInt64_shortcut (G.i (Binary (Wasm.Values.I64 I64Op.Sub))))
  | Type.(Prim Nat64),                        SubOp ->
    compile_Nat64_kernel env "sub" BigNum.compile_unsigned_sub
      (fun env get_a get_b ->
        additiveNat64_shortcut
          (G.i (Compare (Wasm.Values.I64 I64Op.GeU)) ^^
           else_arithmetic_overflow env ^^
           get_a ^^ get_b ^^ G.i (Binary (Wasm.Values.I64 I64Op.Sub)))
          env get_a get_b)
  | Type.(Prim Int),                          DivOp -> BigNum.compile_signed_div env
  | Type.(Prim Int),                          ModOp -> BigNum.compile_signed_mod env

  | Type.Prim Type.(Word8 | Word16 | Word32), AddOp -> G.i (Binary (Wasm.Values.I32 I32Op.Add))
  | Type.(Prim Int32),                        AddOp -> compile_Int32_kernel env "add" I64Op.Add
  | Type.Prim Type.(Int8 | Int16 as ty),      AddOp -> compile_smallInt_kernel env ty "add" I32Op.Add
  | Type.(Prim Nat32),                        AddOp -> compile_Nat32_kernel env "add" I64Op.Add
  | Type.Prim Type.(Nat8 | Nat16 as ty),      AddOp -> compile_smallNat_kernel env ty "add" I32Op.Add
  | Type.Prim Type.(Word8 | Word16 | Word32), SubOp -> G.i (Binary (Wasm.Values.I32 I32Op.Sub))
  | Type.(Prim Int32),                        SubOp -> compile_Int32_kernel env "sub" I64Op.Sub
  | Type.(Prim (Int8|Int16 as ty)),           SubOp -> compile_smallInt_kernel env ty "sub" I32Op.Sub
  | Type.(Prim Nat32),                        SubOp -> compile_Nat32_kernel env "sub" I64Op.Sub
  | Type.(Prim (Nat8|Nat16 as ty)),           SubOp -> compile_smallNat_kernel env ty "sub" I32Op.Sub
  | Type.(Prim (Word8|Word16|Word32 as ty)),  MulOp -> UnboxedSmallWord.compile_word_mul env ty
  | Type.(Prim Int32),                        MulOp -> compile_Int32_kernel env "mul" I64Op.Mul
  | Type.(Prim Int16),                        MulOp -> compile_smallInt_kernel env Type.Int16 "mul" I32Op.Mul
  | Type.(Prim Int8),                         MulOp -> compile_smallInt_kernel' env Type.Int8 "mul"
                                                         (compile_shrS_const 8l ^^ G.i (Binary (Wasm.Values.I32 I32Op.Mul)))
  | Type.(Prim Nat32),                        MulOp -> compile_Nat32_kernel env "mul" I64Op.Mul
  | Type.(Prim Nat16),                        MulOp -> compile_smallNat_kernel env Type.Nat16 "mul" I32Op.Mul
  | Type.(Prim Nat8),                         MulOp -> compile_smallNat_kernel' env Type.Nat8 "mul"
                                                         (compile_shrU_const 8l ^^ G.i (Binary (Wasm.Values.I32 I32Op.Mul)))
  | Type.(Prim (Nat8|Nat16|Nat32|Word8|Word16|Word32 as ty)), DivOp ->
    G.i (Binary (Wasm.Values.I32 I32Op.DivU)) ^^
    UnboxedSmallWord.msb_adjust ty
  | Type.(Prim (Nat8|Nat16|Nat32|Word8|Word16|Word32)), ModOp -> G.i (Binary (Wasm.Values.I32 I32Op.RemU))
  | Type.(Prim Int32),                        DivOp -> G.i (Binary (Wasm.Values.I32 I32Op.DivS))
  | Type.(Prim (Int8|Int16 as ty)),           DivOp ->
    Func.share_code2 env (UnboxedSmallWord.name_of_type ty "div")
      (("a", I32Type), ("b", I32Type)) [I32Type]
      (fun env get_a get_b ->
        let (set_res, get_res) = new_local env "res" in
        get_a ^^ get_b ^^ G.i (Binary (Wasm.Values.I32 I32Op.DivS)) ^^
        UnboxedSmallWord.msb_adjust ty ^^ set_res ^^
        get_a ^^ compile_eq_const 0x80000000l ^^
        G.if_ (StackRep.to_block_type env SR.UnboxedWord32)
          begin
            get_b ^^ UnboxedSmallWord.lsb_adjust ty ^^ compile_eq_const (-1l) ^^
            G.if_ (StackRep.to_block_type env SR.UnboxedWord32)
              (G.i Unreachable)
              get_res
          end
          get_res)
  | Type.(Prim (Int8|Int16|Int32)),           ModOp -> G.i (Binary (Wasm.Values.I32 I32Op.RemS))
  | Type.(Prim (Word8|Word16|Word32 as ty)),  PowOp -> UnboxedSmallWord.compile_word_power env ty
  | Type.(Prim ((Nat8|Nat16) as ty)),         PowOp ->
    Func.share_code2 env (UnboxedSmallWord.name_of_type ty "pow")
      (("n", I32Type), ("exp", I32Type)) [I32Type]
      (fun env get_n get_exp ->
        let (set_res, get_res) = new_local env "res" in
        let bits = UnboxedSmallWord.bits_of_type ty in
        get_exp ^^
        G.if_ (ValBlockType (Some I32Type))
          begin
            get_n ^^ compile_shrU_const Int32.(sub 33l (of_int bits)) ^^
            G.if_ (ValBlockType (Some I32Type))
              begin
                unsigned_dynamics get_n ^^ compile_sub_const (Int32.of_int bits) ^^
                get_exp ^^ UnboxedSmallWord.lsb_adjust ty ^^ G.i (Binary (Wasm.Values.I32 I32Op.Mul)) ^^
                compile_unboxed_const (-30l) ^^
                G.i (Compare (Wasm.Values.I32 I32Op.LtS)) ^^ then_arithmetic_overflow env ^^
                get_n ^^ UnboxedSmallWord.lsb_adjust ty ^^
                get_exp ^^ UnboxedSmallWord.lsb_adjust ty ^^
                UnboxedSmallWord.compile_word_power env Type.Word32 ^^ set_res ^^
                get_res ^^ enforce_unsigned_bits env bits ^^
                get_res ^^ UnboxedSmallWord.msb_adjust ty
              end
              get_n (* n@{0,1} ** (1+exp) == n *)
          end
          (compile_unboxed_const
             Int32.(shift_left one (to_int (UnboxedSmallWord.shift_of_type ty))))) (* x ** 0 == 1 *)
  | Type.(Prim Nat32),                        PowOp ->
    Func.share_code2 env (UnboxedSmallWord.name_of_type Type.Nat32 "pow")
      (("n", I32Type), ("exp", I32Type)) [I32Type]
      (fun env get_n get_exp ->
        let (set_res, get_res) = new_local64 env "res" in
        get_exp ^^
        G.if_ (ValBlockType (Some I32Type))
          begin
            get_n ^^ compile_shrU_const 1l ^^
            G.if_ (ValBlockType (Some I32Type))
              begin
                get_exp ^^ compile_unboxed_const 32l ^^
                G.i (Compare (Wasm.Values.I32 I32Op.GeU)) ^^ then_arithmetic_overflow env ^^
                unsigned_dynamics get_n ^^ compile_sub_const 32l ^^
                get_exp ^^ UnboxedSmallWord.lsb_adjust Type.Nat32 ^^ G.i (Binary (Wasm.Values.I32 I32Op.Mul)) ^^
                compile_unboxed_const (-62l) ^^
                G.i (Compare (Wasm.Values.I32 I32Op.LtS)) ^^ then_arithmetic_overflow env ^^
                get_n ^^ G.i (Convert (Wasm.Values.I64 I64Op.ExtendUI32)) ^^
                get_exp ^^ G.i (Convert (Wasm.Values.I64 I64Op.ExtendUI32)) ^^
                BoxedWord64.compile_unsigned_pow env ^^
                set_res ^^ get_res ^^ enforce_32_unsigned_bits env ^^
                get_res ^^ G.i (Convert (Wasm.Values.I32 I32Op.WrapI64))
              end
              get_n (* n@{0,1} ** (1+exp) == n *)
          end
          compile_unboxed_one) (* x ** 0 == 1 *)
  | Type.(Prim ((Int8|Int16) as ty)),         PowOp ->
    Func.share_code2 env (UnboxedSmallWord.name_of_type ty "pow")
      (("n", I32Type), ("exp", I32Type)) [I32Type]
      (fun env get_n get_exp ->
        let (set_res, get_res) = new_local env "res" in
        let bits = UnboxedSmallWord.bits_of_type ty in
        get_exp ^^ compile_unboxed_zero ^^
        G.i (Compare (Wasm.Values.I32 I32Op.LtS)) ^^ E.then_trap_with env "negative power" ^^
        get_exp ^^
        G.if_ (ValBlockType (Some I32Type))
          begin
            get_n ^^ compile_shrS_const Int32.(sub 33l (of_int bits)) ^^
            G.if_ (ValBlockType (Some I32Type))
              begin
                signed_dynamics get_n ^^ compile_sub_const (Int32.of_int (bits - 1)) ^^
                get_exp ^^ UnboxedSmallWord.lsb_adjust ty ^^ G.i (Binary (Wasm.Values.I32 I32Op.Mul)) ^^
                compile_unboxed_const (-30l) ^^
                G.i (Compare (Wasm.Values.I32 I32Op.LtS)) ^^ then_arithmetic_overflow env ^^
                get_n ^^ UnboxedSmallWord.lsb_adjust ty ^^
                get_exp ^^ UnboxedSmallWord.lsb_adjust ty ^^
                UnboxedSmallWord.compile_word_power env Type.Word32 ^^
                set_res ^^ get_res ^^ get_res ^^ enforce_signed_bits env bits ^^
                get_res ^^ UnboxedSmallWord.msb_adjust ty
              end
              get_n (* n@{0,1} ** (1+exp) == n *)
          end
          (compile_unboxed_const
             Int32.(shift_left one (to_int (UnboxedSmallWord.shift_of_type ty))))) (* x ** 0 == 1 *)
  | Type.(Prim Int32),                        PowOp ->
    Func.share_code2 env (UnboxedSmallWord.name_of_type Type.Int32 "pow")
      (("n", I32Type), ("exp", I32Type)) [I32Type]
      (fun env get_n get_exp ->
        let (set_res, get_res) = new_local64 env "res" in
        get_exp ^^ compile_unboxed_zero ^^
        G.i (Compare (Wasm.Values.I32 I32Op.LtS)) ^^ E.then_trap_with env "negative power" ^^
        get_exp ^^
        G.if_ (ValBlockType (Some I32Type))
          begin
            get_n ^^ compile_unboxed_one ^^ G.i (Compare (Wasm.Values.I32 I32Op.LeS)) ^^
            get_n ^^ compile_unboxed_const (-1l) ^^ G.i (Compare (Wasm.Values.I32 I32Op.GeS)) ^^
            G.i (Binary (Wasm.Values.I32 I32Op.And)) ^^
            G.if_ (ValBlockType (Some I32Type))
              begin
                get_n ^^ compile_unboxed_zero ^^ G.i (Compare (Wasm.Values.I32 I32Op.LtS)) ^^
                G.if_ (ValBlockType (Some I32Type))
                  begin
                    (* -1 ** (1+exp) == if even (1+exp) then 1 else -1 *)
                    get_exp ^^ compile_unboxed_one ^^ G.i (Binary (Wasm.Values.I32 I32Op.And)) ^^
                    G.if_ (ValBlockType (Some I32Type))
                      get_n
                      compile_unboxed_one
                  end
                  get_n (* n@{0,1} ** (1+exp) == n *)
              end
              begin
                get_exp ^^ compile_unboxed_const 32l ^^
                G.i (Compare (Wasm.Values.I32 I32Op.GeU)) ^^ then_arithmetic_overflow env ^^
                signed_dynamics get_n ^^ compile_sub_const 31l ^^
                get_exp ^^ UnboxedSmallWord.lsb_adjust Type.Int32 ^^ G.i (Binary (Wasm.Values.I32 I32Op.Mul)) ^^
                compile_unboxed_const (-62l) ^^
                G.i (Compare (Wasm.Values.I32 I32Op.LtS)) ^^ then_arithmetic_overflow env ^^
                get_n ^^ G.i (Convert (Wasm.Values.I64 I64Op.ExtendSI32)) ^^
                get_exp ^^ G.i (Convert (Wasm.Values.I64 I64Op.ExtendSI32)) ^^
                BoxedWord64.compile_unsigned_pow env ^^
                set_res ^^ get_res ^^ get_res ^^ enforce_32_signed_bits env ^^
                get_res ^^ G.i (Convert (Wasm.Values.I32 I32Op.WrapI64))
              end
          end
          compile_unboxed_one) (* x ** 0 == 1 *)
  | Type.(Prim Int),                          PowOp ->
    let pow = BigNum.compile_unsigned_pow env in
    let (set_n, get_n) = new_local env "n" in
    let (set_exp, get_exp) = new_local env "exp" in
    set_exp ^^ set_n ^^
    get_exp ^^ BigNum.compile_is_negative env ^^
    E.then_trap_with env "negative power" ^^
    get_n ^^ get_exp ^^ pow
  | Type.(Prim Word64),                       PowOp -> BoxedWord64.compile_unsigned_pow env
  | Type.(Prim Int64),                        PowOp ->
    let (set_exp, get_exp) = new_local64 env "exp" in
    set_exp ^^ get_exp ^^
    compile_const_64 0L ^^
    G.i (Compare (Wasm.Values.I64 I64Op.LtS)) ^^
    E.then_trap_with env "negative power" ^^
    get_exp ^^
    compile_Int64_kernel
      env "pow" BigNum.compile_unsigned_pow
      (powInt64_shortcut (BoxedWord64.compile_unsigned_pow env))
  | Type.(Prim Nat64),                        PowOp ->
    compile_Nat64_kernel env "pow"
      BigNum.compile_unsigned_pow
      (powNat64_shortcut (BoxedWord64.compile_unsigned_pow env))
  | Type.(Prim Nat),                          PowOp -> BigNum.compile_unsigned_pow env
  | Type.(Prim Word64),                       AndOp -> G.i (Binary (Wasm.Values.I64 I64Op.And))
  | Type.Prim Type.(Word8 | Word16 | Word32), AndOp -> G.i (Binary (Wasm.Values.I32 I32Op.And))
  | Type.(Prim Word64),                       OrOp  -> G.i (Binary (Wasm.Values.I64 I64Op.Or))
  | Type.Prim Type.(Word8 | Word16 | Word32), OrOp  -> G.i (Binary (Wasm.Values.I32 I32Op.Or))
  | Type.(Prim Word64),                       XorOp -> G.i (Binary (Wasm.Values.I64 I64Op.Xor))
  | Type.Prim Type.(Word8 | Word16 | Word32), XorOp -> G.i (Binary (Wasm.Values.I32 I32Op.Xor))
  | Type.(Prim Word64),                       ShLOp -> G.i (Binary (Wasm.Values.I64 I64Op.Shl))
  | Type.(Prim (Word8|Word16|Word32 as ty)),  ShLOp -> UnboxedSmallWord.(
     lsb_adjust ty ^^ clamp_shift_amount ty ^^
     G.i (Binary (Wasm.Values.I32 I32Op.Shl)))
  | Type.(Prim Word64),                       UShROp -> G.i (Binary (Wasm.Values.I64 I64Op.ShrU))
  | Type.(Prim (Word8|Word16|Word32 as ty)),  UShROp -> UnboxedSmallWord.(
     lsb_adjust ty ^^ clamp_shift_amount ty ^^
     G.i (Binary (Wasm.Values.I32 I32Op.ShrU)) ^^
     sanitize_word_result ty)
  | Type.(Prim Word64),                       SShROp -> G.i (Binary (Wasm.Values.I64 I64Op.ShrS))
  | Type.(Prim (Word8|Word16|Word32 as ty)),  SShROp -> UnboxedSmallWord.(
     lsb_adjust ty ^^ clamp_shift_amount ty ^^
     G.i (Binary (Wasm.Values.I32 I32Op.ShrS)) ^^
     sanitize_word_result ty)
  | Type.(Prim Word64),                       RotLOp -> G.i (Binary (Wasm.Values.I64 I64Op.Rotl))
  | Type.Prim Type.                  Word32,  RotLOp -> G.i (Binary (Wasm.Values.I32 I32Op.Rotl))
  | Type.Prim Type.(Word8 | Word16 as ty),    RotLOp -> UnboxedSmallWord.(
     Func.share_code2 env (name_of_type ty "rotl") (("n", I32Type), ("by", I32Type)) [I32Type]
       Wasm.Values.(fun env get_n get_by ->
      let beside_adjust = compile_shrU_const (Int32.sub 32l (shift_of_type ty)) in
      get_n ^^ get_n ^^ beside_adjust ^^ G.i (Binary (I32 I32Op.Or)) ^^
      get_by ^^ lsb_adjust ty ^^ clamp_shift_amount ty ^^ G.i (Binary (I32 I32Op.Rotl)) ^^
      sanitize_word_result ty))
  | Type.(Prim Word64),                       RotROp -> G.i (Binary (Wasm.Values.I64 I64Op.Rotr))
  | Type.Prim Type.                  Word32,  RotROp -> G.i (Binary (Wasm.Values.I32 I32Op.Rotr))
  | Type.Prim Type.(Word8 | Word16 as ty),    RotROp -> UnboxedSmallWord.(
     Func.share_code2 env (name_of_type ty "rotr") (("n", I32Type), ("by", I32Type)) [I32Type]
       Wasm.Values.(fun env get_n get_by ->
      get_n ^^ get_n ^^ lsb_adjust ty ^^ G.i (Binary (I32 I32Op.Or)) ^^
      get_by ^^ lsb_adjust ty ^^ clamp_shift_amount ty ^^ G.i (Binary (I32 I32Op.Rotr)) ^^
      sanitize_word_result ty))

  | Type.Prim Type.Text, CatOp -> Blob.concat env
  | Type.Non, _ -> G.i Unreachable
  | _ -> todo_trap env "compile_binop" (Arrange_ops.binop op)
  )

let compile_eq env = function
  | Type.(Prim Text) -> Blob.compare env Operator.EqOp
  | Type.(Prim Bool) -> G.i (Compare (Wasm.Values.I32 I32Op.Eq))
  | Type.(Prim (Nat | Int)) -> BigNum.compile_eq env
  | Type.(Prim (Int64 | Nat64 | Word64)) -> G.i (Compare (Wasm.Values.I64 I64Op.Eq))
  | Type.(Prim (Int8 | Nat8 | Word8 | Int16 | Nat16 | Word16 | Int32 | Nat32 | Word32 | Char)) ->
    G.i (Compare (Wasm.Values.I32 I32Op.Eq))
  | Type.Non -> G.i Unreachable
  | _ -> todo_trap env "compile_eq" (Arrange_ops.relop Operator.EqOp)

let get_relops = Operator.(function
  | GeOp -> Ge, I64Op.GeU, I64Op.GeS, I32Op.GeU, I32Op.GeS
  | GtOp -> Gt, I64Op.GtU, I64Op.GtS, I32Op.GtU, I32Op.GtS
  | LeOp -> Le, I64Op.LeU, I64Op.LeS, I32Op.LeU, I32Op.LeS
  | LtOp -> Lt, I64Op.LtU, I64Op.LtS, I32Op.LtU, I32Op.LtS
  | _ -> failwith "uncovered relop")

let compile_comparison env t op =
  let bigintop, u64op, s64op, u32op, s32op = get_relops op in
  let open Type in
  match t with
    | Nat | Int -> BigNum.compile_relop env bigintop
    | Nat64 | Word64 -> G.i (Compare (Wasm.Values.I64 u64op))
    | Nat8 | Word8 | Nat16 | Word16 | Nat32 | Word32 | Char -> G.i (Compare (Wasm.Values.I32 u32op))
    | Int64 -> G.i (Compare (Wasm.Values.I64 s64op))
    | Int8 | Int16 | Int32 -> G.i (Compare (Wasm.Values.I32 s32op))
    | _ -> todo_trap env "compile_comparison" (Arrange_type.prim t)

let compile_relop env t op =
  if t = Type.Non then SR.Vanilla, G.i Unreachable else
  StackRep.of_type t,
  let open Operator in
  match t, op with
  | Type.Prim Type.Text, _ -> Blob.compare env op
  | _, EqOp -> compile_eq env t
  | _, NeqOp -> compile_eq env t ^^
    G.i (Test (Wasm.Values.I32 I32Op.Eqz))
  | Type.(Prim (Nat | Nat8 | Nat16 | Nat32 | Nat64 | Int | Int8 | Int16 | Int32 | Int64 | Word8 | Word16 | Word32 | Word64 | Char as t1)), op1 ->
    compile_comparison env t1 op1
  | _ -> todo_trap env "compile_relop" (Arrange_ops.relop op)

let compile_load_field env typ name =
  Object.load_idx env typ name

(* compile_lexp is used for expressions on the left of an
assignment operator, produces some code (with side effect), and some pure code *)
let rec compile_lexp (env : E.t) ae exp =
  (fun (code,fill_code) -> (G.with_region exp.at code, G.with_region exp.at fill_code)) @@
  match exp.it with
  | VarE var ->
     G.nop,
     Var.set_val env ae var
  | IdxE (e1,e2) ->
     compile_exp_vanilla env ae e1 ^^ (* offset to array *)
     compile_exp_vanilla env ae e2 ^^ (* idx *)
     BigNum.to_word32 env ^^
     Arr.idx env,
     store_ptr
  | DotE (e, n) ->
     compile_exp_vanilla env ae e ^^
     (* Only real objects have mutable fields, no need to branch on the tag *)
     Object.idx env e.note.note_typ n,
     store_ptr
  | _ -> todo "compile_lexp" (Arrange_ir.exp exp) (E.trap_with env "TODO: compile_lexp", G.nop)

and compile_exp (env : E.t) ae exp =
  (fun (sr,code) -> (sr, G.with_region exp.at code)) @@
  match exp.it with
  | IdxE (e1, e2)  ->
    SR.Vanilla,
    compile_exp_vanilla env ae e1 ^^ (* offset to array *)
    compile_exp_vanilla env ae e2 ^^ (* idx *)
    BigNum.to_word32 env ^^
    Arr.idx env ^^
    load_ptr
  | DotE (e, name) ->
    SR.Vanilla,
    compile_exp_vanilla env ae e ^^
    Object.load_idx env e.note.note_typ name
  | ActorDotE (e, name) ->
    SR.Vanilla,
    compile_exp_as env ae SR.Vanilla e ^^
    Dfinity.actor_public_field env name
  | PrimE (p, es) ->

    (* for more concise code when all arguments and result use the same sr *)
    let const_sr sr inst = sr, G.concat_map (compile_exp_as env ae sr) es ^^ inst in

    begin match p, es with

    (* Operators *)

    | UnPrim (_, Operator.PosOp), [e1] -> compile_exp env ae e1
    | UnPrim (t, op), [e1] ->
      let sr_in, sr_out, code = compile_unop env t op in
      sr_out,
      compile_exp_as env ae sr_in e1 ^^
      code
    | BinPrim (t, op), [e1;e2] ->
      let sr_in, sr_out, code = compile_binop env t op in
      sr_out,
      compile_exp_as env ae sr_in e1 ^^
      compile_exp_as env ae sr_in e2 ^^
      code
    | RelPrim (t, op), [e1;e2] ->
      let sr, code = compile_relop env t op in
      SR.bool,
      compile_exp_as env ae sr e1 ^^
      compile_exp_as env ae sr e2 ^^
      code

    (* Numeric conversions *)
    | NumConvPrim (t1, t2), [e] -> begin
      let open Type in
      match t1, t2 with
      | (Nat|Int), (Word8|Word16) ->
        SR.Vanilla,
        compile_exp_vanilla env ae e ^^
        Prim.prim_shiftToWordN env (UnboxedSmallWord.shift_of_type t2)

      | (Nat|Int), Word32 ->
        SR.UnboxedWord32,
        compile_exp_vanilla env ae e ^^
        Prim.prim_intToWord32 env

      | (Nat|Int), Word64 ->
        SR.UnboxedWord64,
        compile_exp_vanilla env ae e ^^
        BigNum.truncate_to_word64 env

      | Nat64, Word64
      | Int64, Word64
      | Word64, Nat64
      | Word64, Int64
      | Nat32, Word32
      | Int32, Word32
      | Word32, Nat32
      | Word32, Int32
      | Nat16, Word16
      | Int16, Word16
      | Word16, Nat16
      | Word16, Int16
      | Nat8, Word8
      | Int8, Word8
      | Word8, Nat8
      | Word8, Int8 ->
        SR.Vanilla,
        compile_exp_vanilla env ae e ^^
        G.nop

      | Int, Int64 ->
        SR.UnboxedWord64,
        compile_exp_vanilla env ae e ^^
        Func.share_code1 env "Int->Int64" ("n", I32Type) [I64Type] (fun env get_n ->
          get_n ^^
          BigNum.fits_signed_bits env 64 ^^
          E.else_trap_with env "losing precision" ^^
          get_n ^^
          BigNum.truncate_to_word64 env)

      | Int, (Int8|Int16|Int32) ->
        let ty = exp.note.note_typ in
        StackRep.of_type ty,
        let pty = prim_of_typ ty in
        compile_exp_vanilla env ae e ^^
        Func.share_code1 env (UnboxedSmallWord.name_of_type pty "Int->") ("n", I32Type) [I32Type] (fun env get_n ->
          get_n ^^
          BigNum.fits_signed_bits env (UnboxedSmallWord.bits_of_type pty) ^^
          E.else_trap_with env "losing precision" ^^
          get_n ^^
          BigNum.truncate_to_word32 env ^^
          UnboxedSmallWord.msb_adjust pty)

      | Nat, Nat64 ->
        SR.UnboxedWord64,
        compile_exp_vanilla env ae e ^^
        Func.share_code1 env "Nat->Nat64" ("n", I32Type) [I64Type] (fun env get_n ->
          get_n ^^
          BigNum.fits_unsigned_bits env 64 ^^
          E.else_trap_with env "losing precision" ^^
          get_n ^^
          BigNum.truncate_to_word64 env)

      | Nat, (Nat8|Nat16|Nat32) ->
        let ty = exp.note.note_typ in
        StackRep.of_type ty,
        let pty = prim_of_typ ty in
        compile_exp_vanilla env ae e ^^
        Func.share_code1 env (UnboxedSmallWord.name_of_type pty "Nat->") ("n", I32Type) [I32Type] (fun env get_n ->
          get_n ^^
          BigNum.fits_unsigned_bits env (UnboxedSmallWord.bits_of_type pty) ^^
          E.else_trap_with env "losing precision" ^^
          get_n ^^
          BigNum.truncate_to_word32 env ^^
          UnboxedSmallWord.msb_adjust pty)

      | Char, Word32 ->
        SR.UnboxedWord32,
        compile_exp_vanilla env ae e ^^
        UnboxedSmallWord.unbox_codepoint

      | (Nat8|Word8|Nat16|Word16), Nat ->
        SR.Vanilla,
        compile_exp_vanilla env ae e ^^
        Prim.prim_shiftWordNtoUnsigned env (UnboxedSmallWord.shift_of_type t1)

      | (Int8|Word8|Int16|Word16), Int ->
        SR.Vanilla,
        compile_exp_vanilla env ae e ^^
        Prim.prim_shiftWordNtoSigned env (UnboxedSmallWord.shift_of_type t1)

      | (Nat32|Word32), Nat ->
        SR.Vanilla,
        compile_exp_as env ae SR.UnboxedWord32 e ^^
        Prim.prim_word32toNat env

      | (Int32|Word32), Int ->
        SR.Vanilla,
        compile_exp_as env ae SR.UnboxedWord32 e ^^
        Prim.prim_word32toInt env

      | (Nat64|Word64), Nat ->
        SR.Vanilla,
        compile_exp_as env ae SR.UnboxedWord64 e ^^
        BigNum.from_word64 env

      | (Int64|Word64), Int ->
        SR.Vanilla,
        compile_exp_as env ae SR.UnboxedWord64 e ^^
        BigNum.from_signed_word64 env

      | Word32, Char ->
        SR.Vanilla,
        compile_exp_as env ae SR.UnboxedWord32 e ^^
        Func.share_code1 env "Word32->Char" ("n", I32Type) [I32Type]
          UnboxedSmallWord.check_and_box_codepoint

      | _ -> SR.Unreachable, todo_trap env "compile_exp" (Arrange_ir.exp exp)
      end

    (* Other prims, unary*)

    | OtherPrim "array_len", [e] ->
      SR.Vanilla,
      compile_exp_vanilla env ae e ^^
      Heap.load_field Arr.len_field ^^
      BigNum.from_word32 env

    | OtherPrim "text_len", [e] ->
      SR.Vanilla,
      compile_exp_vanilla env ae e ^^
      Text.len env

    | OtherPrim "text_chars", [e] ->
      SR.Vanilla,
      compile_exp_vanilla env ae e ^^
      Text.text_chars_direct env

    | OtherPrim "abs", [e] ->
      SR.Vanilla,
      compile_exp_vanilla env ae e ^^
      BigNum.compile_abs env

    | OtherPrim "rts_version", [] ->
      SR.Vanilla,
      E.call_import env "rts" "version"

    | OtherPrim "rts_heap_size", [] ->
      SR.Vanilla,
      GC.get_heap_size env ^^ Prim.prim_word32toNat env

    | OtherPrim "rts_total_allocation", [] ->
      SR.Vanilla,
      Heap.get_total_allocation env ^^ BigNum.from_word64 env

    | OtherPrim "rts_callback_table_count", [] ->
      SR.Vanilla,
      ClosureTable.count env ^^ Prim.prim_word32toNat env

    | OtherPrim "rts_callback_table_size", [] ->
      SR.Vanilla,
      ClosureTable.size env ^^ Prim.prim_word32toNat env


    | OtherPrim "idlHash", [e] ->
      SR.Vanilla,
      E.trap_with env "idlHash only implemented in interpreter "


    | OtherPrim "popcnt8", [e] ->
      SR.Vanilla,
      compile_exp_vanilla env ae e ^^
      G.i (Unary (Wasm.Values.I32 I32Op.Popcnt)) ^^
      UnboxedSmallWord.msb_adjust Type.Word8
    | OtherPrim "popcnt16", [e] ->
      SR.Vanilla,
      compile_exp_vanilla env ae e ^^
      G.i (Unary (Wasm.Values.I32 I32Op.Popcnt)) ^^
      UnboxedSmallWord.msb_adjust Type.Word16
    | OtherPrim "popcnt32", [e] ->
      SR.UnboxedWord32,
      compile_exp_as env ae SR.UnboxedWord32 e ^^
      G.i (Unary (Wasm.Values.I32 I32Op.Popcnt))
    | OtherPrim "popcnt64", [e] ->
      SR.UnboxedWord64,
      compile_exp_as env ae SR.UnboxedWord64 e ^^
      G.i (Unary (Wasm.Values.I64 I64Op.Popcnt))
    | OtherPrim "clz8", [e] -> SR.Vanilla, compile_exp_vanilla env ae e ^^ UnboxedSmallWord.clz_kernel Type.Word8
    | OtherPrim "clz16", [e] -> SR.Vanilla, compile_exp_vanilla env ae e ^^ UnboxedSmallWord.clz_kernel Type.Word16
    | OtherPrim "clz32", [e] -> SR.UnboxedWord32, compile_exp_as env ae SR.UnboxedWord32 e ^^ G.i (Unary (Wasm.Values.I32 I32Op.Clz))
    | OtherPrim "clz64", [e] -> SR.UnboxedWord64, compile_exp_as env ae SR.UnboxedWord64 e ^^ G.i (Unary (Wasm.Values.I64 I64Op.Clz))
    | OtherPrim "ctz8", [e] -> SR.Vanilla, compile_exp_vanilla env ae e ^^ UnboxedSmallWord.ctz_kernel Type.Word8
    | OtherPrim "ctz16", [e] -> SR.Vanilla, compile_exp_vanilla env ae e ^^ UnboxedSmallWord.ctz_kernel Type.Word16
    | OtherPrim "ctz32", [e] -> SR.UnboxedWord32, compile_exp_as env ae SR.UnboxedWord32 e ^^ G.i (Unary (Wasm.Values.I32 I32Op.Ctz))
    | OtherPrim "ctz64", [e] -> SR.UnboxedWord64, compile_exp_as env ae SR.UnboxedWord64 e ^^ G.i (Unary (Wasm.Values.I64 I64Op.Ctz))

    | OtherPrim "conv_Char_Text", [e] ->
      SR.Vanilla,
      compile_exp_vanilla env ae e ^^
      Text.prim_showChar env

    | OtherPrim "print", [e] ->
      SR.unit,
      compile_exp_vanilla env ae e ^^
      Dfinity.print_text env
    | OtherPrim "decodeUTF8", [e] ->
      SR.UnboxedTuple 2,
      compile_exp_vanilla env ae e ^^
      Text.prim_decodeUTF8 env

    (* Other prims, binary*)
    | OtherPrim "Array.init", [_;_] ->
      const_sr SR.Vanilla (Arr.init env)
    | OtherPrim "Array.tabulate", [_;_] ->
      const_sr SR.Vanilla (Arr.tabulate env)
    | OtherPrim "btst8", [_;_] ->
      const_sr SR.Vanilla (UnboxedSmallWord.btst_kernel env Type.Word8)
    | OtherPrim "btst16", [_;_] ->
      const_sr SR.Vanilla (UnboxedSmallWord.btst_kernel env Type.Word16)
    | OtherPrim "btst32", [_;_] ->
      const_sr SR.UnboxedWord32 (UnboxedSmallWord.btst_kernel env Type.Word32)
    | OtherPrim "btst64", [_;_] ->
      const_sr SR.UnboxedWord64 (
        let (set_b, get_b) = new_local64 env "b" in
        set_b ^^ compile_const_64 1L ^^ get_b ^^ G.i (Binary (Wasm.Values.I64 I64Op.Shl)) ^^
        G.i (Binary (Wasm.Values.I64 I64Op.And))
      )

    (* Error related prims *)
    | OtherPrim "error", [e] ->
      Error.compile_error env (compile_exp_vanilla env ae e)
    | OtherPrim "errorCode", [e] ->
      Error.compile_errorCode (compile_exp_vanilla env ae e)
    | OtherPrim "errorMessage", [e] ->
      Error.compile_errorMessage (compile_exp_vanilla env ae e)
    | OtherPrim "make_error", [e1; e2] ->
      Error.compile_make_error (compile_exp_vanilla env ae e1) (compile_exp_vanilla env ae e2)

    | ICReplyPrim ts, [e] ->
      SR.unit, begin match E.mode env with
      | Flags.ICMode | Flags.StubMode ->
        compile_exp_as env ae SR.Vanilla e ^^
        (* TODO: We can try to avoid the boxing and pass the arguments to
          serialize individually *)
        Serialization.serialize env ts ^^
        Dfinity.reply_with_data env
      | _ -> assert false
      end

    | ICRejectPrim, [e] ->
      SR.unit, Dfinity.reject env (compile_exp_vanilla env ae e)

    | ICErrorCodePrim, [] ->
      assert (E.mode env = Flags.ICMode || E.mode env = Flags.StubMode);
      Dfinity.error_code env

    | ICCallPrim, [f;e;k;r] ->
      SR.unit, begin
      (* TBR: Can we do better than using the notes? *)
      let _, _, _, ts1, _ = Type.as_func f.note.note_typ in
      let _, _, _, ts2, _ = Type.as_func k.note.note_typ in
      let (set_meth_pair, get_meth_pair) = new_local env "meth_pair" in
      let (set_arg, get_arg) = new_local env "arg" in
      let (set_k, get_k) = new_local env "k" in
      let (set_r, get_r) = new_local env "r" in
      compile_exp_as env ae SR.Vanilla f ^^ set_meth_pair ^^
      compile_exp_as env ae SR.Vanilla e ^^ set_arg ^^
      compile_exp_as env ae SR.Vanilla k ^^ set_k ^^
      compile_exp_as env ae SR.Vanilla r ^^ set_r ^^
      FuncDec.ic_call env ts1 ts2 get_meth_pair get_arg get_k get_r
      end
    (* Unknown prim *)
    | _ -> SR.Unreachable, todo_trap env "compile_exp" (Arrange_ir.exp exp)
    end
  | VarE var ->
    Var.get_val env ae var
  | AssignE (e1,e2) ->
    SR.unit,
    let (prepare_code, store_code) = compile_lexp env ae e1 in
    prepare_code ^^
    compile_exp_vanilla env ae e2 ^^
    store_code
  | LitE l ->
    compile_lit env l
  | AssertE e1 ->
    SR.unit,
    compile_exp_as env ae SR.bool e1 ^^
    G.if_ (ValBlockType None) G.nop (Dfinity.fail_assert env exp.at)
  | IfE (scrut, e1, e2) ->
    let code_scrut = compile_exp_as env ae SR.bool scrut in
    let sr1, code1 = compile_exp env ae e1 in
    let sr2, code2 = compile_exp env ae e2 in
    let sr = StackRep.relax (StackRep.join sr1 sr2) in
    sr,
    code_scrut ^^ G.if_
      (StackRep.to_block_type env sr)
      (code1 ^^ StackRep.adjust env sr1 sr)
      (code2 ^^ StackRep.adjust env sr2 sr)
  | BlockE (decs, exp) ->
    let captured = Freevars.captured_vars (Freevars.exp exp) in
    let (ae', code1) = compile_decs env ae AllocHow.NotTopLvl decs captured in
    let (sr, code2) = compile_exp env ae' exp in
    (sr, code1 ^^ code2)
  | LabelE (name, _ty, e) ->
    (* The value here can come from many places -- the expression,
       or any of the nested returns. Hard to tell which is the best
       stack representation here.
       So let’s go with Vanilla. *)
    SR.Vanilla,
    G.block_ (StackRep.to_block_type env SR.Vanilla) (
      G.with_current_depth (fun depth ->
        let ae1 = VarEnv.add_label ae name depth in
        compile_exp_vanilla env ae1 e
      )
    )
  | BreakE (name, e) ->
    let d = VarEnv.get_label_depth ae name in
    SR.Unreachable,
    compile_exp_vanilla env ae e ^^
    G.branch_to_ d
  | LoopE e ->
    SR.Unreachable,
    G.loop_ (ValBlockType None) (compile_exp_unit env ae e ^^ G.i (Br (nr 0l))
    )
    ^^
   G.i Unreachable
  | RetE e ->
    SR.Unreachable,
    compile_exp_as env ae (StackRep.of_arity (E.get_return_arity env)) e ^^
    FakeMultiVal.store env (Lib.List.make (E.get_return_arity env) I32Type) ^^
    G.i Return
  | OptE e ->
    SR.Vanilla,
    Opt.inject env (compile_exp_vanilla env ae e)
  | TagE (l, e) ->
    SR.Vanilla,
    Variant.inject env l (compile_exp_vanilla env ae e)
  | TupE es ->
    SR.UnboxedTuple (List.length es),
    G.concat_map (compile_exp_vanilla env ae) es
  | ProjE (e1,n) ->
    SR.Vanilla,
    compile_exp_vanilla env ae e1 ^^ (* offset to tuple (an array) *)
    Tuple.load_n (Int32.of_int n)
  | ArrayE (m, t, es) ->
    SR.Vanilla, Arr.lit env (List.map (compile_exp_vanilla env ae) es)
  | CallE (e1, _, e2) ->
    let sort, control, _, arg_tys, ret_tys = Type.as_func e1.note.note_typ in
    let n_args = List.length arg_tys in
    let return_arity = match control with
      | Type.Returns -> List.length ret_tys
      | Type.Replies -> 0
      | Type.Promises -> assert false in

    StackRep.of_arity return_arity,
    let fun_sr, code1 = compile_exp env ae e1 in
    begin match fun_sr, sort with
     | SR.StaticThing (SR.StaticFun fi), _ ->
        code1 ^^
        compile_unboxed_zero ^^ (* A dummy closure *)
        compile_exp_as env ae (StackRep.of_arity n_args) e2 ^^ (* the args *)
        G.i (Call (nr fi)) ^^
        FakeMultiVal.load env (Lib.List.make return_arity I32Type)
     | _, Type.Local ->
        let (set_clos, get_clos) = new_local env "clos" in
        code1 ^^ StackRep.adjust env fun_sr SR.Vanilla ^^
        set_clos ^^
        get_clos ^^
        compile_exp_as env ae (StackRep.of_arity n_args) e2 ^^
        get_clos ^^
        Closure.call_closure env n_args return_arity
     | _, Type.Shared _ ->
        (* Non-one-shot functions have been rewritten in async.ml *)
        assert (control = Type.Returns);

        let (set_meth_pair, get_meth_pair) = new_local env "meth_pair" in
        let (set_arg, get_arg) = new_local env "arg" in
        let _, _, _, ts, _ = Type.as_func e1.note.note_typ in
        code1 ^^ StackRep.adjust env fun_sr SR.Vanilla ^^
        set_meth_pair ^^
        compile_exp_as env ae SR.Vanilla e2 ^^ set_arg ^^

        FuncDec.ic_call_one_shot env ts get_meth_pair get_arg
    end
  | SwitchE (e, cs) ->
    SR.Vanilla,
    let code1 = compile_exp_vanilla env ae e in
    let (set_i, get_i) = new_local env "switch_in" in
    let (set_j, get_j) = new_local env "switch_out" in

    let rec go env cs = match cs with
      | [] -> CanFail (fun k -> k)
      | {it={pat; exp=e}; _}::cs ->
          let (ae1, code) = compile_pat_local env ae pat in
          orElse ( CannotFail get_i ^^^ code ^^^
                   CannotFail (compile_exp_vanilla env ae1 e) ^^^ CannotFail set_j)
                 (go env cs)
          in
      let code2 = go env cs in
      code1 ^^ set_i ^^ orTrap env code2 ^^ get_j
  (* Async-wait lowering support features *)
  | DeclareE (name, _, e) ->
    let (ae1, i) = VarEnv.add_local_with_offset env ae name 1l in
    let sr, code = compile_exp env ae1 e in
    sr,
    Tagged.obj env Tagged.MutBox [ compile_unboxed_zero ] ^^
    G.i (LocalSet (nr i)) ^^
    code
  | DefineE (name, _, e) ->
    SR.unit,
    compile_exp_vanilla env ae e ^^
    Var.set_val env ae name
  | FuncE (x, sort, control, typ_binds, args, res_tys, e) ->
    let captured = Freevars.captured exp in
    let return_tys = match control with
      | Type.Returns -> res_tys
      | Type.Replies -> []
      | Type.Promises -> assert false in
    let return_arity = List.length return_tys in
    let mk_body env1 ae1 = compile_exp_as env1 ae1 (StackRep.of_arity return_arity) e in
    FuncDec.lit env ae x sort control captured args mk_body return_tys exp.at
  | SelfCallE (ts, exp_f, exp_k, exp_r) ->
    SR.unit,
    let (set_closure_idx, get_closure_idx) = new_local env "closure_idx" in
    let (set_k, get_k) = new_local env "k" in
    let (set_r, get_r) = new_local env "r" in
    let mk_body env1 ae1 = compile_exp_as env1 ae1 SR.unit exp_f in
    let captured = Freevars.captured exp_f in
    FuncDec.async_body env ae ts captured mk_body exp.at ^^
    set_closure_idx ^^

    compile_exp_as env ae SR.Vanilla exp_k ^^ set_k ^^
    compile_exp_as env ae SR.Vanilla exp_r ^^ set_r ^^

    FuncDec.ic_call env [Type.Prim Type.Word32] ts
      ( Dfinity.get_self_reference env ^^
        Dfinity.actor_public_field env (Dfinity.async_method_name))
      (get_closure_idx ^^ BoxedSmallWord.box env)
      get_k
      get_r
  | ActorE (i, ds, fs, _) ->
    SR.Vanilla,
    let captured = Freevars.exp exp in
    let prelude_names = find_prelude_names env in
    if Freevars.M.is_empty (Freevars.diff captured prelude_names)
    then actor_lit env i ds fs exp.at
    else todo_trap env "non-closed actor" (Arrange_ir.exp exp)
  | NewObjE ((Type.Object | Type.Module), fs, _) ->
    SR.Vanilla,
    let fs' = fs |> List.map
      (fun (f : Ir.field) -> (f.it.name, fun () ->
        if Object.is_mut_field env exp.note.note_typ f.it.name
        then Var.get_val_ptr env ae f.it.var
        else Var.get_val_vanilla env ae f.it.var)) in
    Object.lit_raw env fs'
  | _ -> SR.unit, todo_trap env "compile_exp" (Arrange_ir.exp exp)

and compile_exp_as env ae sr_out e =
  G.with_region e.at (
    match sr_out, e.it with
    (* Some optimizations for certain sr_out and expressions *)
    | _ , BlockE (decs, exp) ->
      let captured = Freevars.captured_vars (Freevars.exp exp) in
      let (ae', code1) = compile_decs env ae AllocHow.NotTopLvl decs captured in
      let code2 = compile_exp_as env ae' sr_out exp in
      code1 ^^ code2
    (* Fallback to whatever stackrep compile_exp chooses *)
    | _ ->
      let sr_in, code = compile_exp env ae e in
      code ^^ StackRep.adjust env sr_in sr_out
  )

and compile_exp_as_opt env ae sr_out_o e =
  let sr_in, code = compile_exp env ae e in
  G.with_region e.at (
    code ^^
    match sr_out_o with
    | None -> StackRep.drop env sr_in
    | Some sr_out -> StackRep.adjust env sr_in sr_out
  )

and compile_exp_vanilla (env : E.t) ae exp =
  compile_exp_as env ae SR.Vanilla exp

and compile_exp_unit (env : E.t) ae exp =
  compile_exp_as env ae SR.unit exp


(*
The compilation of declarations (and patterns!) needs to handle mutual recursion.
This requires conceptually three passes:
 1. First we need to collect all names bound in a block,
    and find locations for then (which extends the environment).
    The environment is extended monotonously: The type-checker ensures that
    a Block does not bind the same name twice.
    We would not need to pass in the environment, just out ... but because
    it is bundled in the E.t type, threading it through is also easy.

 2. We need to allocate memory for them, and store the pointer in the
    WebAssembly local, so that they can be captured by closures.

 3. We go through the declarations, generate the actual code and fill the
    allocated memory.
    This includes creating the actual closure references.

We could do this in separate functions, but I chose to do it in one
 * it means all code related to one constructor is in one place and
 * when generating the actual code, we still “know” the id of the local that
   has the memory location, and don’t have to look it up in the environment.

The first phase works with the `pre_env` passed to `compile_dec`,
while the third phase is a function that expects the final environment. This
enabled mutual recursion.
*)


and compile_lit_pat env l =
  match l with
  | NullLit ->
    compile_lit_as env SR.Vanilla l ^^
    G.i (Compare (Wasm.Values.I32 I32Op.Eq))
  | BoolLit true ->
    G.nop
  | BoolLit false ->
    G.i (Test (Wasm.Values.I32 I32Op.Eqz))
  | (NatLit _ | IntLit _) ->
    compile_lit_as env SR.Vanilla l ^^
    BigNum.compile_eq env
  | Nat8Lit _ ->
    snd (compile_lit env l) ^^
    compile_eq env Type.(Prim Nat8)
  | Nat16Lit _ ->
    snd (compile_lit env l) ^^
    compile_eq env Type.(Prim Nat16)
  | Nat32Lit _ ->
    BoxedSmallWord.unbox env ^^
    snd (compile_lit env l) ^^
    compile_eq env Type.(Prim Nat32)
  | Nat64Lit _ ->
    BoxedWord64.unbox env ^^
    snd (compile_lit env l) ^^
    compile_eq env Type.(Prim Nat64)
  | Int8Lit _ ->
    snd (compile_lit env l) ^^
    compile_eq env Type.(Prim Int8)
  | Int16Lit _ ->
    snd (compile_lit env l) ^^
    compile_eq env Type.(Prim Int16)
  | Int32Lit _ ->
    BoxedSmallWord.unbox env ^^
    snd (compile_lit env l) ^^
    compile_eq env Type.(Prim Int32)
  | Int64Lit _ ->
    BoxedWord64.unbox env ^^
    snd (compile_lit env l) ^^
    compile_eq env Type.(Prim Int64)
  | Word8Lit _ ->
    snd (compile_lit env l) ^^
    compile_eq env Type.(Prim Word8)
  | Word16Lit _ ->
    snd (compile_lit env l) ^^
    compile_eq env Type.(Prim Word16)
  | Word32Lit _ ->
    BoxedSmallWord.unbox env ^^
    snd (compile_lit env l) ^^
    compile_eq env Type.(Prim Word32)
  | CharLit _ ->
    snd (compile_lit env l) ^^
    compile_eq env Type.(Prim Char)
  | Word64Lit _ ->
    BoxedWord64.unbox env ^^
    snd (compile_lit env l) ^^
    compile_eq env Type.(Prim Word64)
  | TextLit t ->
    Blob.lit env t ^^
    Blob.compare env Operator.EqOp
  | _ -> todo_trap env "compile_lit_pat" (Arrange_ir.lit l)

and fill_pat env ae pat : patternCode =
  PatCode.with_region pat.at @@
  match pat.it with
  | WildP -> CannotFail (G.i Drop)
  | OptP p ->
      let (set_x, get_x) = new_local env "opt_scrut" in
      CanFail (fun fail_code ->
        set_x ^^
        get_x ^^
        Opt.is_some env ^^
        G.if_ (ValBlockType None)
          ( get_x ^^
            Opt.project ^^
            with_fail fail_code (fill_pat env ae p)
          )
          fail_code
      )
  | TagP (l, p) ->
      let (set_x, get_x) = new_local env "tag_scrut" in
      CanFail (fun fail_code ->
        set_x ^^
        get_x ^^
        Variant.test_is env l ^^
        G.if_ (ValBlockType None)
          ( get_x ^^
            Variant.project ^^
            with_fail fail_code (fill_pat env ae p)
          )
          fail_code
      )
  | LitP l ->
      CanFail (fun fail_code ->
        compile_lit_pat env l ^^
        G.if_ (ValBlockType None) G.nop fail_code)
  | VarP name ->
      CannotFail (Var.set_val env ae name)
  | TupP ps ->
      let (set_i, get_i) = new_local env "tup_scrut" in
      let rec go i = function
        | [] -> CannotFail G.nop
        | p::ps ->
          let code1 = fill_pat env ae p in
          let code2 = go (Int32.add i 1l) ps in
          CannotFail (get_i ^^ Tuple.load_n i) ^^^ code1 ^^^ code2 in
      CannotFail set_i ^^^ go 0l ps
  | ObjP pfs ->
      let project = compile_load_field env pat.note in
      let (set_i, get_i) = new_local env "obj_scrut" in
      let rec go = function
        | [] -> CannotFail G.nop
        | {it={name; pat}; _}::pfs' ->
          let code1 = fill_pat env ae pat in
          let code2 = go pfs' in
          CannotFail (get_i ^^ project name) ^^^ code1 ^^^ code2 in
      CannotFail set_i ^^^ go pfs
  | AltP (p1, p2) ->
      let code1 = fill_pat env ae p1 in
      let code2 = fill_pat env ae p2 in
      let (set_i, get_i) = new_local env "alt_scrut" in
      CannotFail set_i ^^^
      orElse (CannotFail get_i ^^^ code1)
             (CannotFail get_i ^^^ code2)

and alloc_pat_local env ae pat =
  let (_,d) = Freevars.pat pat in
  AllocHow.S.fold (fun v ae ->
    let (ae1, _i) = VarEnv.add_direct_local env ae v
    in ae1
  ) d ae

and alloc_pat env ae how pat : VarEnv.t * G.t  =
  (fun (ae,code) -> (ae, G.with_region pat.at code)) @@
  let (_,d) = Freevars.pat pat in
  AllocHow.S.fold (fun v (ae,code0) ->
    let (ae1, code1) = AllocHow.add_local env ae how v
    in (ae1, code0 ^^ code1)
  ) d (ae, G.nop)

and compile_pat_local env ae pat : VarEnv.t * patternCode =
  (* It returns:
     - the extended environment
     - the code to do the pattern matching.
       This expects the  undestructed value is on top of the stack,
       consumes it, and fills the heap
       If the pattern does not match, it branches to the depth at fail_depth.
  *)
  let ae1 = alloc_pat_local env ae pat in
  let fill_code = fill_pat env ae1 pat in
  (ae1, fill_code)

(* Used for let patterns: If the patterns is an n-ary tuple pattern,
   we want to compile the expression accordingly, to avoid the reboxing.
*)
and compile_n_ary_pat env ae how pat =
  (* It returns:
     - the extended environment
     - the code to allocate memory
     - the arity
     - the code to do the pattern matching.
       This expects the  undestructed value is on top of the stack,
       consumes it, and fills the heap
       If the pattern does not match, it branches to the depth at fail_depth.
  *)
  let (ae1, alloc_code) = alloc_pat env ae how pat in
  let arity, fill_code =
    (fun (sr,code) -> (sr, G.with_region pat.at code)) @@
    match pat.it with
    (* Nothing to match: Do not even put something on the stack *)
    | WildP -> None, G.nop
    (* The good case: We have a tuple pattern *)
    | TupP ps when List.length ps <> 1 ->
      Some (SR.UnboxedTuple (List.length ps)),
      (* We have to fill the pattern in reverse order, to take things off the
         stack. This is only ok as long as patterns have no side effects.
      *)
      G.concat_mapi (fun i p -> orTrap env (fill_pat env ae1 p)) (List.rev ps)
    (* The general case: Create a single value, match that. *)
    | _ ->
      Some SR.Vanilla,
      orTrap env (fill_pat env ae1 pat)
  in (ae1, alloc_code, arity, fill_code)

and compile_dec env pre_ae how v2en dec : VarEnv.t * G.t * (VarEnv.t -> G.t) =
  (fun (pre_ae,alloc_code,mk_code) ->
       (pre_ae, G.with_region dec.at alloc_code, fun ae ->
         G.with_region dec.at (mk_code ae))) @@
  match dec.it with
  | TypD _ ->
    (pre_ae, G.nop, fun _ -> G.nop)
  (* A special case for public methods *)
  (* This relies on the fact that in the top-level mutually recursive group, no shadowing happens. *)
  | LetD ({it = VarP v; _}, e) when E.NameEnv.mem v v2en ->
    let (static_thing, fill) = compile_static_exp env pre_ae how e in
    let fi = match static_thing with
      | SR.StaticMessage fi -> fi
      | _ -> assert false in
    let pre_ae1 = VarEnv.add_local_deferred pre_ae v
      (SR.StaticThing (SR.PublicMethod (fi, (E.NameEnv.find v v2en))))
      (fun _ -> G.nop) false in
    ( pre_ae1, G.nop, fun ae -> fill env ae; G.nop)

  (* A special case for static expressions *)
  | LetD ({it = VarP v; _}, e) when not (AllocHow.M.mem v how) ->
    let (static_thing, fill) = compile_static_exp env pre_ae how e in
    let pre_ae1 = VarEnv.add_local_deferred pre_ae v
      (SR.StaticThing static_thing) (fun _ -> G.nop) false in
    ( pre_ae1, G.nop, fun ae -> fill env ae; G.nop)
  | LetD (p, e) ->
    let (pre_ae1, alloc_code, pat_arity, fill_code) = compile_n_ary_pat env pre_ae how p in
    ( pre_ae1, alloc_code, fun ae ->
      compile_exp_as_opt env ae pat_arity e ^^
      fill_code
    )
  | VarD (name, e) ->
      assert (AllocHow.M.find_opt name how = Some AllocHow.LocalMut ||
              AllocHow.M.find_opt name how = Some AllocHow.StoreHeap ||
              AllocHow.M.find_opt name how = Some AllocHow.StoreStatic);
      let (pre_ae1, alloc_code) = AllocHow.add_local env pre_ae how name in

      ( pre_ae1, alloc_code, fun ae ->
        compile_exp_vanilla env ae e ^^
        Var.set_val env ae name
      )

and compile_decs env ae lvl decs captured_in_body : VarEnv.t * G.t =
  compile_decs_public env ae lvl decs E.NameEnv.empty captured_in_body

and compile_decs_public env ae lvl decs v2en captured_in_body : VarEnv.t * G.t =
  let how = AllocHow.decs ae lvl decs captured_in_body in
  let rec go pre_ae decs = match decs with
    | []          -> (pre_ae, G.nop, fun _ -> G.nop)
    | [dec]       -> compile_dec env pre_ae how v2en dec
    | (dec::decs) ->
        let (pre_ae1, alloc_code1, mk_code1) = compile_dec env pre_ae how v2en dec in
        let (pre_ae2, alloc_code2, mk_code2) = go              pre_ae1 decs in
        ( pre_ae2,
          alloc_code1 ^^ alloc_code2,
          fun env -> let code1 = mk_code1 env in
                     let code2 = mk_code2 env in
                     code1 ^^ code2
        ) in
  let (ae1, alloc_code, mk_code) = go ae decs in
  let code = mk_code ae1 in
  (ae1, alloc_code ^^ code)

and compile_top_lvl_expr env ae e = match e.it with
  | BlockE (decs, exp) ->
    let captured = Freevars.captured_vars (Freevars.exp e) in
    let (ae', code1) = compile_decs env ae AllocHow.TopLvl decs captured in
    let code2 = compile_top_lvl_expr env ae' exp in
    code1 ^^ code2
  | _ ->
    let (sr, code) = compile_exp env ae e in
    code ^^ StackRep.drop env sr

and compile_prog env ae (ds, e) =
    let captured = Freevars.captured_vars (Freevars.exp e) in
    let (ae', code1) = compile_decs env ae AllocHow.TopLvl ds captured in
    let code2 = compile_top_lvl_expr env ae' e in
    (ae', code1 ^^ code2)

and compile_static_exp env pre_ae how exp = match exp.it with
  | FuncE (name, sort, control, typ_binds, args, res_tys, e) ->
      let return_tys = match control with
        | Type.Returns -> res_tys
        | Type.Replies -> []
        | Type.Promises -> assert false in
      let mk_body env ae =
        assert begin (* Is this really closed? *)
          List.for_all (fun v -> VarEnv.NameEnv.mem v ae.VarEnv.vars)
            (Freevars.M.keys (Freevars.exp e))
        end;
        compile_exp_as env ae (StackRep.of_arity (List.length return_tys)) e in
      FuncDec.closed env sort control name args mk_body return_tys exp.at
  | _ -> assert false

and compile_prelude env ae =
  (* Allocate the primitive functions *)
  let (decs, _flavor) = E.get_prelude env in
  let (ae1, code) = compile_prog env ae decs in
  (ae1, code)

(*
This is a horrible hack
When determining whether an actor is closed, we disregard the prelude, because
every actor is compiled with the prelude.
This breaks with shadowing.
This function compiles the prelude, just to find out the bound names.
*)
and find_prelude_names env =
  (* Create a throw-away environment *)
  let env0 = E.mk_global (E.mode env) None (E.get_prelude env) (fun _ _ -> G.i Unreachable) 0l in
  Heap.register_globals env0;
  Stack.register_globals env0;
  Dfinity.system_imports env0;
  RTS.system_imports env0;
  let env1 = E.mk_fun_env env0 0l 0 in
  let ae = VarEnv.empty_ae in
  let (env2, _) = compile_prelude env1 ae in
  VarEnv.in_scope_set env2


and compile_start_func mod_env (progs : Ir.prog list) : E.func_with_names =
  let find_last_expr ds e =
    if ds = [] then [], e.it else
    match Lib.List.split_last ds, e.it with
    | (ds1', {it = LetD ({it = VarP i1; _}, e'); _}), TupE [] ->
      ds1', e'.it
    | (ds1', {it = LetD ({it = VarP i1; _}, e'); _}), VarE i2 when i1 = i2 ->
      ds1', e'.it
    | _ -> ds, e.it in

  let find_last_actor (ds,e) = match find_last_expr ds e with
    | ds1, ActorE (i, ds2, fs, _) ->
      Some (i, ds1 @ ds2, fs)
    | ds1, FuncE (_name, _sort, _control, [], [], _, {it = ActorE (i, ds2, fs, _);_}) ->
      Some (i, ds1 @ ds2, fs)
    | _, _ ->
      None
  in

  Func.of_body mod_env [] [] (fun env ->
    let rec go ae = function
      | [] -> G.nop
      (* If the last program ends with an actor, then consider this the current actor  *)
      | [(prog, _flavor)] ->
        begin match find_last_actor prog with
        | Some (i, ds, fs) -> main_actor env ae i ds fs
        | None ->
          let (_ae, code) = compile_prog env ae prog in
          code
        end
      | ((prog, _flavor) :: progs) ->
        let (ae1, code1) = compile_prog env ae prog in
        let code2 = go ae1 progs in
        code1 ^^ code2 in
    go VarEnv.empty_ae progs
    )

and export_actor_field env  ae (f : Ir.field) =
  let sr, code = Var.get_val env ae f.it.var in
  (* A public actor field is guaranteed to be compiled as a PublicMethod *) 
  let fi = match sr with
    | SR.StaticThing (SR.PublicMethod (fi, _)) -> fi
    | _ -> assert false in
  (* There should be no code associated with this *)
  assert (G.is_nop code);

  E.add_export env (nr {
    name = Wasm.Utf8.decode (match E.mode env with
      | Flags.ICMode | Flags.StubMode ->
        Mo_types.Type.(
        match normalize f.note with
        |  Func(Shared sort,_,_,_,_) ->
           (match sort with
            | Write -> "canister_update " ^ f.it.name
            | Query -> "canister_query " ^ f.it.name)
        | _ -> assert false)
      | _ -> assert false);
    edesc = nr (FuncExport (nr fi))
  })

(* Local actor *)
and actor_lit outer_env this ds fs at =
  let wasm_binary =
    let mod_env = E.mk_global
      (E.mode outer_env)
      (E.get_rts outer_env)
      (E.get_prelude outer_env)
      (E.get_trap_with outer_env)
      Stack.end_of_stack in

    Heap.register_globals mod_env;
    Stack.register_globals mod_env;

    Dfinity.system_imports mod_env;
    RTS.system_imports mod_env;
    RTS_Exports.system_exports mod_env;

    let start_fun = Func.of_body mod_env [] [] (fun env -> G.with_region at @@
      let ae0 = VarEnv.empty_ae in

      (* Compile the prelude *)
      let (ae1, prelude_code) = compile_prelude env ae0 in

      (* Add this pointer *)
      let ae2 = VarEnv.add_local_deferred ae1 this SR.Vanilla Dfinity.get_self_reference false in

      (* Reverse the fs, to a map from variable to exported name *)
      let v2en = E.NameEnv.from_list (List.map (fun f -> (f.it.var, f.it.name)) fs) in

      (* Compile the declarations *)
      let (ae3, decls_code) = compile_decs_public env ae2 AllocHow.TopLvl ds v2en Freevars.S.empty in

      (* Export the public functions *)
      List.iter (export_actor_field env ae3) fs;

      prelude_code ^^ decls_code) in
    let start_fi = E.add_fun mod_env "start" start_fun in

    if E.mode mod_env = Flags.ICMode then Dfinity.export_start mod_env start_fi;
    if E.mode mod_env = Flags.StubMode then Dfinity.export_start mod_env start_fi;

    let m = conclude_module mod_env this None in
    let (_map, wasm_binary) = Wasm_exts.CustomModuleEncode.encode m in
    wasm_binary in

    match E.mode outer_env with
    | Flags.StubMode ->
      let (set_idx, get_idx) = new_local outer_env "idx" in
      let (set_len, get_len) = new_local outer_env "len" in
      let (set_id, get_id) = new_local outer_env "id" in
      (* the module *)
      Blob.lit outer_env wasm_binary ^^
      Blob.as_ptr_len outer_env ^^
      (* the arg (not used in motoko yet) *)
      compile_unboxed_const 0l ^^
      compile_unboxed_const 0l ^^
      Dfinity.system_call outer_env "stub" "create_canister" ^^
      set_idx ^^

      get_idx ^^
      Dfinity.system_call outer_env "stub" "created_canister_id_size" ^^
      set_len ^^

      get_len ^^ Blob.alloc outer_env ^^ set_id ^^

      get_idx ^^
      get_id ^^ Blob.payload_ptr_unskewed ^^
      compile_unboxed_const 0l ^^
      get_len ^^
      Dfinity.system_call outer_env "stub" "created_canister_id_copy" ^^

      get_id
    | _ -> assert false


(* Main actor: Just return the initialization code, and export functions as needed *)
and main_actor env ae1 this ds fs =
  (* Add this pointer *)
  let ae2 = VarEnv.add_local_deferred ae1 this SR.Vanilla Dfinity.get_self_reference false in

  (* Reverse the fs, to a map from variable to exported name *)
  let v2en = E.NameEnv.from_list (List.map (fun f -> (f.it.var, f.it.name)) fs) in

  (* Compile the declarations *)
  let (ae3, decls_code) = compile_decs_public env ae2 AllocHow.TopLvl ds v2en Freevars.S.empty in

  (* Export the public functions *)
  List.iter (export_actor_field env ae3) fs;

  decls_code

and conclude_module env module_name start_fi_o =

  FuncDec.export_async_method env;

  (* add beginning-of-heap pointer, may be changed by linker *)
  (* needs to happen here now that we know the size of static memory *)
  E.add_global32 env "__heap_base" Immutable (E.get_end_of_static_memory env);
  E.export_global env "__heap_base";

  (* Wrap the start function with the RTS initialization *)
  let rts_start_fi = E.add_fun env "rts_start" (Func.of_body env [] [] (fun env1 ->
    Heap.get_heap_base env ^^ Heap.set_heap_ptr env ^^
    match start_fi_o with
    | Some fi -> G.i (Call fi)
    | None -> G.nop
  )) in

  Dfinity.default_exports env;
  GC.register env (E.get_end_of_static_memory env);

  let func_imports = E.get_func_imports env in
  let ni = List.length func_imports in
  let ni' = Int32.of_int ni in

  let other_imports = E.get_other_imports env in

  let funcs = E.get_funcs env in
  let nf = List.length funcs in
  let nf' = Wasm.I32.of_int_u nf in

  let table_sz = Int32.add nf' ni' in

  let memories = [nr {mtype = MemoryType {min = E.mem_size env; max = None}} ] in


  let data = List.map (fun (offset, init) -> nr {
    index = nr 0l;
    offset = nr (G.to_instr_list (compile_unboxed_const offset));
    init;
    }) (E.get_static_memory env) in

  let module_ = {
      types = List.map nr (E.get_types env);
      funcs = List.map (fun (f,_,_) -> f) funcs;
      tables = [ nr { ttype = TableType ({min = table_sz; max = Some table_sz}, FuncRefType) } ];
      elems = [ nr {
        index = nr 0l;
        offset = nr (G.to_instr_list (compile_unboxed_const ni'));
        init = List.mapi (fun i _ -> nr (Wasm.I32.of_int_u (ni + i))) funcs } ];
      start = Some (nr rts_start_fi);
      globals = E.get_globals env;
      memories = memories;
      imports = func_imports @ other_imports;
      exports = E.get_exports env;
      data
    } in

  let emodule =
    let open Wasm_exts.CustomModule in
    { module_;
      dylink = None;
      name = {
        module_ = Some module_name;
        function_names =
            List.mapi (fun i (f,n,_) -> Int32.(add ni' (of_int i), n)) funcs;
        locals_names =
            List.mapi (fun i (f,_,ln) -> Int32.(add ni' (of_int i), ln)) funcs;
      };
    } in

  match E.get_rts env with
  | None -> emodule
  | Some rts -> Linking.LinkModule.link emodule "rts" rts

let compile mode module_name rts (prelude : Ir.prog) (progs : Ir.prog list) : Wasm_exts.CustomModule.extended_module =
  let env = E.mk_global mode rts prelude Dfinity.trap_with Stack.end_of_stack in

  Heap.register_globals env;
  Stack.register_globals env;

  Dfinity.system_imports env;
  RTS.system_imports env;
  RTS_Exports.system_exports env;

  let start_fun = compile_start_func env (prelude :: progs) in
  let start_fi = E.add_fun env "start" start_fun in
  let start_fi_o = match E.mode env with
    | Flags.ICMode | Flags.StubMode -> Dfinity.export_start env start_fi; None
    | Flags.WasmMode | Flags.WASIMode-> Some (nr start_fi) in

  conclude_module env module_name start_fi_o
