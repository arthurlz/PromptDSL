let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in ic)
    (fun () -> really_input_string ic (in_channel_length ic))

let print_diags filename ds =
  List.iter (fun d -> prerr_endline (Error.to_string ~filename d)) ds

let fs_resolver base_dir path : (string, string) result =
  if not (Filename.is_relative path) then
    Error "import paths must be relative to the agent file"
  else
    match read_file (Filename.concat base_dir path) with
    | s -> Ok s
    | exception Sys_error msg -> Error msg

let run_check (file : string) : int =
  match read_file file with
  | exception Sys_error msg ->
      prerr_endline msg;
      2
  | src -> (
      let resolver = fs_resolver (Filename.dirname file) in
      match Compile.parse_and_check ~resolver src with
      | Ok _ ->
          print_endline "OK";
          0
      | Error ds ->
          print_diags file ds;
          1)

let parse_set (s : string) : ((string * string), string) result =
  match String.index_opt s '=' with
  | Some i -> Ok (String.sub s 0 i, String.sub s (i + 1) (String.length s - i - 1))
  | None -> Error (Printf.sprintf "invalid --set %S (expected KEY=VALUE)" s)

let run_run (file : string) (sets : string list) : int =
  match Sys.getenv_opt "OPENAI_API_KEY" with
  | None | Some "" ->
      prerr_endline "OPENAI_API_KEY is not set";
      2
  | Some api_key -> (
      let rec parse acc = function
        | [] -> Ok (List.rev acc)
        | s :: rest -> (
            match parse_set s with Ok kv -> parse (kv :: acc) rest | Error m -> Error m)
      in
      match parse [] sets with
      | Error m -> prerr_endline m; 2
      | Ok values -> (
          match read_file file with
          | exception Sys_error msg -> prerr_endline msg; 2
          | src -> (
              let resolver = fs_resolver (Filename.dirname file) in
              match Compile.compile_request ~values ~resolver src with
              | Error ds -> print_diags file ds; 1
              | Ok request -> (
                  match
                    Runtime.execute ~transport:(Runtime.curl_transport ~api_key) request
                  with
                  | Ok out -> print_string out; print_newline (); 0
                  | Error m -> prerr_endline m; 1))))

let run_compile (file : string) (emit : [ `Prose | `Json | `Both ]) (sets : string list)
    (target : [ `OpenAI | `Anthropic | `Gemini ]) : int =
  let rec parse acc = function
    | [] -> Ok (List.rev acc)
    | s :: rest -> (
        match parse_set s with Ok kv -> parse (kv :: acc) rest | Error m -> Error m)
  in
  match parse [] sets with
  | Error m -> prerr_endline m; 2
  | Ok values -> (
      match read_file file with
      | exception Sys_error msg -> prerr_endline msg; 2
      | src -> (
          let resolver = fs_resolver (Filename.dirname file) in
          match Compile.compile_string ~values ~resolver ~target src with
          | Compile.Failure ds -> print_diags file ds; 1
          | Compile.Success o ->
              (match emit with
               | `Prose -> print_string o.Compile.prose
               | `Json -> print_endline (Yojson.Safe.pretty_to_string o.Compile.json)
               | `Both ->
                   print_endline "=== PROSE ===";
                   print_string o.Compile.prose;
                   print_endline "=== JSON ===";
                   print_endline (Yojson.Safe.pretty_to_string o.Compile.json));
              0))
