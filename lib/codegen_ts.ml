(* TypeScript typed-client codegen. *)

(* --- identifiers --- *)

(* Split a name into alphanumeric words (drop other chars). *)
let words (s : string) : string list =
  let buf = Buffer.create 16 in
  let out = ref [] in
  let flush () = if Buffer.length buf > 0 then (out := Buffer.contents buf :: !out; Buffer.clear buf) in
  String.iter
    (fun c ->
      if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
      then Buffer.add_char buf c
      else flush ())
    s;
  flush ();
  List.rev !out

let cap s =
  if s = "" then s
  else String.make 1 (Char.uppercase_ascii s.[0]) ^ String.sub s 1 (String.length s - 1)

(* Leading digit would be an invalid identifier; prefix with '_'. *)
let safe_ident s = if s <> "" && s.[0] >= '0' && s.[0] <= '9' then "_" ^ s else s

let pascal (name : string) : string =
  safe_ident (match words name with [] -> "Agent" | ws -> String.concat "" (List.map cap ws))

let camel (name : string) : string =
  let p = pascal name in
  if p = "" then p else String.make 1 (Char.lowercase_ascii p.[0]) ^ String.sub p 1 (String.length p - 1)

(* --- TS type mapping --- *)

let union opts = String.concat " | " (List.map (fun o -> Yojson.Safe.to_string (`String o)) opts)

let rec ts_of_ast_ty (t : Ast.ty) : string =
  match t with
  | Ast.TString -> "string"
  | Ast.TInt | Ast.TFloat -> "number"
  | Ast.TBool -> "boolean"
  | Ast.TEnum opts -> union opts
  | Ast.TList t -> ts_of_ast_ty t ^ "[]"

let rec ts_of_schema_ty (t : Ir.schema_ty) : string =
  match t with
  | Ir.SString -> "string"
  | Ir.SInt | Ir.SFloat -> "number"
  | Ir.SBool -> "boolean"
  | Ir.SEnum opts -> union opts
  | Ir.SList t -> ts_of_schema_ty t ^ "[]"

(* --- template IR (fragments resolved, input refs left as {{name}} holes) --- *)

let template_ir (checked : Sema.checked) (fragments : Resolve.fragments) : Ir.t =
  let frag_lookup x =
    match String.index_opt x '.' with
    | Some i ->
        let alias = String.sub x 0 i in
        let name = String.sub x (i + 1) (String.length x - i - 1) in
        Resolve.lookup fragments alias name
    | None -> None
  in
  let b_goal = Interp.subst frag_lookup checked.Sema.goal in
  let b_steps =
    List.map
      (fun (s : Sema.checked_step) ->
        { s with Sema.arg = Option.map (Interp.subst frag_lookup) s.Sema.arg })
      checked.Sema.steps
  in
  let b_content =
    match List.find_opt (fun (i : Sema.checked_input) -> i.Sema.ci_content) checked.Sema.inputs with
    | Some i -> Some ("{{" ^ i.Sema.ci_name ^ "}}")
    | None -> if checked.Sema.has_input_block then Some "" else None
  in
  Lower.lower
    { Bind.b_name = checked.Sema.name; b_goal; b_steps;
      b_output = checked.Sema.output; b_content }
