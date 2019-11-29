open Mo_types
open Mo_frontend
open Declaration_index
module Lsp_t = Lsp.Lsp_t

let string_of_list f xs =
  List.map f xs
  |> String.concat "; "
  |> fun x -> "[ " ^ x ^ " ]"

let template_of_ide_decl decl =
  let supply = ref 0 in
  let fresh () = supply := !supply + 1; string_of_int !supply in
  match decl with
  | ValueDecl value ->
     (match value.typ with
      | Type.Func(_, _, binds, ty_list1, ty_list2) ->
         let ty_args =
           binds
           |> List.map (fun Type.{ var = var; bound = bound} ->
                  Printf.sprintf "${%s:%s}" (fresh ()) var)
           |> String.concat ", " in
         let args =
           ty_list1
           |> List.map (fun _ -> Printf.sprintf "$%s" (fresh ()))
           |> String.concat ", " in
         let ty_args = if ty_args = "" then "" else "<" ^ ty_args ^ ">" in
         Printf.sprintf "%s%s(%s)" value.name ty_args args
      | _ -> value.name)
  | TypeDecl ty ->
     ty.name

let item_of_ide_decl (d : ide_decl) : Lsp_t.completion_item =
  let tmpl = template_of_ide_decl d in
  match d with
  | ValueDecl value ->
     Lsp_t.{
        completion_item_label = value.name;
        completion_item_kind = 3;
        completion_item_insertText = tmpl;
        completion_item_insertTextFormat = 2;
        completion_item_detail = Some(Type.string_of_typ value.typ);
     }
  | TypeDecl ty ->
     let con = ty.typ in
     let eq, params, typ = Type.strings_of_kind (Con.kind con) in
     Lsp_t.{
        completion_item_label = ty.name;
        completion_item_kind = 7;
        completion_item_insertText = tmpl;
        completion_item_insertTextFormat = 2;
        completion_item_detail =
          Some
            (Printf.sprintf
               "type %s%s"
               ty.name
               params);
     }


let import_relative_to_project_root root module_path dependency =
  match Pipeline__.File_path.relative_to root module_path with
  | None -> None
  | Some root_to_module ->
     root_to_module
     |> Filename.dirname
     |> Lib.Fun.flip Filename.concat dependency
     |> Pipeline__.File_path.normalise
     |> Lib.Option.some

(* Given a source file and a cursor position in that file, figure out
   the prefix relevant to searching completions. For example, given:

   List.fi| (where | is the cursor) return `Some ("List", "fi")` *)
let find_completion_prefix logger file line column: (string * string) option =
  (* The LSP sends 0 based line numbers *)
  let line = line + 1 in
  let lexbuf = Lexing.from_string file in
  let next () = Lexer.token Lexer.Normal lexbuf in
  let pos_eq_cursor pos =
    pos.Source.line = line && pos.Source.column = column in
  let pos_past_cursor pos =
    pos.Source.line > line
    || (pos.Source.line = line && pos.Source.column > column) in
  let rec loop = function
    | _ when (pos_past_cursor (Lexer.region lexbuf).Source.right) -> None
    | Parser.ID ident ->
       let next_token_end = (Lexer.region lexbuf).Source.right in
       if pos_eq_cursor next_token_end
       then Some("", ident)
       else
       (match next () with
        | Parser.DOT ->
           (match next () with
            | Parser.EOF -> Some (ident, "")
            | Parser.ID prefix ->
               let next_token_end = (Lexer.region lexbuf).Source.right in
               if pos_eq_cursor next_token_end
               then Some (ident, prefix)
               else loop (Parser.ID prefix)
            | tkn ->
               let next_token_start = (Lexer.region lexbuf).Source.left in
               if pos_eq_cursor next_token_start
                  || pos_past_cursor next_token_start
               then Some (ident, "")
               else loop tkn)
        | tkn -> loop tkn)
    | Parser.EOF -> None
    | _ -> loop (next ()) in
  try loop (next ()) with _ -> None

let has_prefix (prefix : string) (ide_decl : ide_decl): bool =
  ide_decl
  |> name_of_ide_decl
  |> Lib.String.chop_prefix prefix
  |> Lib.Option.is_some

let opt_bind f = function
  | None -> None
  | Some x -> f x

let completions index logger project_root file_path file_contents line column =
  let imported = Source_file.parse_module_header project_root file_path file_contents in
  let current_uri_opt = Pipeline__.File_path.relative_to project_root file_path in
  let module_alias_completion_item alias =
    Lsp_t.{
        completion_item_label = alias;
        completion_item_kind = 9;
        completion_item_insertText = alias;
        completion_item_insertTextFormat = 1;
        completion_item_detail = None;
    } in
  match find_completion_prefix logger file_contents line column with
  | None ->
     (* If we don't have any prefix to work with, just suggest the
        imported module aliases, as well as top-level definitions in
        the current file *)
     let toplevel =
       current_uri_opt
       |> opt_bind (fun uri -> Index.find_opt uri index)
       |> Lib.Option.map (List.map item_of_ide_decl)
       |> Lib.Fun.flip Lib.Option.get [] in
     imported
     |> List.map (fun (alias, _) -> module_alias_completion_item alias)
     |> List.append toplevel
  | Some ("", prefix) ->
     (* Without an alias but with a prefix we filter the toplevel
        idenfiers of the current module *)
       current_uri_opt
       |> opt_bind (fun uri -> Index.find_opt uri index)
       |> Lib.Option.map (fun decls ->
            decls
            |> List.filter (has_prefix prefix)
            |> List.map item_of_ide_decl)
       |> Lib.Fun.flip Lib.Option.get []
  | Some (alias, prefix) ->
     let module_path =
       imported
       |> List.find_opt (fun (mn, _) -> String.equal mn alias) in
     match module_path with
     | Some mp ->
        (match Index.find_opt (snd mp) index with
         | Some decls ->
            decls
            |> List.filter (has_prefix prefix)
            |> List.map item_of_ide_decl
         | None ->
            (* The matching import references a module we haven't loaded *)
            [])
     | None ->
        (* No module with the given prefix was found *)
        []

let completion_handler index logger project_root file_path file_contents position =
  let line = position.Lsp_t.position_line in
  let column = position.Lsp_t.position_character in
  `CompletionResponse
    (completions index logger project_root file_path file_contents line column)
