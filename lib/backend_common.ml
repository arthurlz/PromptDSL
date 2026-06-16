open Ir

(* The user message / first content part: the agent's bound @content, or the
   placeholder for an agent with no input. Shared by every backend. *)
let user_message ?(no_content_user = "{{input}}") (ir : Ir.t) : string =
  match ir.content with None -> no_content_user | Some s -> s

(* Standard (lowercase) JSON Schema type for a field type. *)
let rec json_of_ty = function
  | SString -> `Assoc [ ("type", `String "string") ]
  | SInt -> `Assoc [ ("type", `String "integer") ]
  | SBool -> `Assoc [ ("type", `String "boolean") ]
  | SFloat -> `Assoc [ ("type", `String "number") ]
  | SEnum opts ->
      `Assoc
        [ ("type", `String "string");
          ("enum", `List (List.map (fun s -> `String s) opts)) ]
  | SList t -> `Assoc [ ("type", `String "array"); ("items", json_of_ty t) ]

(* Append minimum/maximum to a property when the field has a range. Integer
   bounds are emitted as JSON integers, others as numbers. Provider-neutral:
   reused verbatim by the Gemini backend. *)
let with_range (f : Ir.schema_field) (base : Yojson.Safe.t) : Yojson.Safe.t =
  match (f.range, base) with
  | None, _ -> base
  | Some (lo, hi), `Assoc kvs ->
      let num v = match f.fty with Ir.SInt -> `Int (int_of_float v) | _ -> `Float v in
      `Assoc (kvs @ [ ("minimum", num lo); ("maximum", num hi) ])
  | Some _, j -> j

(* The {type:object, properties, required, additionalProperties:false} object,
   shared by OpenAI's response_format and Anthropic's output_config.format. *)
let schema_object (fields : Ir.schema_field list) : Yojson.Safe.t =
  let props =
    List.map (fun (f : Ir.schema_field) -> (f.fname, with_range f (json_of_ty f.fty))) fields
  in
  let required =
    List.filter_map
      (fun (f : Ir.schema_field) -> if f.required then Some (`String f.fname) else None)
      fields
  in
  `Assoc
    [ ("type", `String "object");
      ("properties", `Assoc props);
      ("required", `List required);
      ("additionalProperties", `Bool false) ]
