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

let suite =
  ( "parser",
    [ Alcotest.test_case "parse ok" `Quick test_parse_ok;
      Alcotest.test_case "parse error" `Quick test_parse_error ] )
