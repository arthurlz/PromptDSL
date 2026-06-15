open Promptdsl

let msgs ds = String.concat "; " (List.map (fun (d : Error.t) -> d.Error.message) ds)

let analyze src =
  match Compile.parse src with
  | Error e -> Alcotest.failf "parse error: %s" e.Error.message
  | Ok af -> Sema.analyze af.Ast.af_agent

let ok_or_fail src =
  match analyze src with
  | Ok c -> c
  | Error ds -> Alcotest.failf "unexpected errors: %s" (msgs ds)

let err_or_fail src =
  match analyze src with
  | Error ds -> ds
  | Ok _ -> Alcotest.fail "expected an error"

let test_levenshtein () =
  Alcotest.(check int) "off-by-one" 1 (Sema.levenshtein "search" "serch");
  Alcotest.(check int) "equal" 0 (Sema.levenshtein "abc" "abc")

let test_closest () =
  Alcotest.(check (option string)) "near" (Some "search")
    (Sema.closest "serch" Sema.known_actions);
  Alcotest.(check (option string)) "far" None
    (Sema.closest "zzzzzzz" Sema.known_actions)

let test_valid () =
  let c = ok_or_fail {|agent "a" { goal "g" step { summarize } }|} in
  Alcotest.(check string) "goal" "g" c.Sema.goal;
  Alcotest.(check int) "steps" 1 (List.length c.Sema.steps)

let test_unknown_action () =
  let ds = err_or_fail {|agent "a" { goal "g" step { searchh "x" } }|} in
  let d = List.hd ds in
  Alcotest.(check string) "msg" "unknown action 'searchh'" d.Error.message;
  Alcotest.(check (option string)) "hint" (Some "did you mean 'search'?") d.Error.hint

let test_missing_goal () =
  let ds = err_or_fail {|agent "a" { step { summarize } }|} in
  Alcotest.(check bool) "missing goal" true
    (List.exists (fun (d : Error.t) -> d.Error.message = "missing required 'goal'") ds)

let test_instruct_no_arg () =
  let ds = err_or_fail {|agent "a" { goal "g" step { instruct } }|} in
  Alcotest.(check string) "msg" "'instruct' requires a string argument"
    (List.hd ds).Error.message

let test_dup_field () =
  let ds = err_or_fail {|agent "a" { goal "g" output json { x: string x: int } }|} in
  Alcotest.(check bool) "dup field" true
    (List.exists (fun (d : Error.t) -> d.Error.message = "duplicate field 'x'") ds)

let test_schema_on_text () =
  let ds = err_or_fail {|agent "a" { goal "g" output text { x: string } }|} in
  Alcotest.(check bool) "schema-on-text" true
    (List.exists
       (fun (d : Error.t) -> d.Error.message = "'text' output does not take a schema")
       ds)

(* Block-level errors (missing goal at 1:1) must be reported before later
   item errors, i.e. diagnostics come out in source order. *)
let test_error_order () =
  let ds =
    err_or_fail {|agent "a" {
  step { searchh "x" }
}|}
  in
  match ds with
  | first :: _ ->
      Alcotest.(check string) "first is missing goal" "missing required 'goal'"
        first.Error.message;
      Alcotest.(check int) "first on line 1" 1 first.Error.loc.Location.start_line
  | [] -> Alcotest.fail "expected errors"

(* A string-token diagnostic points at the OPENING quote. In
   `agent "a" { goal "x" goal "y" }` the second goal's string opens at
   column 27 (1-based). *)
let test_string_span () =
  let ds = err_or_fail {|agent "a" { goal "x" goal "y" }|} in
  match
    List.find_opt (fun (d : Error.t) -> d.Error.message = "duplicate 'goal'") ds
  with
  | Some d ->
      Alcotest.(check int) "line" 1 d.Error.loc.Location.start_line;
      Alcotest.(check int) "opening-quote col" 27 d.Error.loc.Location.start_col
  | None -> Alcotest.fail "expected duplicate 'goal' error"

let test_unknown_format () =
  let ds = err_or_fail {|agent "a" { goal "g" output josn }|} in
  let d = List.hd ds in
  Alcotest.(check string) "msg" "unknown output format 'josn'" d.Error.message;
  Alcotest.(check (option string)) "hint" (Some "did you mean 'json'?") d.Error.hint

let test_dup_output () =
  let ds = err_or_fail {|agent "a" { goal "g" output text output json }|} in
  Alcotest.(check bool) "dup output" true
    (List.exists
       (fun (d : Error.t) -> d.Error.message = "duplicate 'output'")
       ds)

let test_valid_inputs () =
  let c =
    ok_or_fail
      {|agent "a" { input { ticker: string  depth: enum("b","d") = "b" } goal "x {{ticker}} {{depth}}" }|}
  in
  Alcotest.(check int) "inputs" 2 (List.length c.Sema.inputs)

let test_undeclared_ref () =
  let ds = err_or_fail {|agent "a" { goal "analyze {{ticker}}" }|} in
  Alcotest.(check bool) "undeclared ref" true
    (List.exists
       (fun (d : Error.t) -> d.Error.message = "undeclared input reference '{{ticker}}'")
       ds)

let test_dup_input () =
  let ds = err_or_fail {|agent "a" { input { x: string  x: string } goal "g" }|} in
  Alcotest.(check bool) "dup input" true
    (List.exists (fun (d : Error.t) -> d.Error.message = "duplicate input 'x'") ds)

let test_two_content () =
  let ds =
    err_or_fail {|agent "a" { input { x: string @content  y: string @content } goal "g" }|}
  in
  Alcotest.(check bool) "two content" true
    (List.exists
       (fun (d : Error.t) -> d.Error.message = "at most one input may be @content")
       ds)

let test_default_on_int () =
  let ds = err_or_fail {|agent "a" { input { n: int = "5" } goal "g" }|} in
  Alcotest.(check bool) "default on int" true
    (List.exists
       (fun (d : Error.t) ->
         d.Error.message = "a default is only allowed on string or enum inputs")
       ds)

let test_content_not_string () =
  let ds = err_or_fail {|agent "a" { input { n: int @content } goal "g" }|} in
  Alcotest.(check bool) "content not string" true
    (List.exists
       (fun (d : Error.t) -> d.Error.message = "@content must be on a string input")
       ds)

let test_list_input () =
  let ds = err_or_fail {|agent "a" { input { items: list<string> } goal "g" }|} in
  Alcotest.(check bool) "list rejected" true
    (List.exists
       (fun (d : Error.t) -> d.Error.message = "list is not allowed as an input type")
       ds)

let test_enum_default_not_member () =
  let ds =
    err_or_fail {|agent "a" { input { d: enum("low","high") = "medium" } goal "g" }|}
  in
  Alcotest.(check bool) "bad enum default" true
    (List.exists
       (fun (d : Error.t) ->
         d.Error.message = {|default "medium" is not one of the enum options|})
       ds)

(* The {{ref}}-declared check runs after the whole-body pass, so a goal that
   references an input declared later in the file is still valid. *)
let test_goal_before_input () =
  let c =
    ok_or_fail {|agent "a" { goal "analyze {{ticker}}" input { ticker: string } }|}
  in
  Alcotest.(check int) "inputs" 1 (List.length c.Sema.inputs)

let analyze_with frags src =
  match Compile.parse src with
  | Error e -> Alcotest.failf "parse error: %s" e.Error.message
  | Ok af -> Sema.analyze ~fragments:frags af.Ast.af_agent

let test_fragment_ref_ok () =
  let frags = [ ("fin", [ ("disclaimer", "D") ]) ] in
  match analyze_with frags {|agent "a" { goal "g {{fin.disclaimer}}" }|} with
  | Ok _ -> ()
  | Error ds ->
      Alcotest.failf "unexpected: %s"
        (String.concat "; " (List.map (fun (d : Error.t) -> d.Error.message) ds))

let test_unknown_alias () =
  match analyze_with [] {|agent "a" { goal "g {{fin.disclaimer}}" }|} with
  | Ok _ -> Alcotest.fail "expected error"
  | Error ds ->
      Alcotest.(check bool) "unknown alias" true
        (List.exists (fun (d : Error.t) -> d.Error.message = "unknown import alias 'fin'") ds)

let test_unknown_def () =
  let frags = [ ("fin", [ ("disclaimer", "D") ]) ] in
  match analyze_with frags {|agent "a" { goal "g {{fin.nope}}" }|} with
  | Ok _ -> Alcotest.fail "expected error"
  | Error ds ->
      Alcotest.(check bool) "unknown def" true
        (List.exists
           (fun (d : Error.t) -> d.Error.message = "no def 'nope' in import 'fin'") ds)

let suite =
  ( "sema",
    [ Alcotest.test_case "levenshtein" `Quick test_levenshtein;
      Alcotest.test_case "closest" `Quick test_closest;
      Alcotest.test_case "valid" `Quick test_valid;
      Alcotest.test_case "unknown action" `Quick test_unknown_action;
      Alcotest.test_case "missing goal" `Quick test_missing_goal;
      Alcotest.test_case "instruct no arg" `Quick test_instruct_no_arg;
      Alcotest.test_case "dup field" `Quick test_dup_field;
      Alcotest.test_case "schema on text" `Quick test_schema_on_text;
      Alcotest.test_case "error order" `Quick test_error_order;
      Alcotest.test_case "string span" `Quick test_string_span;
      Alcotest.test_case "unknown format" `Quick test_unknown_format;
      Alcotest.test_case "dup output" `Quick test_dup_output;
      Alcotest.test_case "valid inputs" `Quick test_valid_inputs;
      Alcotest.test_case "undeclared ref" `Quick test_undeclared_ref;
      Alcotest.test_case "dup input" `Quick test_dup_input;
      Alcotest.test_case "two content" `Quick test_two_content;
      Alcotest.test_case "default on int" `Quick test_default_on_int;
      Alcotest.test_case "content not string" `Quick test_content_not_string;
      Alcotest.test_case "list input rejected" `Quick test_list_input;
      Alcotest.test_case "enum default not member" `Quick test_enum_default_not_member;
      Alcotest.test_case "goal before input" `Quick test_goal_before_input;
      Alcotest.test_case "fragment ref ok" `Quick test_fragment_ref_ok;
      Alcotest.test_case "unknown alias" `Quick test_unknown_alias;
      Alcotest.test_case "unknown def" `Quick test_unknown_def ] )
