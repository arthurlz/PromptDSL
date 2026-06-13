open Promptdsl

let test_lower () =
  let checked =
    {
      Sema.name = "researcher";
      goal = "analyze TSLA";
      steps =
        [ { Sema.verb = "search"; arg = Some "TSLA earnings" };
          { Sema.verb = "summarize"; arg = None } ];
      output =
        Sema.COJson
          (Some
             [ { Ast.field_name = "ticker"; field_ty = Ast.TString;
                 optional = false; field_loc = Location.dummy } ]);
    }
  in
  let ir = Lower.lower checked in
  Alcotest.(check string) "agent" "researcher" ir.Ir.agent_name;
  Alcotest.(check string) "objective" "analyze TSLA" ir.Ir.objective;
  Alcotest.(check (list string)) "instructions"
    [ "Search for: TSLA earnings"; "Summarize the findings" ]
    ir.Ir.instructions;
  match ir.Ir.out with
  | Ir.OJson (Some [ f ]) ->
      Alcotest.(check string) "field name" "ticker" f.Ir.fname;
      Alcotest.(check bool) "required" true f.Ir.required
  | _ -> Alcotest.fail "expected json schema with one field"

(* An empty `output json {}` schema lowers to bare json (no schema), not a
   schema object that forbids all keys. *)
let test_lower_empty_schema () =
  let checked =
    { Sema.name = "a"; goal = "g"; steps = []; output = Sema.COJson (Some []) }
  in
  match (Lower.lower checked).Ir.out with
  | Ir.OJson None -> ()
  | _ -> Alcotest.fail "empty schema should lower to OJson None"

(* Every action verb renders to its expected instruction, with and without
   an argument. *)
let test_all_verbs () =
  let step verb arg = { Sema.verb; arg } in
  let checked =
    {
      Sema.name = "a";
      goal = "g";
      steps =
        [ step "search" None;
          step "extract" (Some "facts");
          step "translate" (Some "ja");
          step "classify" None;
          step "instruct" (Some "Be concise");
          step "summarize" (Some "the doc") ];
      output = Sema.COText;
    }
  in
  Alcotest.(check (list string)) "instructions"
    [ "Search for relevant information";
      "Extract: facts";
      "Translate the result into: ja";
      "Classify the result";
      "Be concise";
      "Summarize: the doc" ]
    (Lower.lower checked).Ir.instructions

let suite =
  ( "lower",
    [ Alcotest.test_case "lower" `Quick test_lower;
      Alcotest.test_case "empty schema" `Quick test_lower_empty_schema;
      Alcotest.test_case "all verbs" `Quick test_all_verbs ] )
