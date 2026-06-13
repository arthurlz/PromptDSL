open Promptdsl

let sample_ir =
  {
    Ir.agent_name = "researcher";
    objective = "analyze TSLA";
    instructions = [ "Search for: TSLA earnings"; "Summarize the findings" ];
    out =
      Ir.OJson
        (Some
           [ { Ir.fname = "rating"; fty = Ir.SEnum [ "buy"; "hold"; "sell" ];
               required = true };
             { Ir.fname = "note"; fty = Ir.SString; required = false } ]);
  }

let contains s sub =
  let ls = String.length s and lsub = String.length sub in
  let rec go i =
    if i + lsub > ls then false
    else if String.sub s i lsub = sub then true
    else go (i + 1)
  in
  go 0

let test_prose () =
  let s = Backend_prose.render sample_ir in
  Alcotest.(check bool) "goal" true (contains s "Goal: analyze TSLA");
  Alcotest.(check bool) "step 1" true (contains s "1. Search for: TSLA earnings");
  Alcotest.(check bool) "step 2" true (contains s "2. Summarize the findings")

let test_openai () =
  let open Yojson.Safe.Util in
  let j = Backend_openai.render sample_ir in
  Alcotest.(check string) "model" "gpt-4o-mini"
    (j |> member "model" |> to_string);
  let rf = j |> member "response_format" in
  Alcotest.(check string) "rf type" "json_schema" (rf |> member "type" |> to_string);
  let required =
    rf |> member "json_schema" |> member "schema" |> member "required"
    |> to_list |> List.map to_string
  in
  Alcotest.(check (list string)) "required" [ "rating" ] required

let suite =
  ( "backends",
    [ Alcotest.test_case "prose" `Quick test_prose;
      Alcotest.test_case "openai" `Quick test_openai ] )
