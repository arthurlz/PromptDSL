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
