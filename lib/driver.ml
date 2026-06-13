let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in ic)
    (fun () -> really_input_string ic (in_channel_length ic))

let print_diags filename ds =
  List.iter (fun d -> prerr_endline (Error.to_string ~filename d)) ds

let run_check (file : string) : int =
  match read_file file with
  | exception Sys_error msg ->
      prerr_endline msg;
      2
  | src -> (
      match Compile.parse_and_check src with
      | Ok _ ->
          print_endline "OK";
          0
      | Error ds ->
          print_diags file ds;
          1)

let run_compile (file : string) (emit : [ `Prose | `Json | `Both ]) : int =
  match read_file file with
  | exception Sys_error msg ->
      prerr_endline msg;
      2
  | src -> (
      match Compile.compile_string src with
      | Compile.Failure ds ->
          print_diags file ds;
          1
      | Compile.Success o ->
          (match emit with
           | `Prose -> print_string o.Compile.prose
           | `Json -> print_endline (Yojson.Safe.pretty_to_string o.Compile.json)
           | `Both ->
               print_endline "=== PROSE ===";
               print_string o.Compile.prose;
               print_endline "=== JSON ===";
               print_endline (Yojson.Safe.pretty_to_string o.Compile.json));
          0)
