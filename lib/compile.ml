let parse (src : string) : (Ast.agent_block, Error.t) result =
  let lexbuf = Lexing.from_string src in
  lexbuf.Lexing.lex_curr_p <-
    { lexbuf.Lexing.lex_curr_p with Lexing.pos_lnum = 1; pos_fname = "" };
  try Ok (Parser.program Lexer.token lexbuf) with
  | Lexer.Error (msg, loc) -> Error (Error.make loc msg)
  | Parser.Error ->
      let loc =
        Location.of_positions (Lexing.lexeme_start_p lexbuf)
          (Lexing.lexeme_end_p lexbuf)
      in
      Error (Error.make loc "syntax error")

let parse_and_check (src : string) : (Sema.checked, Error.t list) result =
  match parse src with
  | Error e -> Error [ e ]
  | Ok block -> Sema.analyze block

type outputs = { prose : string; json : Yojson.Safe.t }
type outcome = Success of outputs | Failure of Error.t list

let compile_string (src : string) : outcome =
  match parse_and_check src with
  | Error ds -> Failure ds
  | Ok checked ->
      let ir = Lower.lower checked in
      Success { prose = Backend_prose.render ir; json = Backend_openai.render ir }
