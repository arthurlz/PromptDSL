open Ir

(* POST https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=$GEMINI_API_KEY
   The model is in the URL, so it is NOT part of this body. *)

let default_model = "gemini-2.5-flash"

(* Gemini responseSchema uses UPPERCASE OpenAPI-style type names. *)
let rec gemini_of_ty = function
  | SString -> `Assoc [ ("type", `String "STRING") ]
  | SInt -> `Assoc [ ("type", `String "INTEGER") ]
  | SBool -> `Assoc [ ("type", `String "BOOLEAN") ]
  | SFloat -> `Assoc [ ("type", `String "NUMBER") ]
  | SEnum opts ->
      `Assoc
        [ ("type", `String "STRING");
          ("enum", `List (List.map (fun s -> `String s) opts)) ]
  | SList t -> `Assoc [ ("type", `String "ARRAY"); ("items", gemini_of_ty t) ]

(* No additionalProperties (Gemini's schema subset does not support it);
   minimum/maximum are the same as everywhere, so reuse Backend_common.with_range. *)
let gemini_schema_object (fields : Ir.schema_field list) : Yojson.Safe.t =
  let props =
    List.map
      (fun (f : Ir.schema_field) ->
        (f.fname, Backend_common.with_range f (gemini_of_ty f.fty)))
      fields
  in
  let required =
    List.filter_map
      (fun (f : Ir.schema_field) -> if f.required then Some (`String f.fname) else None)
      fields
  in
  `Assoc
    [ ("type", `String "OBJECT");
      ("properties", `Assoc props);
      ("required", `List required) ]

let render ?(no_content_user = "{{input}}") (ir : Ir.t) : Yojson.Safe.t =
  let base =
    [ ( "systemInstruction",
        `Assoc [ ("parts", `List [ `Assoc [ ("text", `String (Backend_prose.render ir)) ] ]) ] );
      ( "contents",
        `List
          [ `Assoc
              [ ("role", `String "user");
                ( "parts",
                  `List [ `Assoc [ ("text", `String (Backend_common.user_message ~no_content_user ir)) ] ] ) ] ] ) ]
  in
  let gen_config =
    match ir.out with
    | OJson (Some fields) ->
        Some
          (`Assoc
             [ ("responseMimeType", `String "application/json");
               ("responseSchema", gemini_schema_object fields) ])
    | OJson None -> Some (`Assoc [ ("responseMimeType", `String "application/json") ])
    | OText | OMarkdown -> None
  in
  let fields =
    match gen_config with Some g -> base @ [ ("generationConfig", g) ] | None -> base
  in
  `Assoc fields
