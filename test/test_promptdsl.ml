let () =
  Alcotest.run "promptdsl"
    [ Test_basics.suite; Test_parser.suite; Test_sema.suite;
      Test_lower.suite; Test_backends.suite ]
