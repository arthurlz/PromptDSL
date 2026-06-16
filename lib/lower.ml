let render_instruction (s : Sema.checked_step) : string =
  match (s.Sema.verb, s.Sema.arg) with
  | "search", Some a -> "Search for: " ^ a
  | "search", None -> "Search for relevant information"
  | "summarize", Some a -> "Summarize: " ^ a
  | "summarize", None -> "Summarize the findings"
  | "extract", Some a -> "Extract: " ^ a
  | "extract", None -> "Extract the key information"
  | "translate", Some a -> "Translate the result into: " ^ a
  | "translate", None -> "Translate the result"
  | "classify", Some a -> "Classify: " ^ a
  | "classify", None -> "Classify the result"
  | "instruct", Some a -> a
  | _, Some a -> s.Sema.verb ^ ": " ^ a
  | verb, None -> verb

let rec ty_to_ir (t : Ast.ty) : Ir.schema_ty =
  match t with
  | Ast.TString -> Ir.SString
  | Ast.TInt -> Ir.SInt
  | Ast.TBool -> Ir.SBool
  | Ast.TFloat -> Ir.SFloat
  | Ast.TEnum opts -> Ir.SEnum opts
  | Ast.TList t -> Ir.SList (ty_to_ir t)

let field_to_ir (f : Ast.field) : Ir.schema_field =
  { Ir.fname = f.Ast.field_name; fty = ty_to_ir f.Ast.field_ty;
    required = not f.Ast.optional }

let output_to_ir (o : Sema.checked_output) : Ir.output =
  match o with
  | Sema.COText -> Ir.OText
  | Sema.COMarkdown -> Ir.OMarkdown
  | Sema.COJson None -> Ir.OJson None
  (* An empty schema `output json {}` carries no constraints, so treat it the
     same as a bare `output json` rather than emitting a schema that forbids
     all keys. *)
  | Sema.COJson (Some []) -> Ir.OJson None
  | Sema.COJson (Some fields) -> Ir.OJson (Some (List.map field_to_ir fields))

let lower (b : Bind.bound) : Ir.t =
  {
    Ir.agent_name = b.Bind.b_name;
    objective = b.Bind.b_goal;
    instructions = List.map render_instruction b.Bind.b_steps;
    out = output_to_ir b.Bind.b_output;
    content = b.Bind.b_content;
  }
