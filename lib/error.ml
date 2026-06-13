type t = { loc : Location.t; message : string; hint : string option }

let make ?hint loc message = { loc; message; hint }

let to_string ~(filename : string) (d : t) : string =
  let base =
    Printf.sprintf "%s:%d:%d: error: %s" filename d.loc.Location.start_line
      d.loc.Location.start_col d.message
  in
  match d.hint with
  | Some h -> base ^ Printf.sprintf " (%s)" h
  | None -> base
