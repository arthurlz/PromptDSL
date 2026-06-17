type transport = string -> (string, string) result

type provider = {
  env_var : string;
  endpoint : string -> string;                          (* api_key -> URL *)
  headers : string -> (string * string) list;            (* api_key -> extra headers *)
  extract : Yojson.Safe.t -> (string, string) result;    (* response JSON -> reply text | error *)
}

(* Shared error branch: every provider exposes the human message at error.message. *)
let error_message (err : Yojson.Safe.t) : string =
  match Yojson.Safe.Util.member "message" err with
  | `String m -> m
  | _ -> "API error"

(* OpenAI: choices[0].message.content *)
let openai_extract (resp : Yojson.Safe.t) : (string, string) result =
  let open Yojson.Safe.Util in
  match member "error" resp with
  | `Null -> (
      match member "choices" resp with
      | `List (c :: _) -> (
          match c |> member "message" |> member "content" with
          | `String content -> Ok content
          | _ -> Error "unexpected response shape (no message content)")
      | _ -> Error "unexpected response shape (no choices)")
  | err -> Error (error_message err)

(* Anthropic: first content[] block whose type is "text" -> its text *)
let anthropic_extract (resp : Yojson.Safe.t) : (string, string) result =
  let open Yojson.Safe.Util in
  match member "error" resp with
  | `Null -> (
      match member "content" resp with
      | `List blocks -> (
          match
            List.find_opt (fun b -> member "type" b = `String "text") blocks
          with
          | Some b -> (
              match member "text" b with
              | `String t -> Ok t
              | _ -> Error "unexpected response shape (no text)")
          | None -> Error "unexpected response shape (no text block)")
      | _ -> Error "unexpected response shape (no content)")
  | err -> Error (error_message err)

(* Gemini: candidates[0].content.parts[0].text *)
let gemini_extract (resp : Yojson.Safe.t) : (string, string) result =
  let open Yojson.Safe.Util in
  match member "error" resp with
  | `Null -> (
      match member "candidates" resp with
      | `List (c :: _) -> (
          match c |> member "content" |> member "parts" with
          | `List (p :: _) -> (
              match member "text" p with
              | `String t -> Ok t
              | _ -> Error "unexpected response shape (no text)")
          | _ -> Error "unexpected response shape (no parts)")
      | _ -> Error "unexpected response shape (no candidates)")
  | err -> Error (error_message err)

let openai : provider =
  { env_var = "OPENAI_API_KEY";
    endpoint = (fun _ -> "https://api.openai.com/v1/chat/completions");
    headers = (fun k -> [ ("Authorization", "Bearer " ^ k) ]);
    extract = openai_extract }

let anthropic : provider =
  { env_var = "ANTHROPIC_API_KEY";
    endpoint = (fun _ -> "https://api.anthropic.com/v1/messages");
    headers = (fun k -> [ ("x-api-key", k); ("anthropic-version", "2023-06-01") ]);
    extract = anthropic_extract }

let gemini : provider =
  { env_var = "GEMINI_API_KEY";
    endpoint =
      (fun k ->
        "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key="
        ^ k);
    headers = (fun _ -> []);
    extract = gemini_extract }

(* If the reply parses as JSON, pretty-print it; otherwise return it unchanged. *)
let pretty_if_json (content : string) : string =
  match Yojson.Safe.from_string content with
  | exception _ -> content
  | j -> Yojson.Safe.pretty_to_string j

let execute ~(provider : provider) ~(transport : transport) (request : Yojson.Safe.t) :
    (string, string) result =
  match transport (Yojson.Safe.to_string request) with
  | Error e -> Error e
  | Ok raw -> (
      match Yojson.Safe.from_string raw with
      | exception _ -> Error "invalid JSON response from API"
      | resp -> Result.map pretty_if_json (provider.extract resp))

(* Shell out to curl. The only piece not exercised by unit tests. *)
let curl_transport ~(provider : provider) ~(api_key : string) : transport =
 fun body ->
  let tmp = Filename.temp_file "promptc" ".json" in
  Fun.protect
    ~finally:(fun () -> try Sys.remove tmp with _ -> ())
    (fun () ->
      let oc = open_out tmp in
      output_string oc body;
      close_out oc;
      let header_args =
        List.concat_map
          (fun (k, v) -> [ "-H"; Filename.quote (k ^ ": " ^ v) ])
          (("Content-Type", "application/json") :: provider.headers api_key)
      in
      let cmd =
        String.concat " "
          ([ "curl"; "-sS"; "-X"; "POST"; Filename.quote (provider.endpoint api_key) ]
          @ header_args
          @ [ "-d"; Filename.quote ("@" ^ tmp) ])
      in
      let ic = Unix.open_process_in cmd in
      let out = In_channel.input_all ic in
      match Unix.close_process_in ic with
      | Unix.WEXITED 0 -> Ok out
      | _ -> Error (if out = "" then "curl request failed" else out))
