open Promptdsl

(* Run the full execute path with a fake transport that returns canned JSON. *)
let exec provider raw =
  Runtime.execute ~provider ~transport:(fun _ -> Ok raw) (`Assoc [])

let test_openai_text () =
  match exec Runtime.openai {|{"choices":[{"message":{"content":"hello there"}}]}|} with
  | Ok s -> Alcotest.(check string) "text" "hello there" s
  | Error _ -> Alcotest.fail "unexpected error"

let test_openai_json () =
  match exec Runtime.openai {|{"choices":[{"message":{"content":"{\"score\":87}"}}]}|} with
  | Ok s ->
      Alcotest.(check bool) "reparses to same json" true
        (Yojson.Safe.from_string s = `Assoc [ ("score", `Int 87) ])
  | Error _ -> Alcotest.fail "unexpected error"

let test_openai_error () =
  match exec Runtime.openai {|{"error":{"message":"Invalid API key"}}|} with
  | Error m -> Alcotest.(check string) "err msg" "Invalid API key" m
  | Ok _ -> Alcotest.fail "expected error"

let test_openai_bad_shape () =
  match exec Runtime.openai {|{"choices":[]}|} with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected error"

let test_execute_transport_error () =
  match
    Runtime.execute ~provider:Runtime.openai
      ~transport:(fun _ -> Error "network down") (`Assoc [])
  with
  | Error m -> Alcotest.(check string) "transport err" "network down" m
  | Ok _ -> Alcotest.fail "expected error"

let suite =
  ( "runtime",
    [ Alcotest.test_case "openai text" `Quick test_openai_text;
      Alcotest.test_case "openai json" `Quick test_openai_json;
      Alcotest.test_case "openai error" `Quick test_openai_error;
      Alcotest.test_case "openai bad shape" `Quick test_openai_bad_shape;
      Alcotest.test_case "execute transport error" `Quick test_execute_transport_error ] )
