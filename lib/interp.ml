(* Scan a string for {{ name }} occurrences. Returns each (name, start, stop)
   where the literal {{...}} spans [start, stop) in the original string. *)
let tokens (s : string) : (string * int * int) list =
  let n = String.length s in
  let acc = ref [] in
  let i = ref 0 in
  while !i + 1 < n do
    if s.[!i] = '{' && s.[!i + 1] = '{' then begin
      let j = ref (!i + 2) in
      let close = ref (-1) in
      while !j + 1 < n && !close < 0 do
        if s.[!j] = '}' && s.[!j + 1] = '}' then close := !j else incr j
      done;
      if !close >= 0 then begin
        let name = String.trim (String.sub s (!i + 2) (!close - (!i + 2))) in
        acc := (name, !i, !close + 2) :: !acc;
        i := !close + 2
      end
      else i := n
    end
    else incr i
  done;
  List.rev !acc

(* Names referenced by {{...}}, ignoring malformed empties. *)
let refs (s : string) : string list =
  List.filter_map
    (fun (name, _, _) -> if name = "" then None else Some name)
    (tokens s)

(* Replace each {{name}} via [lookup]; unknown names are left verbatim. *)
let subst (lookup : string -> string option) (s : string) : string =
  match tokens s with
  | [] -> s
  | toks ->
      let b = Buffer.create (String.length s) in
      let pos = ref 0 in
      List.iter
        (fun (name, start, stop) ->
          Buffer.add_string b (String.sub s !pos (start - !pos));
          (match lookup name with
           | Some v -> Buffer.add_string b v
           | None -> Buffer.add_string b (String.sub s start (stop - start)));
          pos := stop)
        toks;
      Buffer.add_string b (String.sub s !pos (String.length s - !pos));
      Buffer.contents b
