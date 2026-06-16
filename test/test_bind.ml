open Promptdsl

let bind src values =
  match Compile.parse_and_check src with
  | Error ds -> Alcotest.failf "sema error: %s" (String.concat "; " (List.map (fun (d:Error.t) -> d.Error.message) ds))
  | Ok c -> Bind.bind c values

let test_subst_and_default () =
  match bind {|agent "a" { input { ticker: string  depth: enum("b","d") = "d" } goal "{{ticker}} {{depth}}" }|}
          [ ("ticker", "TSLA") ] with
  | Error ds -> Alcotest.failf "unexpected: %s" (String.concat "; " (List.map (fun (d:Error.t) -> d.Error.message) ds))
  | Ok b -> Alcotest.(check string) "goal" "TSLA d" b.Bind.b_goal

let test_missing_required () =
  match bind {|agent "a" { input { ticker: string } goal "{{ticker}}" }|} [] with
  | Ok _ -> Alcotest.fail "expected missing-input error"
  | Error ds ->
      Alcotest.(check bool) "missing" true
        (List.exists (fun (d:Error.t) ->
           d.Error.message = "missing required input 'ticker' (use --set ticker=...)") ds)

let test_type_mismatch () =
  match bind {|agent "a" { input { n: int } goal "g {{n}}" }|} [ ("n", "abc") ] with
  | Ok _ -> Alcotest.fail "expected type error"
  | Error ds ->
      Alcotest.(check bool) "type" true
        (List.exists (fun (d:Error.t) -> d.Error.message = "input 'n': expected an int, got \"abc\"") ds)

let test_unknown_set () =
  match bind {|agent "a" { input { x: string } goal "{{x}}" }|} [ ("x","v"); ("y","z") ] with
  | Ok _ -> Alcotest.fail "expected unknown-input error"
  | Error ds ->
      Alcotest.(check bool) "unknown" true
        (List.exists (fun (d:Error.t) -> d.Error.message = "unknown input 'y' passed with --set") ds)

let test_content () =
  match bind {|agent "a" { input { body: string @content } goal "g" }|} [ ("body","hello") ] with
  | Ok b -> Alcotest.(check (option string)) "content" (Some "hello") b.Bind.b_content
  | Error _ -> Alcotest.fail "unexpected error"

let test_no_input_block_content_none () =
  match bind {|agent "a" { goal "g" }|} [] with
  | Ok b -> Alcotest.(check (option string)) "legacy" None b.Bind.b_content
  | Error _ -> Alcotest.fail "unexpected error"

(* An empty `input {}` block is "block present, no @content" -> empty user
   message (Some ""), distinct from no block at all (None -> legacy {{input}}). *)
let test_empty_input_block_content () =
  match bind {|agent "a" { input { } goal "g" }|} [] with
  | Ok b ->
      Alcotest.(check (option string)) "empty block -> empty user msg" (Some "")
        b.Bind.b_content
  | Error _ -> Alcotest.fail "unexpected error"

(* A repeated --set for the same key is last-wins. *)
let test_set_last_wins () =
  match bind {|agent "a" { input { x: string } goal "{{x}}" }|} [ ("x", "A"); ("x", "B") ] with
  | Ok b -> Alcotest.(check string) "last-wins" "B" b.Bind.b_goal
  | Error _ -> Alcotest.fail "unexpected error"

let test_fragment_subst () =
  match Compile.parse {|agent "a" { input { t: string } goal "{{t}} {{fin.disclaimer}}" }|} with
  | Error e -> Alcotest.failf "parse: %s" e.Error.message
  | Ok af -> (
      let frags = [ ("fin", [ ("disclaimer", "D") ]) ] in
      match Sema.analyze ~fragments:frags af.Ast.af_agent with
      | Error _ -> Alcotest.fail "sema error"
      | Ok c -> (
          match Bind.bind ~fragments:frags c [ ("t", "X") ] with
          | Error _ -> Alcotest.fail "bind error"
          | Ok b -> Alcotest.(check string) "subst" "X D" b.Bind.b_goal))

let test_float_input () =
  (match bind {|agent "a" { input { pe: float } goal "{{pe}}" }|} [ ("pe", "12.5") ] with
   | Ok b -> Alcotest.(check string) "ok" "12.5" b.Bind.b_goal
   | Error _ -> Alcotest.fail "expected ok");
  (match bind {|agent "a" { input { pe: float } goal "{{pe}}" }|} [ ("pe", "abc") ] with
   | Ok _ -> Alcotest.fail "expected type error"
   | Error ds ->
       Alcotest.(check bool) "bad" true
         (List.exists (fun (d : Error.t) -> d.Error.message = "input 'pe': expected a number, got \"abc\"") ds))

let suite =
  ( "bind",
    [ Alcotest.test_case "subst + default" `Quick test_subst_and_default;
      Alcotest.test_case "missing required" `Quick test_missing_required;
      Alcotest.test_case "type mismatch" `Quick test_type_mismatch;
      Alcotest.test_case "unknown --set" `Quick test_unknown_set;
      Alcotest.test_case "content" `Quick test_content;
      Alcotest.test_case "no input block" `Quick test_no_input_block_content_none;
      Alcotest.test_case "empty input block" `Quick test_empty_input_block_content;
      Alcotest.test_case "set last-wins" `Quick test_set_last_wins;
      Alcotest.test_case "fragment subst" `Quick test_fragment_subst;
      Alcotest.test_case "float input" `Quick test_float_input ] )
