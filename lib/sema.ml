open Ast

type checked_step = { verb : string; arg : string option }

type checked_output =
  | COText
  | COMarkdown
  | COJson of Ast.field list option

type checked = {
  name : string;
  goal : string;
  steps : checked_step list;
  output : checked_output;
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

let analyze (block : Ast.agent_block) : (checked, Error.t list) result =
  let errors = ref [] in
  let add e = errors := e :: !errors in
  let goal = ref None and steps = ref [] and output = ref None in
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
  List.iter
    (fun item ->
      match item with
      | IGoal g -> (
          match !goal with
          | None -> goal := Some g.v
          | Some _ -> add (Error.make g.span "duplicate 'goal'"))
      | IStep a ->
          let name = a.action_name.v in
          if not (List.mem name known_actions) then
            add
              (Error.make ?hint:(hint_for name known_actions) a.action_name.span
                 (Printf.sprintf "unknown action '%s'" name))
          else if name = "instruct" && a.action_arg = None then
            add
              (Error.make a.action_name.span
                 "'instruct' requires a string argument")
          else steps := { verb = name; arg = a.action_arg } :: !steps
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
  match !errors with
  | [] ->
      Ok
        {
          name = block.block_name;
          goal = Option.get goal_val;
          steps = List.rev !steps;
          output = Option.value !output ~default:COText;
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
