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
let parse_library (src : string) : (Ast.def_decl list, Error.t) result =
  run_parser Parser.library src

let parse_and_check (src : string) : (Sema.checked, Error.t list) result =
  match parse src with
  | Error e -> Error [ e ]
  | Ok af -> Sema.analyze af.Ast.af_agent

type outputs = { prose : string; json : Yojson.Safe.t }
type outcome = Success of outputs | Failure of Error.t list

let compile_string ?(values = []) (src : string) : outcome =
  match parse_and_check src with
  | Error ds -> Failure ds
  | Ok checked -> (
      match Bind.bind checked values with
      | Error ds -> Failure ds
      | Ok bound ->
          let ir = Lower.lower bound in
          Success { prose = Backend_prose.render ir; json = Backend_openai.render ir })
