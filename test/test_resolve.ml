open Promptdsl

(* in-memory loader *)
let mem files path =
  match List.assoc_opt path files with Some c -> Ok c | None -> Error "no such file"

let imp path alias = { Ast.imp_path = path; imp_alias = alias; imp_loc = Location.dummy }

let test_resolve_ok () =
  let files = [ ("fin.prompt", {|def disclaimer = "D"  def rubric = "R"|}) ] in
  match
    Resolve.resolve ~parse_lib:Compile.parse_library ~resolver:(mem files)
      [ imp "fin.prompt" "fin" ]
  with
  | Error _ -> Alcotest.fail "unexpected error"
  | Ok r ->
      Alcotest.(check (option string)) "found" (Some "D")
        (Resolve.lookup r.Resolve.fragments "fin" "disclaimer")

let test_resolve_template () =
  let files = [ ("s.prompt", {|template Rater { step { summarize } }|}) ] in
  match
    Resolve.resolve ~parse_lib:Compile.parse_library ~resolver:(mem files) [ imp "s.prompt" "s" ]
  with
  | Error _ -> Alcotest.fail "unexpected error"
  | Ok r -> (
      match Resolve.find_template r "s" "Rater" with
      | Some items -> Alcotest.(check int) "tpl items" 1 (List.length items)
      | None -> Alcotest.fail "expected template Rater")

let has msg ds = List.exists (fun (d : Error.t) -> d.Error.message = msg) ds

let test_resolve_not_found () =
  match Resolve.resolve ~parse_lib:Compile.parse_library ~resolver:(mem []) [ imp "x.prompt" "x" ] with
  | Ok _ -> Alcotest.fail "expected error"
  | Error ds ->
      Alcotest.(check bool) "not found" true (has "cannot import \"x.prompt\": no such file" ds)

let test_resolve_not_def_only () =
  let files = [ ("bad.prompt", {|agent "a" { goal "g" }|}) ] in
  match Resolve.resolve ~parse_lib:Compile.parse_library ~resolver:(mem files) [ imp "bad.prompt" "b" ] with
  | Ok _ -> Alcotest.fail "expected error"
  | Error ds ->
      Alcotest.(check bool) "not def-only" true
        (List.exists
           (fun (d : Error.t) ->
             let m = d.Error.message in
             String.length m >= 13 && String.sub m 0 13 = "imported file")
           ds)

let test_resolve_dup_alias () =
  let files = [ ("a.prompt", {|def x = "1"|}) ] in
  match
    Resolve.resolve ~parse_lib:Compile.parse_library ~resolver:(mem files)
      [ imp "a.prompt" "fin"; imp "a.prompt" "fin" ]
  with
  | Ok _ -> Alcotest.fail "expected error"
  | Error ds ->
      Alcotest.(check bool) "dup alias" true (has "duplicate import alias 'fin'" ds)

let suite =
  ( "resolve",
    [ Alcotest.test_case "ok" `Quick test_resolve_ok;
      Alcotest.test_case "template" `Quick test_resolve_template;
      Alcotest.test_case "not found" `Quick test_resolve_not_found;
      Alcotest.test_case "not def-only" `Quick test_resolve_not_def_only;
      Alcotest.test_case "dup alias" `Quick test_resolve_dup_alias ] )
