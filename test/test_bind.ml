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

let suite =
  ( "bind",
    [ Alcotest.test_case "subst + default" `Quick test_subst_and_default;
      Alcotest.test_case "missing required" `Quick test_missing_required;
      Alcotest.test_case "type mismatch" `Quick test_type_mismatch;
      Alcotest.test_case "unknown --set" `Quick test_unknown_set;
      Alcotest.test_case "content" `Quick test_content;
      Alcotest.test_case "no input block" `Quick test_no_input_block_content_none ] )
