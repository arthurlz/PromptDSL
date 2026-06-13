open Promptdsl

let test_location () =
  let s = Lexing.{ pos_fname = ""; pos_lnum = 2; pos_bol = 10; pos_cnum = 12 } in
  let e = Lexing.{ pos_fname = ""; pos_lnum = 2; pos_bol = 10; pos_cnum = 18 } in
  let loc = Location.of_positions s e in
  Alcotest.(check int) "line" 2 loc.Location.start_line;
  Alcotest.(check int) "col" 3 loc.Location.start_col

let test_error_format () =
  let loc = Location.{ start_line = 3; start_col = 5; end_line = 3; end_col = 11 } in
  let d = Error.make ~hint:"did you mean 'search'?" loc "unknown action 'searchh'" in
  Alcotest.(check string) "fmt"
    "f.prompt:3:5: error: unknown action 'searchh' (did you mean 'search'?)"
    (Error.to_string ~filename:"f.prompt" d)

let suite =
  ( "basics",
    [ Alcotest.test_case "location" `Quick test_location;
      Alcotest.test_case "error format" `Quick test_error_format ] )
