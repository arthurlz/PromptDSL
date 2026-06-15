%{
open Ast

let mknode v (s, e) = { v; span = Location.of_positions s e }
let mkloc (s, e) = Location.of_positions s e
%}

%token AGENT GOAL STEP OUTPUT INPUT
%token STRING_TY INT_TY BOOL_TY ENUM LIST
%token <string> IDENT
%token <string> STRING
%token LBRACE RBRACE LPAREN RPAREN LT GT COMMA COLON QUESTION
%token EQ CONTENT
%token EOF

%start <Ast.agent_block> program

%%

program:
  | a = agent EOF { a }

agent:
  | AGENT name = STRING LBRACE items = list(item) RBRACE
    { { block_name = name; block_items = items; block_loc = mkloc $loc } }

item:
  | GOAL s = STRING
    { IGoal (mknode s $loc(s)) }
  | STEP LBRACE a = action RBRACE
    { IStep a }
  | OUTPUT f = IDENT s = schema_opt
    { IOutput (mknode { out_format = mknode f $loc(f); out_schema = s } $loc) }
  | INPUT LBRACE fs = list(input_field) RBRACE
    { IInputs (mknode fs $loc) }

action:
  | name = IDENT arg = action_arg
    { { action_name = mknode name $loc(name); action_arg = arg } }

action_arg:
  | { None }
  | s = STRING { Some s }

schema_opt:
  | { None }
  | LBRACE fs = list(field) RBRACE { Some fs }

field:
  | name = IDENT q = boption(QUESTION) COLON t = ty
    { { field_name = name; field_ty = t; optional = q; field_loc = mkloc $loc } }

input_field:
  | name = IDENT COLON t = ty d = default_opt c = content_opt
    { { in_name = name; in_ty = t; in_default = d; in_content = c; in_loc = mkloc $loc } }

default_opt:
  | { None }
  | EQ s = STRING { Some s }

content_opt:
  | { false }
  | CONTENT { true }

ty:
  | STRING_TY { TString }
  | INT_TY    { TInt }
  | BOOL_TY   { TBool }
  | ENUM LPAREN opts = separated_nonempty_list(COMMA, STRING) RPAREN { TEnum opts }
  | LIST LT t = ty GT { TList t }
