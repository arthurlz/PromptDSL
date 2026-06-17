open Ir

let response_format (fields : Ir.schema_field list) : Yojson.Safe.t =
  `Assoc
    [ ("type", `String "json_schema");
      ( "json_schema",
        `Assoc
          [ ("name", `String "output");
            ("schema", Backend_common.schema_object fields) ] ) ]

let default_model = "gpt-4o-mini"

let render ?(no_content_user = "{{input}}") ?(model = default_model) (ir : Ir.t) : Yojson.Safe.t =
  let base =
    [ ("model", `String model);
      ( "messages",
        `List
          [ `Assoc
              [ ("role", `String "system");
                ("content", `String (Backend_prose.render ir)) ];
            `Assoc
              [ ("role", `String "user");
                ("content", `String (Backend_common.user_message ~no_content_user ir)) ] ] ) ]
  in
  let fields =
    match ir.out with
    | OJson (Some fields) -> base @ [ ("response_format", response_format fields) ]
    | OJson None ->
        base @ [ ("response_format", `Assoc [ ("type", `String "json_object") ]) ]
    | OText | OMarkdown -> base
  in
  `Assoc fields
