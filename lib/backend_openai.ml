open Ir

let rec json_of_ty = function
  | SString -> `Assoc [ ("type", `String "string") ]
  | SInt -> `Assoc [ ("type", `String "integer") ]
  | SBool -> `Assoc [ ("type", `String "boolean") ]
  | SEnum opts ->
      `Assoc
        [ ("type", `String "string");
          ("enum", `List (List.map (fun s -> `String s) opts)) ]
  | SList t -> `Assoc [ ("type", `String "array"); ("items", json_of_ty t) ]

let response_format fields =
  let props = List.map (fun f -> (f.fname, json_of_ty f.fty)) fields in
  let required =
    List.filter_map
      (fun f -> if f.required then Some (`String f.fname) else None)
      fields
  in
  `Assoc
    [ ("type", `String "json_schema");
      ( "json_schema",
        `Assoc
          [ ("name", `String "output");
            ( "schema",
              `Assoc
                [ ("type", `String "object");
                  ("properties", `Assoc props);
                  ("required", `List required);
                  ("additionalProperties", `Bool false) ] ) ] ) ]

let user_message (ir : Ir.t) : string =
  match ir.content with None -> "{{input}}" | Some s -> s

let render (ir : Ir.t) : Yojson.Safe.t =
  let base =
    [ ("model", `String "gpt-4o-mini");
      ( "messages",
        `List
          [ `Assoc
              [ ("role", `String "system");
                ("content", `String (Backend_prose.render ir)) ];
            `Assoc
              [ ("role", `String "user"); ("content", `String (user_message ir)) ] ] ) ]
  in
  let fields =
    match ir.out with
    | OJson (Some fields) -> base @ [ ("response_format", response_format fields) ]
    | OJson None ->
        base @ [ ("response_format", `Assoc [ ("type", `String "json_object") ]) ]
    | OText | OMarkdown -> base
  in
  `Assoc fields
