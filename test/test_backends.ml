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
    content = None;
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

let ir_with out =
  { Ir.agent_name = "a"; objective = "g"; instructions = []; out; content = None }

let has_member j k =
  match j with `Assoc l -> List.mem_assoc k l | _ -> false

(* response_format is present only for json output: absent for text/markdown,
   json_object for bare json, json_schema for a typed schema. *)
let test_response_format_gating () =
  Alcotest.(check bool) "text: no response_format" false
    (has_member (Backend_openai.render (ir_with Ir.OText)) "response_format");
  Alcotest.(check bool) "markdown: no response_format" false
    (has_member (Backend_openai.render (ir_with Ir.OMarkdown)) "response_format");
  let open Yojson.Safe.Util in
  let j = Backend_openai.render (ir_with (Ir.OJson None)) in
  Alcotest.(check string) "bare json -> json_object" "json_object"
    (j |> member "response_format" |> member "type" |> to_string)

let test_prose_output_lines () =
  Alcotest.(check bool) "markdown note" true
    (contains (Backend_prose.render (ir_with Ir.OMarkdown))
       "Format your answer as Markdown.");
  Alcotest.(check bool) "text: no format note" false
    (contains (Backend_prose.render (ir_with Ir.OText)) "Format your answer")

let test_content_to_user_message () =
  match Compile.compile_string ~values:[ ("body", "review this") ]
          {|agent "r" { input { body: string @content } goal "Review the input." }|}
  with
  | Compile.Failure _ -> Alcotest.fail "unexpected failure"
  | Compile.Success o ->
      let open Yojson.Safe.Util in
      let user =
        o.Compile.json |> member "messages" |> to_list |> List.rev |> List.hd
        |> member "content" |> to_string
      in
      Alcotest.(check string) "user message is content" "review this" user

let test_no_input_legacy_user_message () =
  match Compile.compile_string {|agent "r" { goal "g" }|} with
  | Compile.Failure _ -> Alcotest.fail "unexpected failure"
  | Compile.Success o ->
      let open Yojson.Safe.Util in
      let user =
        o.Compile.json |> member "messages" |> to_list |> List.rev |> List.hd
        |> member "content" |> to_string
      in
      Alcotest.(check string) "legacy {{input}}" "{{input}}" user

let suite =
  ( "backends",
    [ Alcotest.test_case "prose" `Quick test_prose;
      Alcotest.test_case "openai" `Quick test_openai;
      Alcotest.test_case "response_format gating" `Quick test_response_format_gating;
      Alcotest.test_case "prose output lines" `Quick test_prose_output_lines;
      Alcotest.test_case "content to user message" `Quick test_content_to_user_message;
      Alcotest.test_case "no input legacy user message" `Quick test_no_input_legacy_user_message ] )
