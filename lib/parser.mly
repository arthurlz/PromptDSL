%{
open Ast

let mknode v (s, e) = { v; span = Location.of_positions s e }
let mkloc (s, e) = Location.of_positions s e
%}

%token AGENT GOAL STEP OUTPUT INPUT
%token IMPORT AS DEF
%token TEMPLATE EXTENDS DOT
%token STRING_TY INT_TY BOOL_TY FLOAT_TY ENUM LIST
%token <string> IDENT
%token <string> STRING
%token LBRACE RBRACE LPAREN RPAREN LT GT COMMA COLON QUESTION
%token EQ CONTENT
%token <int> INT_LIT
%token <float> FLOAT_LIT
%token DOTDOT
%token EOF

%start <Ast.agent_file> program
%start <Ast.lib_item list> library

%%

program:
  | imports = list(import_decl) a = agent EOF
    { { af_imports = imports; af_agent = a } }

library:
  | items = list(lib_item) EOF { items }

lib_item:
  | d = def_decl { Ast.LDef d }
  | t = template_decl { Ast.LTemplate t }

template_decl:
  | TEMPLATE name = IDENT LBRACE items = list(item) RBRACE
    { { tpl_name = name; tpl_items = items; tpl_loc = mkloc $loc } }

import_decl:
  | IMPORT p = STRING AS a = IDENT
    { { imp_path = p; imp_alias = a; imp_loc = mkloc $loc } }

def_decl:
  | DEF name = IDENT EQ text = STRING
    { { def_name = name; def_text = text; def_loc = mkloc $loc } }

agent:
  | AGENT name = STRING ext = extends_opt LBRACE items = list(item) RBRACE
    { { block_name = name; block_items = items; block_loc = mkloc $loc; block_extends = ext } }

extends_opt:
  | { None }
  | EXTENDS a = IDENT DOT n = IDENT { Some (a, n, mkloc $loc) }

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
  | name = IDENT q = boption(QUESTION) COLON t = ty r = range_opt
    { { field_name = name; field_ty = t; optional = q; field_loc = mkloc $loc; field_range = r } }

range_opt:
  | { None }
  | LPAREN lo = number DOTDOT hi = number RPAREN { Some (lo, hi) }

number:
  | n = INT_LIT { float_of_int n }
  | f = FLOAT_LIT { f }

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
  | FLOAT_TY  { TFloat }
  | ENUM LPAREN opts = separated_nonempty_list(COMMA, STRING) RPAREN { TEnum opts }
  | LIST LT t = ty GT { TList t }
