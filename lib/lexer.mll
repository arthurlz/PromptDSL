{
open Parser

exception Error of string * Location.t

let loc_of lexbuf =
  Location.of_positions (Lexing.lexeme_start_p lexbuf) (Lexing.lexeme_end_p lexbuf)

let keywords =
  [ ("agent", AGENT); ("goal", GOAL); ("step", STEP); ("output", OUTPUT);
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
  | '"'            { Buffer.clear buf; string_lit lexbuf }
  | ident as id    { ident_or_keyword id }
  | eof            { EOF }
  | _ as c         { raise (Error (Printf.sprintf "unexpected character '%c'" c, loc_of lexbuf)) }

and string_lit = parse
  | '"'        { STRING (Buffer.contents buf) }
  | '\\' '"'   { Buffer.add_char buf '"'; string_lit lexbuf }
  | '\\' '\\'  { Buffer.add_char buf '\\'; string_lit lexbuf }
  | '\\' 'n'   { Buffer.add_char buf '\n'; string_lit lexbuf }
  | '\\' 't'   { Buffer.add_char buf '\t'; string_lit lexbuf }
  | newline    { Lexing.new_line lexbuf; Buffer.add_char buf '\n'; string_lit lexbuf }
  | eof        { raise (Error ("unterminated string literal", loc_of lexbuf)) }
  | _ as c     { Buffer.add_char buf c; string_lit lexbuf }
