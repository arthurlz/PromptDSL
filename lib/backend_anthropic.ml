open Ir

(* https://api.anthropic.com/v1/messages
   Headers (not part of this body): content-type: application/json,
   anthropic-version: 2023-06-01, x-api-key: $ANTHROPIC_API_KEY. *)

(* Structured output uses the current production output_config.format
   (no beta header); schema is standard lowercase JSON Schema, shared with OpenAI. *)
let output_config (fields : Ir.schema_field list) : Yojson.Safe.t =
  `Assoc
    [ ( "format",
        `Assoc
          [ ("type", `String "json_schema");
            ("schema", Backend_common.schema_object fields) ] ) ]

let render (ir : Ir.t) : Yojson.Safe.t =
  let base =
    [ ("model", `String "claude-haiku-4-5-20251001");
      ("max_tokens", `Int 1024);
      ("system", `String (Backend_prose.render ir));
      ( "messages",
        `List
          [ `Assoc
              [ ("role", `String "user");
                ("content", `String (Backend_common.user_message ir)) ] ] ) ]
  in
  let fields =
    match ir.out with
    | OJson (Some fields) -> base @ [ ("output_config", output_config fields) ]
    | OJson None | OText | OMarkdown -> base
  in
  `Assoc fields
