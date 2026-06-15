open Promptdsl

let test_refs () =
  Alcotest.(check (list string)) "refs"
    [ "ticker"; "depth" ]
    (Interp.refs "Analyze {{ticker}} at {{ depth }} depth.");
  Alcotest.(check (list string)) "none" [] (Interp.refs "no refs here")

let test_subst () =
  let lookup = function "ticker" -> Some "TSLA" | _ -> None in
  Alcotest.(check string) "subst"
    "Analyze TSLA now"
    (Interp.subst lookup "Analyze {{ticker}} now");
  (* unknown refs are left verbatim; subst is not responsible for validation *)
  Alcotest.(check string) "unknown left as-is"
    "Hi {{name}}"
    (Interp.subst lookup "Hi {{name}}")

let suite =
  ( "interp",
    [ Alcotest.test_case "refs" `Quick test_refs;
      Alcotest.test_case "subst" `Quick test_subst ] )
