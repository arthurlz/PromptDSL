open Cmdliner
open Promptdsl

let emit_conv = Arg.enum [ ("prose", `Prose); ("json", `Json); ("both", `Both) ]

let file_arg =
  let doc = "The .prompt source file." in
  Arg.(required & pos 0 (some string) None & info [] ~docv:"FILE" ~doc)

let emit_arg =
  let doc = "What to emit: prose, json, or both." in
  Arg.(value & opt emit_conv `Prose & info [ "emit" ] ~docv:"WHAT" ~doc)

let set_arg =
  let doc = "Bind an input: $(b,--set ticker=TSLA). Repeatable." in
  Arg.(value & opt_all string [] & info [ "set" ] ~docv:"KEY=VALUE" ~doc)

let compile_cmd =
  let doc = "Compile a .prompt file to a prompt and/or an OpenAI request." in
  let term = Term.(const Driver.run_compile $ file_arg $ emit_arg $ set_arg) in
  Cmd.v (Cmd.info "compile" ~doc) term

let check_cmd =
  let doc = "Parse and check a .prompt file, reporting diagnostics." in
  let term = Term.(const Driver.run_check $ file_arg) in
  Cmd.v (Cmd.info "check" ~doc) term

let () =
  let doc = "A Prompt DSL compiler." in
  let info = Cmd.info "promptc" ~version:"0.1.0" ~doc in
  exit (Cmd.eval' (Cmd.group info [ compile_cmd; check_cmd ]))
