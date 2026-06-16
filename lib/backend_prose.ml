open Ir

let rec render_ty = function
  | SString -> "string"
  | SInt -> "int"
  | SBool -> "bool"
  | SFloat -> "float"
  | SEnum opts -> "enum(" ^ String.concat ", " opts ^ ")"
  | SList t -> "list<" ^ render_ty t ^ ">"

let render (ir : Ir.t) : string =
  let b = Buffer.create 256 in
  Buffer.add_string b (Printf.sprintf "You are \"%s\".\n" ir.agent_name);
  Buffer.add_string b (Printf.sprintf "Goal: %s\n" ir.objective);
  if ir.instructions <> [] then begin
    Buffer.add_string b "\nSteps:\n";
    List.iteri
      (fun i instr -> Buffer.add_string b (Printf.sprintf "%d. %s\n" (i + 1) instr))
      ir.instructions
  end;
  (match ir.out with
   | OText -> ()
   | OMarkdown -> Buffer.add_string b "\nFormat your answer as Markdown.\n"
   | OJson None -> Buffer.add_string b "\nReturn your answer as JSON.\n"
   | OJson (Some fields) ->
       Buffer.add_string b "\nReturn ONLY JSON matching this schema:\n";
       List.iter
         (fun f ->
           Buffer.add_string b
             (Printf.sprintf "  %s%s: %s\n" f.fname
                (if f.required then "" else "?")
                (render_ty f.fty)))
         fields);
  (match ir.content with
   | Some s when s <> "" -> Buffer.add_string b (Printf.sprintf "\n## Input\n%s\n" s)
   | _ -> ());
  Buffer.contents b
