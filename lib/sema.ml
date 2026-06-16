open Ast

type checked_step = { verb : string; arg : string option }

type checked_output =
  | COText
  | COMarkdown
  | COJson of Ast.field list option

type checked_input = {
  ci_name : string;
  ci_ty : Ast.ty;
  ci_default : string option;
  ci_content : bool;
  ci_loc : Location.t;
}

type checked = {
  name : string;
  goal : string;
  steps : checked_step list;
  output : checked_output;
  inputs : checked_input list;
  has_input_block : bool;
}

let known_actions =
  [ "search"; "summarize"; "extract"; "translate"; "classify"; "instruct" ]

let known_formats = [ "text"; "markdown"; "json" ]

let levenshtein a b =
  let la = String.length a and lb = String.length b in
  let d = Array.make_matrix (la + 1) (lb + 1) 0 in
  for i = 0 to la do d.(i).(0) <- i done;
  for j = 0 to lb do d.(0).(j) <- j done;
  for i = 1 to la do
    for j = 1 to lb do
      let cost = if a.[i - 1] = b.[j - 1] then 0 else 1 in
      d.(i).(j) <-
        min
          (min (d.(i - 1).(j) + 1) (d.(i).(j - 1) + 1))
          (d.(i - 1).(j - 1) + cost)
    done
  done;
  d.(la).(lb)

let closest target candidates =
  let scored = List.map (fun c -> (c, levenshtein target c)) candidates in
  match List.sort (fun (_, x) (_, y) -> compare x y) scored with
  | (c, dist) :: _ when dist <= 2 -> Some c
  | _ -> None

let hint_for target candidates =
  match closest target candidates with
  | Some s -> Some (Printf.sprintf "did you mean '%s'?" s)
  | None -> None

let analyze ?(fragments : Resolve.fragments = []) (block : Ast.agent_block) : (checked, Error.t list) result =
  let errors = ref [] in
  let add e = errors := e :: !errors in
  let goal = ref None and steps = ref [] and output = ref None in
  let inputs = ref [] and saw_input_block = ref false in
  let ref_sites = ref [] in   (* (text, span) to validate {{...}} against declared inputs *)
  let check_dup_fields fields =
    let seen = Hashtbl.create 8 in
    List.iter
      (fun (f : Ast.field) ->
        if Hashtbl.mem seen f.field_name then
          add
            (Error.make f.field_loc
               (Printf.sprintf "duplicate field '%s'" f.field_name))
        else Hashtbl.add seen f.field_name ())
      fields
  in
  let check_field_ranges fields =
    List.iter
      (fun (f : Ast.field) ->
        match f.field_range with
        | None -> ()
        | Some (lo, hi) -> (
            match f.field_ty with
            | Ast.TInt ->
                if Float.rem lo 1.0 <> 0.0 || Float.rem hi 1.0 <> 0.0 then
                  add (Error.make f.field_loc "int range bounds must be integers")
            | Ast.TFloat -> ()
            | _ -> add (Error.make f.field_loc "range is only allowed on int or float fields")))
      fields
  in
  List.iter
    (fun item ->
      match item with
      | IGoal g -> (
          ref_sites := (g.v, g.span) :: !ref_sites;
          match !goal with
          | None -> goal := Some g.v
          | Some _ -> add (Error.make g.span "duplicate 'goal'"))
      | IStep a ->
          let name = a.action_name.v in
          (match a.action_arg with
           | Some arg -> ref_sites := (arg, a.action_name.span) :: !ref_sites
           | None -> ());
          if not (List.mem name known_actions) then
            add
              (Error.make ?hint:(hint_for name known_actions) a.action_name.span
                 (Printf.sprintf "unknown action '%s'" name))
          else if name = "instruct" && a.action_arg = None then
            add
              (Error.make a.action_name.span
                 "'instruct' requires a string argument")
          else steps := { verb = name; arg = a.action_arg } :: !steps
      | IInputs blk ->
          if !saw_input_block then
            add (Error.make blk.span "duplicate 'input' block")
          else begin
            saw_input_block := true;
            let seen = Hashtbl.create 8 in
            let content_count = ref 0 in
            List.iter
              (fun (d : Ast.input_decl) ->
                (if Hashtbl.mem seen d.in_name then
                   add (Error.make d.in_loc (Printf.sprintf "duplicate input '%s'" d.in_name))
                 else Hashtbl.add seen d.in_name ());
                (match d.in_ty with
                 | Ast.TList _ ->
                     add (Error.make d.in_loc "list is not allowed as an input type")
                 | _ -> ());
                (match (d.in_default, d.in_ty) with
                 | Some _, Ast.TString -> ()
                 | Some def, Ast.TEnum opts ->
                     if not (List.mem def opts) then
                       add (Error.make d.in_loc
                              (Printf.sprintf "default %S is not one of the enum options" def))
                 | Some _, _ ->
                     add (Error.make d.in_loc
                            "a default is only allowed on string or enum inputs")
                 | None, _ -> ());
                (if d.in_content then begin
                   incr content_count;
                   (match d.in_ty with
                    | Ast.TString -> ()
                    | _ -> add (Error.make d.in_loc "@content must be on a string input"))
                 end);
                inputs :=
                  { ci_name = d.in_name; ci_ty = d.in_ty; ci_default = d.in_default;
                    ci_content = d.in_content; ci_loc = d.in_loc }
                  :: !inputs)
              blk.v;
            if !content_count > 1 then
              add (Error.make blk.span "at most one input may be @content")
          end
      | IOutput o -> (
          match !output with
          | Some _ -> add (Error.make o.span "duplicate 'output'")
          | None -> (
              let ro = o.v in
              match ro.out_format.v with
              | "text" -> (
                  match ro.out_schema with
                  | Some _ ->
                      add (Error.make o.span "'text' output does not take a schema")
                  | None -> output := Some COText)
              | "markdown" -> (
                  match ro.out_schema with
                  | Some _ ->
                      add
                        (Error.make o.span
                           "'markdown' output does not take a schema")
                  | None -> output := Some COMarkdown)
              | "json" -> (
                  match ro.out_schema with
                  | None -> output := Some (COJson None)
                  | Some fields ->
                      check_dup_fields fields;
                      check_field_ranges fields;
                      output := Some (COJson (Some fields)))
              | other ->
                  add
                    (Error.make ?hint:(hint_for other known_formats)
                       ro.out_format.span
                       (Printf.sprintf "unknown output format '%s'" other)))))
    block.block_items;
  let goal_val =
    match !goal with
    | Some g -> Some g
    | None ->
        add (Error.make block.block_loc "missing required 'goal'");
        None
  in
  let declared = List.map (fun (i : checked_input) -> i.ci_name) !inputs in
  List.iter
    (fun (text, span) ->
      List.iter
        (fun name ->
          match String.index_opt name '.' with
          | Some i ->
              let alias = String.sub name 0 i in
              let dname = String.sub name (i + 1) (String.length name - i - 1) in
              (match Resolve.find fragments alias dname with
               | Resolve.Found _ -> ()
               | Resolve.NoAlias ->
                   add (Error.make span (Printf.sprintf "unknown import alias '%s'" alias))
               | Resolve.NoDef ->
                   add (Error.make span
                          (Printf.sprintf "no def '%s' in import '%s'" dname alias)))
          | None ->
              if not (List.mem name declared) then
                add (Error.make span
                       (Printf.sprintf "undeclared input reference '{{%s}}'" name)))
        (Interp.refs text))
    (List.rev !ref_sites);
  match !errors with
  | [] ->
      Ok
        {
          name = block.block_name;
          goal = Option.get goal_val;
          steps = List.rev !steps;
          output = Option.value !output ~default:COText;
          inputs = List.rev !inputs;
          has_input_block = !saw_input_block;
        }
  | es ->
      (* Report diagnostics in source order. Item errors are accumulated in
         order, but block-level errors (e.g. missing goal) are added last, so
         sort by span position. *)
      let by_pos (a : Error.t) (b : Error.t) =
        compare
          (a.loc.Location.start_line, a.loc.Location.start_col)
          (b.loc.Location.start_line, b.loc.Location.start_col)
      in
      Error (List.stable_sort by_pos es)
