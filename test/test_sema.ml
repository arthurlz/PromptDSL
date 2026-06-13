open Promptdsl

let msgs ds = String.concat "; " (List.map (fun (d : Error.t) -> d.Error.message) ds)

let analyze src =
  match Compile.parse src with
  | Error e -> Alcotest.failf "parse error: %s" e.Error.message
  | Ok b -> Sema.analyze b

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
      Alcotest.test_case "error order" `Quick test_error_order ] )
