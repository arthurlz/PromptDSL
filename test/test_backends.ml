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
               required = true; range = None };
             { Ir.fname = "note"; fty = Ir.SString; required = false; range = None } ]);
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

let test_import_end_to_end () =
  let resolver = function
    | "fin.prompt" -> Ok {|def disclaimer = "Not advice."|}
    | _ -> Error "no such file"
  in
  let src =
    {|import "fin.prompt" as fin
      agent "a" { goal "Analyze. {{fin.disclaimer}}" }|}
  in
  match Compile.compile_string ~resolver src with
  | Compile.Failure ds ->
      Alcotest.failf "unexpected failure: %s"
        (String.concat "; " (List.map (fun (d : Error.t) -> d.Error.message) ds))
  | Compile.Success o ->
      Alcotest.(check bool) "fragment substituted" true
        (contains o.Compile.prose "Analyze. Not advice.")

let test_extends_end_to_end () =
  let resolver = function
    | "s.prompt" ->
        Ok {|template Rater {
               step { summarize }
               output json { rating: enum("buy","sell") why: string }
             }|}
    | _ -> Error "no such file"
  in
  let src =
    {|import "s.prompt" as s
      agent "a" extends s.Rater {
        input { topic: string }
        goal "Rate {{topic}}."
      }|}
  in
  match Compile.compile_string ~resolver ~values:[ ("topic", "TSLA") ] src with
  | Compile.Failure ds ->
      Alcotest.failf "unexpected failure: %s"
        (String.concat "; " (List.map (fun (d : Error.t) -> d.Error.message) ds))
  | Compile.Success o ->
      let open Yojson.Safe.Util in
      Alcotest.(check bool) "goal substituted" true (contains o.Compile.prose "Goal: Rate TSLA.");
      Alcotest.(check bool) "step inherited" true (contains o.Compile.prose "Summarize the findings");
      Alcotest.(check string) "output inherited" "json_schema"
        (o.Compile.json |> member "response_format" |> member "type" |> to_string)

let test_float_number () =
  let ir =
    { Ir.agent_name = "a"; objective = "g"; instructions = [];
      out = Ir.OJson (Some [ { Ir.fname = "p"; fty = Ir.SFloat; required = true; range = None } ]);
      content = None }
  in
  let open Yojson.Safe.Util in
  let t =
    Backend_openai.render ir |> member "response_format" |> member "json_schema"
    |> member "schema" |> member "properties" |> member "p" |> member "type" |> to_string
  in
  Alcotest.(check string) "float -> number" "number" t

let test_range_emitted () =
  let ir =
    { Ir.agent_name = "a"; objective = "g"; instructions = [];
      out = Ir.OJson (Some [
        { Ir.fname = "score"; fty = Ir.SInt; required = true; range = Some (0., 100.) };
        { Ir.fname = "ratio"; fty = Ir.SFloat; required = true; range = Some (0., 1.) } ]);
      content = None }
  in
  let open Yojson.Safe.Util in
  let props =
    Backend_openai.render ir |> member "response_format" |> member "json_schema"
    |> member "schema" |> member "properties"
  in
  Alcotest.(check int) "int min" 0 (props |> member "score" |> member "minimum" |> to_int);
  Alcotest.(check int) "int max" 100 (props |> member "score" |> member "maximum" |> to_int);
  Alcotest.(check (float 0.001)) "float max" 1.0 (props |> member "ratio" |> member "maximum" |> to_number);
  Alcotest.(check bool) "prose range" true
    (contains (Backend_prose.render ir) "score: int (0..100)")

(* Integral bounds render as plain integers in prose, not scientific notation. *)
let test_prose_large_int_range () =
  let ir =
    { Ir.agent_name = "a"; objective = "g"; instructions = [];
      out = Ir.OJson (Some [ { Ir.fname = "vol"; fty = Ir.SInt; required = true; range = Some (0., 1000000.) } ]);
      content = None }
  in
  Alcotest.(check bool) "plain int bound" true
    (contains (Backend_prose.render ir) "vol: int (0..1000000)")

let test_run_request_user () =
  (match
     Compile.compile_request ~values:[ ("body", "hi") ]
       {|agent "a" { input { body: string @content } goal "g" }|}
   with
   | Error _ -> Alcotest.fail "compile_request failed"
   | Ok j ->
       let open Yojson.Safe.Util in
       let u = j |> member "messages" |> to_list |> List.rev |> List.hd |> member "content" |> to_string in
       Alcotest.(check string) "content user" "hi" u);
  (match Compile.compile_request {|agent "a" { goal "g" }|} with
   | Error _ -> Alcotest.fail "compile_request failed"
   | Ok j ->
       let open Yojson.Safe.Util in
       let u = j |> member "messages" |> to_list |> List.rev |> List.hd |> member "content" |> to_string in
       Alcotest.(check string) "empty user (not placeholder)" "" u)

(* Backend_common.schema_object builds the lowercase JSON-Schema object shared
   by OpenAI and Anthropic. *)
let test_common_schema_object () =
  let open Yojson.Safe.Util in
  let fields =
    [ { Ir.fname = "rating"; fty = Ir.SEnum [ "buy"; "sell" ]; required = true; range = None };
      { Ir.fname = "note"; fty = Ir.SString; required = false; range = None } ]
  in
  let s = Backend_common.schema_object fields in
  Alcotest.(check string) "object type" "object" (s |> member "type" |> to_string);
  Alcotest.(check bool) "additionalProperties false" false
    (s |> member "additionalProperties" |> to_bool);
  Alcotest.(check (list string)) "required" [ "rating" ]
    (s |> member "required" |> to_list |> List.map to_string);
  Alcotest.(check string) "enum is lowercase string" "string"
    (s |> member "properties" |> member "rating" |> member "type" |> to_string)

(* Anthropic Messages body: top-level system, single user message, model +
   max_tokens, output_config.format only for a typed schema. *)
let test_anthropic () =
  let open Yojson.Safe.Util in
  let j = Backend_anthropic.render sample_ir in
  Alcotest.(check string) "model" "claude-haiku-4-5-20251001"
    (j |> member "model" |> to_string);
  Alcotest.(check int) "max_tokens" 1024 (j |> member "max_tokens" |> to_int);
  Alcotest.(check bool) "system is top-level" true (has_member j "system");
  let roles =
    j |> member "messages" |> to_list
    |> List.map (fun m -> m |> member "role" |> to_string)
  in
  Alcotest.(check (list string)) "only a user message" [ "user" ] roles;
  Alcotest.(check string) "format type" "json_schema"
    (j |> member "output_config" |> member "format" |> member "type" |> to_string);
  let schema = j |> member "output_config" |> member "format" |> member "schema" in
  Alcotest.(check bool) "additionalProperties present (shared builder)" true
    (has_member schema "additionalProperties");
  Alcotest.(check string) "enum is lowercase string" "string"
    (schema |> member "properties" |> member "rating" |> member "type" |> to_string)

let test_anthropic_gating () =
  Alcotest.(check bool) "text: no output_config" false
    (has_member (Backend_anthropic.render (ir_with Ir.OText)) "output_config");
  Alcotest.(check bool) "markdown: no output_config" false
    (has_member (Backend_anthropic.render (ir_with Ir.OMarkdown)) "output_config");
  Alcotest.(check bool) "bare json: no output_config" false
    (has_member (Backend_anthropic.render (ir_with (Ir.OJson None))) "output_config")

let test_anthropic_no_content () =
  let open Yojson.Safe.Util in
  let j = Backend_anthropic.render (ir_with Ir.OText) in
  let u =
    j |> member "messages" |> to_list |> List.hd |> member "content" |> to_string
  in
  Alcotest.(check string) "no-content user is placeholder" "{{input}}" u

(* Gemini generateContent body: systemInstruction/contents use parts[].text,
   responseSchema uses UPPERCASE types and has no additionalProperties, and the
   model is NOT in the body (it lives in the URL). *)
let test_gemini () =
  let open Yojson.Safe.Util in
  let j = Backend_gemini.render sample_ir in
  let sys =
    j |> member "systemInstruction" |> member "parts" |> to_list |> List.hd
    |> member "text" |> to_string
  in
  Alcotest.(check bool) "system carries the goal" true (contains sys "Goal: analyze TSLA");
  Alcotest.(check bool) "no model field in body" false (has_member j "model");
  let gc = j |> member "generationConfig" in
  Alcotest.(check string) "mime" "application/json"
    (gc |> member "responseMimeType" |> to_string);
  let schema = gc |> member "responseSchema" in
  Alcotest.(check string) "object UPPERCASE" "OBJECT" (schema |> member "type" |> to_string);
  Alcotest.(check string) "enum UPPERCASE STRING" "STRING"
    (schema |> member "properties" |> member "rating" |> member "type" |> to_string);
  Alcotest.(check bool) "no additionalProperties" false
    (has_member schema "additionalProperties")

let test_gemini_gating () =
  let open Yojson.Safe.Util in
  Alcotest.(check bool) "text: no generationConfig" false
    (has_member (Backend_gemini.render (ir_with Ir.OText)) "generationConfig");
  Alcotest.(check bool) "markdown: no generationConfig" false
    (has_member (Backend_gemini.render (ir_with Ir.OMarkdown)) "generationConfig");
  let gc = Backend_gemini.render (ir_with (Ir.OJson None)) |> member "generationConfig" in
  Alcotest.(check string) "bare json: mime only" "application/json"
    (gc |> member "responseMimeType" |> to_string);
  Alcotest.(check bool) "bare json: no responseSchema" false
    (has_member gc "responseSchema")

let test_gemini_range_and_list () =
  let open Yojson.Safe.Util in
  let ir =
    { Ir.agent_name = "a"; objective = "g"; instructions = [];
      out = Ir.OJson (Some [
        { Ir.fname = "score"; fty = Ir.SInt; required = true; range = Some (0., 100.) };
        { Ir.fname = "tags"; fty = Ir.SList Ir.SString; required = false; range = None } ]);
      content = None }
  in
  let props =
    Backend_gemini.render ir |> member "generationConfig" |> member "responseSchema"
    |> member "properties"
  in
  Alcotest.(check string) "int UPPERCASE" "INTEGER"
    (props |> member "score" |> member "type" |> to_string);
  Alcotest.(check int) "min" 0 (props |> member "score" |> member "minimum" |> to_int);
  Alcotest.(check int) "max" 100 (props |> member "score" |> member "maximum" |> to_int);
  Alcotest.(check string) "list UPPERCASE ARRAY" "ARRAY"
    (props |> member "tags" |> member "type" |> to_string);
  Alcotest.(check string) "items UPPERCASE STRING" "STRING"
    (props |> member "tags" |> member "items" |> member "type" |> to_string)

(* compile_string dispatches the JSON renderer by target; prose is unchanged. *)
let test_compile_string_target () =
  let open Yojson.Safe.Util in
  let src = {|agent "r" { goal "g" output json { x: string } }|} in
  let model outcome =
    match outcome with
    | Compile.Failure _ -> Alcotest.fail "unexpected failure"
    | Compile.Success o -> o.Compile.json
  in
  let oa = model (Compile.compile_string ~target:`OpenAI src) in
  Alcotest.(check string) "openai model" "gpt-4o-mini" (oa |> member "model" |> to_string);
  let an = model (Compile.compile_string ~target:`Anthropic src) in
  Alcotest.(check string) "anthropic model" "claude-haiku-4-5-20251001"
    (an |> member "model" |> to_string);
  let ge = model (Compile.compile_string ~target:`Gemini src) in
  Alcotest.(check bool) "gemini has contents" true (has_member ge "contents");
  let def = model (Compile.compile_string src) in
  Alcotest.(check string) "default model" "gpt-4o-mini" (def |> member "model" |> to_string)

(* compile_request builds each provider's body with the run-time user message
   (bound @content, or "" when none — never the {{input}} placeholder). *)
let test_compile_request_targets () =
  let open Yojson.Safe.Util in
  (match
     Compile.compile_request ~target:`Anthropic ~values:[ ("body", "hi") ]
       {|agent "a" { input { body: string @content } goal "g" }|}
   with
   | Error _ -> Alcotest.fail "anthropic compile_request failed"
   | Ok j ->
       Alcotest.(check string) "anthropic model" "claude-haiku-4-5-20251001"
         (j |> member "model" |> to_string);
       let u = j |> member "messages" |> to_list |> List.hd |> member "content" |> to_string in
       Alcotest.(check string) "anthropic content user" "hi" u);
  (match Compile.compile_request ~target:`Anthropic {|agent "a" { goal "g" }|} with
   | Error _ -> Alcotest.fail "anthropic compile_request failed"
   | Ok j ->
       let u = j |> member "messages" |> to_list |> List.hd |> member "content" |> to_string in
       Alcotest.(check string) "anthropic empty user (not placeholder)" "" u);
  (match
     Compile.compile_request ~target:`Gemini ~values:[ ("body", "hey") ]
       {|agent "a" { input { body: string @content } goal "g" }|}
   with
   | Error _ -> Alcotest.fail "gemini compile_request failed"
   | Ok j ->
       let t =
         j |> member "contents" |> to_list |> List.hd |> member "parts" |> to_list
         |> List.hd |> member "text" |> to_string
       in
       Alcotest.(check string) "gemini content text" "hey" t)

(* --model overrides the body model for OpenAI/Anthropic; Gemini exposes the
   default as a constant (its body carries no model). *)
let test_model_override () =
  let open Yojson.Safe.Util in
  let ir = ir_with Ir.OText in
  Alcotest.(check string) "openai default" "gpt-4o-mini"
    (Backend_openai.render ir |> member "model" |> to_string);
  Alcotest.(check string) "openai override" "gpt-4o"
    (Backend_openai.render ~model:"gpt-4o" ir |> member "model" |> to_string);
  Alcotest.(check string) "anthropic default" "claude-haiku-4-5-20251001"
    (Backend_anthropic.render ir |> member "model" |> to_string);
  Alcotest.(check string) "anthropic override" "claude-opus-4-8"
    (Backend_anthropic.render ~model:"claude-opus-4-8" ir |> member "model" |> to_string);
  Alcotest.(check string) "gemini default_model const" "gemini-2.5-flash"
    Backend_gemini.default_model

(* compile_string / compile_request forward ?model to the OpenAI/Anthropic renderers. *)
let test_compile_model () =
  let open Yojson.Safe.Util in
  (match Compile.compile_request ~model:"gpt-4o" {|agent "a" { goal "g" }|} with
   | Error _ -> Alcotest.fail "compile_request failed"
   | Ok j -> Alcotest.(check string) "req override" "gpt-4o" (j |> member "model" |> to_string));
  (match Compile.compile_request {|agent "a" { goal "g" }|} with
   | Error _ -> Alcotest.fail "compile_request failed"
   | Ok j -> Alcotest.(check string) "req default" "gpt-4o-mini" (j |> member "model" |> to_string));
  match
    Compile.compile_string ~target:`Anthropic ~model:"claude-opus-4-8"
      {|agent "a" { goal "g" }|}
  with
  | Compile.Failure _ -> Alcotest.fail "compile_string failed"
  | Compile.Success o ->
      Alcotest.(check string) "str override" "claude-opus-4-8"
        (o.Compile.json |> member "model" |> to_string)

let suite =
  ( "backends",
    [ Alcotest.test_case "prose" `Quick test_prose;
      Alcotest.test_case "openai" `Quick test_openai;
      Alcotest.test_case "response_format gating" `Quick test_response_format_gating;
      Alcotest.test_case "prose output lines" `Quick test_prose_output_lines;
      Alcotest.test_case "content to user message" `Quick test_content_to_user_message;
      Alcotest.test_case "no input legacy user message" `Quick test_no_input_legacy_user_message;
      Alcotest.test_case "import end-to-end" `Quick test_import_end_to_end;
      Alcotest.test_case "extends end-to-end" `Quick test_extends_end_to_end;
      Alcotest.test_case "float number" `Quick test_float_number;
      Alcotest.test_case "range emitted" `Quick test_range_emitted;
      Alcotest.test_case "prose large int range" `Quick test_prose_large_int_range;
      Alcotest.test_case "run request user" `Quick test_run_request_user;
      Alcotest.test_case "common schema_object" `Quick test_common_schema_object;
      Alcotest.test_case "anthropic" `Quick test_anthropic;
      Alcotest.test_case "anthropic gating" `Quick test_anthropic_gating;
      Alcotest.test_case "anthropic no content" `Quick test_anthropic_no_content;
      Alcotest.test_case "gemini" `Quick test_gemini;
      Alcotest.test_case "gemini gating" `Quick test_gemini_gating;
      Alcotest.test_case "gemini range and list" `Quick test_gemini_range_and_list;
      Alcotest.test_case "compile_string target" `Quick test_compile_string_target;
      Alcotest.test_case "compile_request targets" `Quick test_compile_request_targets;
      Alcotest.test_case "model override" `Quick test_model_override;
      Alcotest.test_case "compile model" `Quick test_compile_model ] )
