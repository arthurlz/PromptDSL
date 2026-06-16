open Promptdsl

let researcher =
  {|
agent "researcher" {
  goal "analyze TSLA"
  step { search "TSLA earnings" }
  step { summarize }
  output json {
    ticker: string
    rating: enum("buy", "hold", "sell")
    summary: string
  }
}
|}

let test_parse_ok () =
  match Compile.parse researcher with
  | Error e -> Alcotest.failf "unexpected parse error: %s" e.Error.message
  | Ok af ->
      Alcotest.(check string) "name" "researcher" af.Ast.af_agent.Ast.block_name;
      Alcotest.(check int) "items" 4 (List.length af.Ast.af_agent.Ast.block_items);
      (match List.nth af.Ast.af_agent.Ast.block_items 0 with
       | Ast.IGoal g -> Alcotest.(check string) "goal" "analyze TSLA" g.Ast.v
       | _ -> Alcotest.fail "expected goal first");
      (match List.nth af.Ast.af_agent.Ast.block_items 3 with
       | Ast.IOutput o ->
           Alcotest.(check string) "fmt" "json" o.Ast.v.Ast.out_format.Ast.v;
           (match o.Ast.v.Ast.out_schema with
            | Some fs -> Alcotest.(check int) "fields" 3 (List.length fs)
            | None -> Alcotest.fail "expected schema")
       | _ -> Alcotest.fail "expected output last")

let test_parse_error () =
  match Compile.parse "agent \"x\" { goal }" with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected parse error (goal without string)"

(* Exercises Compile.parse's Lexer.Error routing (an unterminated string
   literal), which is otherwise untested. *)
let test_lexer_error () =
  match Compile.parse {|agent "x" { goal "oops |} with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected lexer error for unterminated string"

(* Locks in the AST shapes for list<T>, optional `?`, and enum, which later
   passes depend on but the happy-path test does not exercise. *)
let test_schema_types () =
  let src =
    {|agent "a" {
        goal "g"
        output json {
          tags: list<string>
          note?: string
          rating: enum("buy", "sell")
        }
      }|}
  in
  match Compile.parse src with
  | Error e -> Alcotest.failf "unexpected parse error: %s" e.Error.message
  | Ok af -> (
      match List.nth af.Ast.af_agent.Ast.block_items 1 with
      | Ast.IOutput o -> (
          match o.Ast.v.Ast.out_schema with
          | Some [ tags; note; rating ] ->
              Alcotest.(check bool) "tags is list<string>" true
                (tags.Ast.field_ty = Ast.TList Ast.TString);
              Alcotest.(check bool) "note optional" true note.Ast.optional;
              Alcotest.(check bool) "rating enum" true
                (rating.Ast.field_ty = Ast.TEnum [ "buy"; "sell" ])
          | _ -> Alcotest.fail "expected 3 schema fields")
      | _ -> Alcotest.fail "expected output item")

(* Syntax errors name the offending token (or report end-of-input). *)
let test_syntax_error_msg () =
  match Compile.parse "agent \"x\" { goal }" with
  | Ok _ -> Alcotest.fail "expected syntax error"
  | Error e ->
      Alcotest.(check string) "near token" "syntax error near '}'" e.Error.message

let test_syntax_error_eof () =
  match Compile.parse "agent \"x\" {" with
  | Ok _ -> Alcotest.fail "expected syntax error"
  | Error e ->
      Alcotest.(check string) "eof" "syntax error at end of input" e.Error.message

let test_parse_input_block () =
  let src =
    {|agent "a" {
        input {
          ticker: string
          depth:  enum("brief", "deep") = "brief"
          notes:  string @content
        }
        goal "Analyze {{ticker}} at {{depth}}."
      }|}
  in
  match Compile.parse src with
  | Error e -> Alcotest.failf "unexpected parse error: %s" e.Error.message
  | Ok af -> (
      match
        List.find_map
          (function Ast.IInputs n -> Some n.Ast.v | _ -> None)
          af.Ast.af_agent.Ast.block_items
      with
      | Some [ a; b; c ] ->
          Alcotest.(check string) "1 name" "ticker" a.Ast.in_name;
          Alcotest.(check bool) "1 required" true (a.Ast.in_default = None);
          Alcotest.(check (option string)) "2 default" (Some "brief") b.Ast.in_default;
          Alcotest.(check bool) "3 content" true c.Ast.in_content
      | _ -> Alcotest.fail "expected an input block with 3 fields")

let test_parse_import_and_agent () =
  let src =
    {|import "finance.prompt" as fin
      agent "a" { goal "g {{fin.disclaimer}}" }|}
  in
  match Compile.parse src with
  | Error e -> Alcotest.failf "unexpected parse error: %s" e.Error.message
  | Ok af -> (
      Alcotest.(check string) "agent name" "a" af.Ast.af_agent.Ast.block_name;
      match af.Ast.af_imports with
      | [ i ] ->
          Alcotest.(check string) "path" "finance.prompt" i.Ast.imp_path;
          Alcotest.(check string) "alias" "fin" i.Ast.imp_alias
      | _ -> Alcotest.fail "expected one import")

let test_parse_library () =
  match Compile.parse_library {|def disclaimer = "x"  def rubric = "y"|} with
  | Error e -> Alcotest.failf "unexpected: %s" e.Error.message
  | Ok [ Ast.LDef a; Ast.LDef b ] ->
      Alcotest.(check string) "1 name" "disclaimer" a.Ast.def_name;
      Alcotest.(check string) "1 text" "x" a.Ast.def_text;
      Alcotest.(check string) "2 name" "rubric" b.Ast.def_name
  | Ok _ -> Alcotest.fail "expected two defs"

let test_parse_template () =
  match Compile.parse_library {|def d = "x"  template Rater { goal "g" step { summarize } }|} with
  | Error e -> Alcotest.failf "unexpected: %s" e.Error.message
  | Ok [ Ast.LDef d; Ast.LTemplate t ] ->
      Alcotest.(check string) "def" "d" d.Ast.def_name;
      Alcotest.(check string) "tpl name" "Rater" t.Ast.tpl_name;
      Alcotest.(check int) "tpl items" 2 (List.length t.Ast.tpl_items)
  | Ok _ -> Alcotest.fail "expected one def then one template"

let test_parse_extends () =
  match Compile.parse {|import "s.prompt" as s
                        agent "a" extends s.Rater { goal "g" }|} with
  | Error e -> Alcotest.failf "unexpected: %s" e.Error.message
  | Ok af -> (
      match af.Ast.af_agent.Ast.block_extends with
      | Some (alias, name, _) ->
          Alcotest.(check string) "alias" "s" alias;
          Alcotest.(check string) "name" "Rater" name
      | None -> Alcotest.fail "expected extends")

let test_parse_float () =
  match Compile.parse {|agent "a" { input { pe: float } goal "g" output json { p: float } }|} with
  | Error e -> Alcotest.failf "parse: %s" e.Error.message
  | Ok af ->
      let items = af.Ast.af_agent.Ast.block_items in
      (match List.find_map (function Ast.IInputs n -> Some n.Ast.v | _ -> None) items with
       | Some [ d ] -> Alcotest.(check bool) "float input" true (d.Ast.in_ty = Ast.TFloat)
       | _ -> Alcotest.fail "expected one input");
      (match List.find_map (function Ast.IOutput o -> Some o.Ast.v | _ -> None) items with
       | Some ro -> (
           match ro.Ast.out_schema with
           | Some [ f ] -> Alcotest.(check bool) "float field" true (f.Ast.field_ty = Ast.TFloat)
           | _ -> Alcotest.fail "expected one field")
       | None -> Alcotest.fail "expected output")

let suite =
  ( "parser",
    [ Alcotest.test_case "parse ok" `Quick test_parse_ok;
      Alcotest.test_case "parse error" `Quick test_parse_error;
      Alcotest.test_case "lexer error" `Quick test_lexer_error;
      Alcotest.test_case "schema types" `Quick test_schema_types;
      Alcotest.test_case "syntax error msg" `Quick test_syntax_error_msg;
      Alcotest.test_case "syntax error eof" `Quick test_syntax_error_eof;
      Alcotest.test_case "input block" `Quick test_parse_input_block;
      Alcotest.test_case "import+agent" `Quick test_parse_import_and_agent;
      Alcotest.test_case "library" `Quick test_parse_library;
      Alcotest.test_case "template" `Quick test_parse_template;
      Alcotest.test_case "extends" `Quick test_parse_extends;
      Alcotest.test_case "float" `Quick test_parse_float ] )
