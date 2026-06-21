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

(* --- request body: Yojson -> TS expression, holes -> ${inputs.name} --- *)

(* Escape a string for inside a `...` template literal: \, `, and ${ . *)
let esc_template (s : string) : string =
  let b = Buffer.create (String.length s + 8) in
  let n = String.length s in
  let i = ref 0 in
  while !i < n do
    let c = s.[!i] in
    if c = '\\' then Buffer.add_string b "\\\\"
    else if c = '`' then Buffer.add_string b "\\`"
    else if c = '$' && !i + 1 < n && s.[!i + 1] = '{' then Buffer.add_string b "\\$"
    else Buffer.add_char b c;
    incr i
  done;
  Buffer.contents b

(* A string value -> a TS expression. If it has {{name}} holes, a template
   literal with ${inputs.name}; otherwise a JSON string literal. *)
let ts_string_expr (s : string) : string =
  if Interp.refs s = [] then Yojson.Safe.to_string (`String s)
  else
    let body =
      Interp.subst (fun name -> Some (Printf.sprintf "${inputs.%s}" name)) (esc_template s)
    in
    "`" ^ body ^ "`"

let rec yojson_to_ts (j : Yojson.Safe.t) : string =
  match j with
  | `String s -> ts_string_expr s
  | `Assoc kvs ->
      "{ "
      ^ String.concat ", "
          (List.map
             (fun (k, v) -> Yojson.Safe.to_string (`String k) ^ ": " ^ yojson_to_ts v)
             kvs)
      ^ " }"
  | `List xs -> "[" ^ String.concat ", " (List.map yojson_to_ts xs) ^ "]"
  | other -> Yojson.Safe.to_string other

(* --- output type --- *)

let ts_output_type (out : Ir.output) : string =
  match out with
  | Ir.OText | Ir.OMarkdown -> "string"
  | Ir.OJson None -> "unknown"
  | Ir.OJson (Some fields) ->
      let field (f : Ir.schema_field) =
        Printf.sprintf "%s%s: %s" f.Ir.fname (if f.required then "" else "?")
          (ts_of_schema_ty f.fty)
      in
      "{ " ^ String.concat "; " (List.map field fields) ^ " }"

(* --- runtime validator --- *)

(* Format a range bound as a TS number literal. *)
let num (f : float) : string =
  if Float.is_integer f then string_of_int (int_of_float f) else Printf.sprintf "%g" f

(* Lines that throw if [acc] (assumed present) doesn't match [fty]/[range]. *)
let rec check_lines (acc : string) (fty : Ir.schema_ty) (range : (float * float) option)
    (label : string) : string list =
  let err msg = Printf.sprintf "throw new Error(%s)" (Yojson.Safe.to_string (`String (label ^ ": " ^ msg))) in
  match fty with
  | Ir.SString -> [ Printf.sprintf "if (typeof %s !== \"string\") %s;" acc (err "expected string") ]
  | Ir.SBool -> [ Printf.sprintf "if (typeof %s !== \"boolean\") %s;" acc (err "expected boolean") ]
  | Ir.SInt | Ir.SFloat ->
      let base = [ Printf.sprintf "if (typeof %s !== \"number\") %s;" acc (err "expected number") ] in
      (match range with
       | Some (lo, hi) ->
           base @ [ Printf.sprintf "if (%s < %s || %s > %s) %s;" acc (num lo) acc (num hi) (err "out of range") ]
       | None -> base)
  | Ir.SEnum opts ->
      let arr = "[" ^ String.concat ", " (List.map (fun o -> Yojson.Safe.to_string (`String o)) opts) ^ "]" in
      [ Printf.sprintf "if (!%s.includes(%s)) %s;" arr acc (err "invalid enum value") ]
  | Ir.SList t ->
      let inner = check_lines "v" t None label in
      [ Printf.sprintf "if (!Array.isArray(%s)) %s;" acc (err "expected array");
        Printf.sprintf "for (const v of %s) { %s }" acc (String.concat " " inner) ]

let gen_validator (tname : string) (fields : Ir.schema_field list) : string =
  let block (f : Ir.schema_field) =
    let acc = Printf.sprintf "x[%s]" (Yojson.Safe.to_string (`String f.Ir.fname)) in
    let lines = check_lines acc f.fty f.range f.fname in
    if f.required then
      let presence =
        Printf.sprintf "if (%s === undefined || %s === null) throw new Error(%s);" acc acc
          (Yojson.Safe.to_string (`String (f.fname ^ ": required")))
      in
      "  " ^ String.concat "\n  " (presence :: lines)
    else
      Printf.sprintf "  if (%s !== undefined && %s !== null) {\n    %s\n  }" acc acc
        (String.concat "\n    " lines)
  in
  Printf.sprintf "function validate%s(x: any): %s {\n%s\n  return x as %s;\n}" tname tname
    (String.concat "\n" (List.map block fields))
    tname
