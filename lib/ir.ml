type schema_ty =
  | SString
  | SInt
  | SBool
  | SEnum of string list
  | SList of schema_ty

type schema_field = { fname : string; fty : schema_ty; required : bool }

type output =
  | OText
  | OMarkdown
  | OJson of schema_field list option

type t = {
  agent_name : string;
  objective : string;
  instructions : string list;
  out : output;
}
