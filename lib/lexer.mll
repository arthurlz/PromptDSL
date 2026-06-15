{
open Parser

exception Error of string * Location.t

let loc_of lexbuf =
  Location.of_positions (Lexing.lexeme_start_p lexbuf) (Lexing.lexeme_end_p lexbuf)

let keywords =
  [ ("agent", AGENT); ("goal", GOAL); ("step", STEP); ("output", OUTPUT);
    ("input", INPUT);
    ("string", STRING_TY); ("int", INT_TY); ("bool", BOOL_TY);
    ("enum", ENUM); ("list", LIST) ]

let ident_or_keyword s =
  match List.assoc_opt s keywords with Some t -> t | None -> IDENT s

let buf = Buffer.create 64
}

let white = [' ' '\t' '\r']+
let newline = '\n'
let ident = ['a'-'z' 'A'-'Z' '_'] ['a'-'z' 'A'-'Z' '0'-'9' '_']*

rule token = parse
  | white          { token lexbuf }
  | newline        { Lexing.new_line lexbuf; token lexbuf }
  | "//" [^ '\n']* { token lexbuf }
  | '{'            { LBRACE }
  | '}'            { RBRACE }
  | '('            { LPAREN }
  | ')'            { RPAREN }
  | '<'            { LT }
  | '>'            { GT }
  | ','            { COMMA }
  | ':'            { COLON }
  | '?'            { QUESTION }
  | '='            { EQ }
  | "@content"     { CONTENT }
  | '"'            { let start_p = Lexing.lexeme_start_p lexbuf in
                     Buffer.clear buf;
                     let tok = string_lit start_p lexbuf in
                     (* Re-anchor the token start to the opening quote;
                        sub-matches inside string_lit would otherwise leave it
                        at the closing quote. *)
                     lexbuf.Lexing.lex_start_p <- start_p;
                     tok }
  | ident as id    { ident_or_keyword id }
  | eof            { EOF }
  | _ as c         { raise (Error (Printf.sprintf "unexpected character '%c'" c, loc_of lexbuf)) }

(* String literals interpret the escapes backslash-quote, double-backslash,
   backslash-n, and backslash-t. Any other backslash sequence is kept verbatim
   (a backslash followed by d stays as those two characters), which is handy for
   prose and regex inside instruction text. [start_p] is the opening-quote
   position, used for the unterminated-string diagnostic. *)
and string_lit start_p = parse
  | '"'        { STRING (Buffer.contents buf) }
  | '\\' '"'   { Buffer.add_char buf '"'; string_lit start_p lexbuf }
  | '\\' '\\'  { Buffer.add_char buf '\\'; string_lit start_p lexbuf }
  | '\\' 'n'   { Buffer.add_char buf '\n'; string_lit start_p lexbuf }
  | '\\' 't'   { Buffer.add_char buf '\t'; string_lit start_p lexbuf }
  | newline    { Lexing.new_line lexbuf; Buffer.add_char buf '\n'; string_lit start_p lexbuf }
  | eof        { raise (Error ("unterminated string literal",
                               Location.of_positions start_p (Lexing.lexeme_end_p lexbuf))) }
  | _ as c     { Buffer.add_char buf c; string_lit start_p lexbuf }
