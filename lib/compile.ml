let run_parser entry (src : string) =
  let lexbuf = Lexing.from_string src in
  lexbuf.Lexing.lex_curr_p <-
    { lexbuf.Lexing.lex_curr_p with Lexing.pos_lnum = 1; pos_fname = "" };
  try Ok (entry Lexer.token lexbuf) with
  | Lexer.Error (msg, loc) -> Error (Error.make loc msg)
  | Parser.Error ->
      let tok = Lexing.lexeme lexbuf in
      let msg =
        if tok = "" then "syntax error at end of input"
        else Printf.sprintf "syntax error near '%s'" tok
      in
      let loc =
        Location.of_positions (Lexing.lexeme_start_p lexbuf)
          (Lexing.lexeme_end_p lexbuf)
      in
      Error (Error.make loc msg)

let parse (src : string) : (Ast.agent_file, Error.t) result = run_parser Parser.program src
let parse_library (src : string) : (Ast.lib_item list, Error.t) result =
  run_parser Parser.library src

type outputs = { prose : string; json : Yojson.Safe.t }
type outcome = Success of outputs | Failure of Error.t list

let default_resolver (_ : string) : (string, string) result =
  Error "imports require a file context (compile a file, not a bare string)"

let frontend ?(resolver = default_resolver) (src : string) :
    (Sema.checked * Resolve.fragments, Error.t list) result =
  match parse src with
  | Error e -> Error [ e ]
  | Ok af -> (
      match Resolve.resolve ~parse_lib:parse_library ~resolver af.Ast.af_imports with
      | Error ds -> Error ds
      | Ok resolved -> (
          match Expand.expand resolved af.Ast.af_agent with
          | Error ds -> Error ds
          | Ok merged -> (
              match Sema.analyze ~fragments:resolved.Resolve.fragments merged with
              | Error ds -> Error ds
              | Ok checked -> Ok (checked, resolved.Resolve.fragments))))

let parse_and_check ?(resolver = default_resolver) (src : string) :
    (Sema.checked, Error.t list) result =
  Result.map fst (frontend ~resolver src)

let compile_string ?(values = []) ?(resolver = default_resolver) (src : string) : outcome =
  match frontend ~resolver src with
  | Error ds -> Failure ds
  | Ok (checked, fragments) -> (
      match Bind.bind ~fragments checked values with
      | Error ds -> Failure ds
      | Ok bound ->
          let ir = Lower.lower bound in
          Success { prose = Backend_prose.render ir; json = Backend_openai.render ir })
