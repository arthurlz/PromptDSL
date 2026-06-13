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
  | Ok block ->
      Alcotest.(check string) "name" "researcher" block.Ast.block_name;
      Alcotest.(check int) "items" 4 (List.length block.Ast.block_items);
      (match List.nth block.Ast.block_items 0 with
       | Ast.IGoal g -> Alcotest.(check string) "goal" "analyze TSLA" g.Ast.v
       | _ -> Alcotest.fail "expected goal first");
      (match List.nth block.Ast.block_items 3 with
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
  | Ok block -> (
      match List.nth block.Ast.block_items 1 with
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

let suite =
  ( "parser",
    [ Alcotest.test_case "parse ok" `Quick test_parse_ok;
      Alcotest.test_case "parse error" `Quick test_parse_error;
      Alcotest.test_case "lexer error" `Quick test_lexer_error;
      Alcotest.test_case "schema types" `Quick test_schema_types;
      Alcotest.test_case "syntax error msg" `Quick test_syntax_error_msg;
      Alcotest.test_case "syntax error eof" `Quick test_syntax_error_eof ] )
