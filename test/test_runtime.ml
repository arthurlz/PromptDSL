open Promptdsl

let resp s = Yojson.Safe.from_string s

let test_format_text () =
  match Runtime.format_response (resp {|{"choices":[{"message":{"content":"hello there"}}]}|}) with
  | Ok s -> Alcotest.(check string) "text" "hello there" s
  | Error _ -> Alcotest.fail "unexpected error"

let test_format_json () =
  match Runtime.format_response (resp {|{"choices":[{"message":{"content":"{\"score\":87}"}}]}|}) with
  | Ok s ->
      Alcotest.(check bool) "reparses to same json" true
        (Yojson.Safe.from_string s = `Assoc [ ("score", `Int 87) ])
  | Error _ -> Alcotest.fail "unexpected error"

let test_format_error () =
  match Runtime.format_response (resp {|{"error":{"message":"Invalid API key"}}|}) with
  | Error m -> Alcotest.(check string) "err msg" "Invalid API key" m
  | Ok _ -> Alcotest.fail "expected error"

let test_format_bad_shape () =
  match Runtime.format_response (resp {|{"choices":[]}|}) with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected error"

let test_execute_fake () =
  let transport _ = Ok {|{"choices":[{"message":{"content":"hi"}}]}|} in
  match Runtime.execute ~transport (`Assoc []) with
  | Ok s -> Alcotest.(check string) "fake transport" "hi" s
  | Error _ -> Alcotest.fail "unexpected error"

let test_execute_transport_error () =
  let transport _ = Error "network down" in
  match Runtime.execute ~transport (`Assoc []) with
  | Error m -> Alcotest.(check string) "transport err" "network down" m
  | Ok _ -> Alcotest.fail "expected error"

let suite =
  ( "runtime",
    [ Alcotest.test_case "format text" `Quick test_format_text;
      Alcotest.test_case "format json" `Quick test_format_json;
      Alcotest.test_case "format error" `Quick test_format_error;
      Alcotest.test_case "format bad shape" `Quick test_format_bad_shape;
      Alcotest.test_case "execute fake" `Quick test_execute_fake;
      Alcotest.test_case "execute transport error" `Quick test_execute_transport_error ] )
