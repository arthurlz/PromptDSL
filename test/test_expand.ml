open Promptdsl

(* Build a resolved with a single template under alias.name. *)
let resolved_with alias name items : Resolve.resolved =
  { Resolve.fragments = []; templates = [ ((alias, name), items) ] }

(* Parse an agent file and return its agent_block. *)
let agent src =
  match Compile.parse src with
  | Error e -> Alcotest.failf "parse: %s" e.Error.message
  | Ok af -> af.Ast.af_agent

let counts (b : Ast.agent_block) =
  let n f = List.length (List.filter f b.Ast.block_items) in
  ( n (function Ast.IGoal _ -> true | _ -> false),
    n (function Ast.IStep _ -> true | _ -> false),
    n (function Ast.IOutput _ -> true | _ -> false) )

let goal_text (b : Ast.agent_block) =
  List.find_map (function Ast.IGoal g -> Some g.Ast.v | _ -> None) b.Ast.block_items

let test_inherit_and_override () =
  let tpl = (agent {|agent "t" { goal "T" step { summarize } step { summarize } }|}).Ast.block_items in
  let ag = agent {|agent "a" extends m.Base { goal "A" }|} in
  match Expand.expand (resolved_with "m" "Base" tpl) ag with
  | Error _ -> Alcotest.fail "unexpected error"
  | Ok merged ->
      Alcotest.(check (option string)) "goal overridden" (Some "A") (goal_text merged);
      let _, steps, _ = counts merged in
      Alcotest.(check int) "steps inherited" 2 steps

let test_unknown_template () =
  let ag = agent {|agent "a" extends m.Nope { goal "A" }|} in
  match Expand.expand (resolved_with "m" "Base" []) ag with
  | Ok _ -> Alcotest.fail "expected error"
  | Error ds ->
      Alcotest.(check bool) "unknown template" true
        (List.exists (fun (d : Error.t) -> d.Error.message = "unknown template 'm.Nope'") ds)

let test_no_extends_passthrough () =
  let ag = agent {|agent "a" { goal "A" }|} in
  match Expand.expand { Resolve.fragments = []; templates = [] } ag with
  | Ok merged -> Alcotest.(check (option string)) "unchanged" (Some "A") (goal_text merged)
  | Error _ -> Alcotest.fail "unexpected error"

let suite =
  ( "expand",
    [ Alcotest.test_case "inherit + override" `Quick test_inherit_and_override;
      Alcotest.test_case "unknown template" `Quick test_unknown_template;
      Alcotest.test_case "no extends" `Quick test_no_extends_passthrough ] )
