type 'a node = { v : 'a; span : Location.t }

let node v span = { v; span }

type ty =
  | TString
  | TInt
  | TBool
  | TEnum of string list
  | TList of ty

type field = {
  field_name : string;
  field_ty : ty;
  optional : bool;
  field_loc : Location.t;
}

type input_decl = {
  in_name : string;
  in_ty : ty;
  in_default : string option;
  in_content : bool;
  in_loc : Location.t;
}

type action = { action_name : string node; action_arg : string option }

type raw_output = { out_format : string node; out_schema : field list option }

type agent_item =
  | IGoal of string node
  | IStep of action
  | IOutput of raw_output node
  | IInputs of input_decl list node

type agent_block = {
  block_name : string;
  block_items : agent_item list;
  block_loc : Location.t;
}
