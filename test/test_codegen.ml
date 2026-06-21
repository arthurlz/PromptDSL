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

let test_validator () =
  let fields =
    [ { Ir.fname = "rating"; fty = Ir.SEnum [ "buy"; "sell" ]; required = true; range = None };
      { Ir.fname = "score"; fty = Ir.SInt; required = true; range = Some (0., 100.) };
      { Ir.fname = "note"; fty = Ir.SString; required = false; range = None } ]
  in
  let v = Codegen_ts.gen_validator "FooOutput" fields in
  Alcotest.(check bool) "fn header" true (contains v "function validateFooOutput(x: any): FooOutput");
  Alcotest.(check bool) "enum check" true (contains v {|["buy", "sell"].includes|});
  Alcotest.(check bool) "range check" true (contains v "x[\"score\"] < 0 || x[\"score\"] > 100");
  Alcotest.(check bool) "optional guard" true (contains v {|x["note"] !== undefined|});
  Alcotest.(check string) "object type"
    "{ rating: \"buy\" | \"sell\"; score: number; note?: string }"
    (Codegen_ts.ts_output_type (Ir.OJson (Some fields)));
  Alcotest.(check string) "text type" "string" (Codegen_ts.ts_output_type Ir.OText);
  Alcotest.(check string) "bare json type" "unknown" (Codegen_ts.ts_output_type (Ir.OJson None))

let gen src target =
  match Compile.frontend src with
  | Error _ -> Alcotest.fail "frontend failed"
  | Ok (checked, fragments) -> Codegen_ts.generate checked fragments ~target ~model:None

let test_generate_openai () =
  let src =
    {|agent "researcher" { input { ticker: string } goal "analyze {{ticker}}"
       output json { rating: enum("buy","sell") } }|}
  in
  let ts = gen src `OpenAI in
  Alcotest.(check bool) "inputs type" true (contains ts "export type ResearcherInputs");
  Alcotest.(check bool) "output type" true (contains ts "export type ResearcherOutput");
  Alcotest.(check bool) "fn signature" true
    (contains ts "export async function researcher(inputs: ResearcherInputs");
  Alcotest.(check bool) "validator called" true (contains ts "validateResearcherOutput(");
  Alcotest.(check bool) "openai endpoint" true (contains ts "api.openai.com/v1/chat/completions");
  Alcotest.(check bool) "openai auth" true (contains ts "Authorization");
  Alcotest.(check bool) "interpolates input" true (contains ts "${inputs.ticker}")

let test_generate_text_and_providers () =
  let text_ts = gen {|agent "a" { goal "g" output markdown }|} `OpenAI in
  Alcotest.(check bool) "text returns named alias" true (contains text_ts "Promise<AOutput>");
  Alcotest.(check bool) "text no validator" false (contains text_ts "function validate");
  let anth = gen {|agent "a" { goal "g" }|} `Anthropic in
  Alcotest.(check bool) "anthropic header" true (contains anth "x-api-key");
  Alcotest.(check bool) "anthropic version" true (contains anth "anthropic-version");
  let gem = gen {|agent "a" { goal "g" }|} `Gemini in
  Alcotest.(check bool) "gemini model in url" true (contains gem "models/gemini-2.5-flash:generateContent")

let suite =
  ( "codegen",
    [ Alcotest.test_case "ts type mapping" `Quick test_ts_type_mapping;
      Alcotest.test_case "identifiers" `Quick test_identifiers;
      Alcotest.test_case "template ir holes" `Quick test_template_ir_holes;
      Alcotest.test_case "body emitter" `Quick test_body_emitter;
      Alcotest.test_case "validator" `Quick test_validator;
      Alcotest.test_case "generate openai" `Quick test_generate_openai;
      Alcotest.test_case "generate text+providers" `Quick test_generate_text_and_providers ] )
