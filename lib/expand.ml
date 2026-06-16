(* Split a body into the four clause sublists (inputs, goal, steps, output),
   preserving order within each. *)
let classify (items : Ast.agent_item list) =
  ( List.filter (function Ast.IInputs _ -> true | _ -> false) items,
    List.filter (function Ast.IGoal _ -> true | _ -> false) items,
    List.filter (function Ast.IStep _ -> true | _ -> false) items,
    List.filter (function Ast.IOutput _ -> true | _ -> false) items )

let expand (resolved : Resolve.resolved) (block : Ast.agent_block) :
    (Ast.agent_block, Error.t list) result =
  match block.Ast.block_extends with
  | None -> Ok block
  | Some (alias, name, loc) -> (
      match Resolve.find_template resolved alias name with
      | None ->
          Error [ Error.make loc (Printf.sprintf "unknown template '%s.%s'" alias name) ]
      | Some tpl_items ->
          let ai, ag, as_, ao = classify block.Ast.block_items in
          let ti, tg, ts, to_ = classify tpl_items in
          let pick a t = if a <> [] then a else t in
          let merged = pick ai ti @ pick ag tg @ pick as_ ts @ pick ao to_ in
          Ok { block with Ast.block_items = merged; block_extends = None })
