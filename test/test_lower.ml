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

let suite = ("lower", [ Alcotest.test_case "lower" `Quick test_lower ])
