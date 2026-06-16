type bound = {
  b_name : string;
  b_goal : string;
  b_steps : Sema.checked_step list;
  b_output : Sema.checked_output;
  b_content : string option;
}

let typecheck (ty : Ast.ty) (v : string) : (unit, string) result =
  match ty with
  | Ast.TString -> Ok ()
  | Ast.TInt -> (
      match int_of_string_opt v with
      | Some _ -> Ok ()
      | None -> Error (Printf.sprintf "expected an int, got %S" v))
  | Ast.TBool -> (
      match v with "true" | "false" -> Ok () | _ -> Error (Printf.sprintf "expected true or false, got %S" v))
  | Ast.TEnum opts ->
      if List.mem v opts then Ok ()
      else Error (Printf.sprintf "expected one of %s, got %S" (String.concat "/" opts) v)
  | Ast.TFloat -> (
      match float_of_string_opt v with
      | Some _ -> Ok ()
      | None -> Error (Printf.sprintf "expected a number, got %S" v))
  | Ast.TList _ -> Error "list inputs are not supported"

let bind ?(fragments : Resolve.fragments = []) (c : Sema.checked)
    (values : (string * string) list) : (bound, Error.t list) result =
  let errors = ref [] in
  let add ?(loc = Location.dummy) m = errors := Error.make loc m :: !errors in
  let declared = List.map (fun (i : Sema.checked_input) -> i.Sema.ci_name) c.Sema.inputs in
  List.iter
    (fun (k, _) ->
      if not (List.mem k declared) then
        add (Printf.sprintf "unknown input '%s' passed with --set" k))
    values;
  (* A repeated --set k=v is last-wins, the usual CLI convention. *)
  let latest = List.rev values in
  let resolved = Hashtbl.create 8 in
  List.iter
    (fun (i : Sema.checked_input) ->
      let v =
        match List.assoc_opt i.ci_name latest with
        | Some v -> Some v
        | None -> i.ci_default
      in
      match v with
      | None ->
          add ~loc:i.ci_loc
            (Printf.sprintf "missing required input '%s' (use --set %s=...)" i.ci_name i.ci_name)
      | Some v -> (
          match typecheck i.ci_ty v with
          | Ok () -> Hashtbl.replace resolved i.ci_name v
          | Error msg -> add ~loc:i.ci_loc (Printf.sprintf "input '%s': %s" i.ci_name msg)))
    c.Sema.inputs;
  match List.rev !errors with
  | _ :: _ as es -> Error es
  | [] ->
      let lookup x =
        match String.index_opt x '.' with
        | Some i ->
            let alias = String.sub x 0 i in
            let name = String.sub x (i + 1) (String.length x - i - 1) in
            Resolve.lookup fragments alias name
        | None -> Hashtbl.find_opt resolved x
      in
      let b_goal = Interp.subst lookup c.Sema.goal in
      let b_steps =
        List.map
          (fun (s : Sema.checked_step) ->
            { s with Sema.arg = Option.map (Interp.subst lookup) s.Sema.arg })
          c.Sema.steps
      in
      let b_content =
        match List.find_opt (fun (i : Sema.checked_input) -> i.ci_content) c.Sema.inputs with
        | Some i -> Hashtbl.find_opt resolved i.ci_name
        | None -> if c.Sema.has_input_block then Some "" else None
      in
      Ok { b_name = c.Sema.name; b_goal; b_steps; b_output = c.Sema.output; b_content }
