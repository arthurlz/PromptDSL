let endpoint = "https://api.openai.com/v1/chat/completions"

type transport = string -> (string, string) result

(* Turn an OpenAI response into the text to print, or an error. Pure. *)
let format_response (resp : Yojson.Safe.t) : (string, string) result =
  let open Yojson.Safe.Util in
  match member "error" resp with
  | `Null -> (
      match member "choices" resp with
      | `List (c :: _) -> (
          match c |> member "message" |> member "content" with
          | `String content -> (
              match Yojson.Safe.from_string content with
              | exception _ -> Ok content
              | j -> Ok (Yojson.Safe.pretty_to_string j))
          | _ -> Error "unexpected response shape (no message content)")
      | _ -> Error "unexpected response shape (no choices)")
  | err -> (
      match member "message" err with
      | `String m -> Error m
      | _ -> Error "API error")

let execute ~(transport : transport) (request : Yojson.Safe.t) : (string, string) result =
  match transport (Yojson.Safe.to_string request) with
  | Error e -> Error e
  | Ok raw -> (
      match Yojson.Safe.from_string raw with
      | exception _ -> Error "invalid JSON response from API"
      | resp -> format_response resp)

(* Shell out to curl. The only piece not exercised by unit tests. *)
let curl_transport ~(api_key : string) : transport =
 fun body ->
  let tmp = Filename.temp_file "promptc" ".json" in
  Fun.protect
    ~finally:(fun () -> try Sys.remove tmp with _ -> ())
    (fun () ->
      let oc = open_out tmp in
      output_string oc body;
      close_out oc;
      let cmd =
        Printf.sprintf "curl -sS -X POST %s -H %s -H %s -d @%s"
          (Filename.quote endpoint)
          (Filename.quote ("Authorization: Bearer " ^ api_key))
          (Filename.quote "Content-Type: application/json")
          (Filename.quote tmp)
      in
      let ic = Unix.open_process_in cmd in
      let out = In_channel.input_all ic in
      match Unix.close_process_in ic with
      | Unix.WEXITED 0 -> Ok out
      | _ -> Error (if out = "" then "curl request failed" else out))
