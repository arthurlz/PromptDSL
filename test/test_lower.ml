open Promptdsl

let test_lower () =
  let bound =
    {
      Bind.b_name = "researcher";
      b_goal = "analyze TSLA";
      b_steps =
        [ { Sema.verb = "search"; arg = Some "TSLA earnings" };
          { Sema.verb = "summarize"; arg = None } ];
      b_output =
        Sema.COJson
          (Some
             [ { Ast.field_name = "ticker"; field_ty = Ast.TString;
                 optional = false; field_loc = Location.dummy; field_range = None } ]);
      b_content = None;
    }
  in
  let ir = Lower.lower bound in
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
  let bound =
    { Bind.b_name = "a"; b_goal = "g"; b_steps = []; b_output = Sema.COJson (Some []); b_content = None }
  in
  match (Lower.lower bound).Ir.out with
  | Ir.OJson None -> ()
  | _ -> Alcotest.fail "empty schema should lower to OJson None"

(* Every action verb renders to its expected instruction, with and without
   an argument. *)
let test_all_verbs () =
  let step verb arg = { Sema.verb; arg } in
  let bound =
    {
      Bind.b_name = "a";
      b_goal = "g";
      b_steps =
        [ step "search" None;
          step "extract" (Some "facts");
          step "translate" (Some "ja");
          step "classify" None;
          step "instruct" (Some "Be concise");
          step "summarize" (Some "the doc") ];
      b_output = Sema.COText;
      b_content = None;
    }
  in
  Alcotest.(check (list string)) "instructions"
    [ "Search for relevant information";
      "Extract: facts";
      "Translate the result into: ja";
      "Classify the result";
      "Be concise";
      "Summarize: the doc" ]
    (Lower.lower bound).Ir.instructions

let suite =
  ( "lower",
    [ Alcotest.test_case "lower" `Quick test_lower;
      Alcotest.test_case "empty schema" `Quick test_lower_empty_schema;
      Alcotest.test_case "all verbs" `Quick test_all_verbs ] )
