open Promptdsl

let contains s sub =
  let ls = String.length s and lsub = String.length sub in
  let rec go i =
    if i + lsub > ls then false
    else if String.sub s i lsub = sub then true
    else go (i + 1)
  in
  go 0

let test_ts_type_mapping () =
  Alcotest.(check string) "enum union" {|"buy" | "sell"|}
    (Codegen_ts.ts_of_schema_ty (Ir.SEnum [ "buy"; "sell" ]));
  Alcotest.(check string) "list" "string[]"
    (Codegen_ts.ts_of_schema_ty (Ir.SList Ir.SString));
  Alcotest.(check string) "int -> number" "number"
    (Codegen_ts.ts_of_schema_ty Ir.SInt);
  Alcotest.(check string) "ast enum" {|"a" | "b"|}
    (Codegen_ts.ts_of_ast_ty (Ast.TEnum [ "a"; "b" ]))

let test_identifiers () =
  Alcotest.(check string) "pascal" "EarningsAnalyst" (Codegen_ts.pascal "earnings-analyst");
  Alcotest.(check string) "camel" "earningsAnalyst" (Codegen_ts.camel "earnings analyst")

let test_template_ir_holes () =
  match
    Compile.frontend {|agent "r" { input { ticker: string } goal "analyze {{ticker}}" }|}
  with
  | Error _ -> Alcotest.fail "frontend failed"
  | Ok (checked, fragments) ->
      let ir = Codegen_ts.template_ir checked fragments in
      Alcotest.(check bool) "hole preserved in objective" true
        (contains ir.Ir.objective "{{ticker}}")

let test_body_emitter () =
  Alcotest.(check string) "plain string" {|"hi"|} (Codegen_ts.yojson_to_ts (`String "hi"));
  let t = Codegen_ts.yojson_to_ts (`String "analyze {{ticker}} now") in
  Alcotest.(check bool) "is template literal" true (contains t "${inputs.ticker}");
  Alcotest.(check bool) "is backticked" true (String.length t > 0 && t.[0] = '`');
  let o = Codegen_ts.yojson_to_ts (`Assoc [ ("a", `Int 1); ("b", `List [ `Bool true ]) ]) in
  Alcotest.(check bool) "object keys quoted" true (contains o {|"a": 1|});
  Alcotest.(check bool) "array" true (contains o "[true]")

let suite =
  ( "codegen",
    [ Alcotest.test_case "ts type mapping" `Quick test_ts_type_mapping;
      Alcotest.test_case "identifiers" `Quick test_identifiers;
      Alcotest.test_case "template ir holes" `Quick test_template_ir_holes;
      Alcotest.test_case "body emitter" `Quick test_body_emitter ] )
