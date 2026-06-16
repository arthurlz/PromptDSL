type lookup_result = Found of string | NoAlias | NoDef

type fragments = (string * (string * string) list) list
(* alias -> [(def_name, def_text)] *)

type resolved = {
  fragments : fragments;
  templates : ((string * string) * Ast.agent_item list) list;
}

let find_template (r : resolved) (alias : string) (name : string) :
    Ast.agent_item list option =
  List.assoc_opt (alias, name) r.templates

let find (frags : fragments) (alias : string) (name : string) : lookup_result =
  match List.assoc_opt alias frags with
  | None -> NoAlias
  | Some defs -> ( match List.assoc_opt name defs with Some t -> Found t | None -> NoDef)

let lookup frags alias name =
  match find frags alias name with Found t -> Some t | _ -> None

let resolve ~(parse_lib : string -> (Ast.lib_item list, Error.t) result)
    ~(resolver : string -> (string, string) result) (imports : Ast.import_decl list) :
    (resolved, Error.t list) result =
  let errors = ref [] in
  let add loc m = errors := Error.make loc m :: !errors in
  let seen = Hashtbl.create 8 in
  let frags = ref [] and tmpls = ref [] in
  List.iter
    (fun (imp : Ast.import_decl) ->
      if Hashtbl.mem seen imp.Ast.imp_alias then
        add imp.Ast.imp_loc (Printf.sprintf "duplicate import alias '%s'" imp.Ast.imp_alias)
      else begin
        Hashtbl.add seen imp.Ast.imp_alias ();
        match resolver imp.Ast.imp_path with
        | Error msg ->
            add imp.Ast.imp_loc (Printf.sprintf "cannot import %S: %s" imp.Ast.imp_path msg)
        | Ok contents -> (
            match parse_lib contents with
            | Error e ->
                add imp.Ast.imp_loc
                  (Printf.sprintf "imported file %S is not a valid library: %s"
                     imp.Ast.imp_path e.Error.message)
            | Ok items ->
                let defs =
                  List.filter_map (function Ast.LDef d -> Some d | Ast.LTemplate _ -> None) items
                in
                let seen_def = Hashtbl.create 8 in
                let pairs =
                  List.filter_map
                    (fun (d : Ast.def_decl) ->
                      if Hashtbl.mem seen_def d.Ast.def_name then begin
                        add imp.Ast.imp_loc
                          (Printf.sprintf "duplicate def '%s' in import %S" d.Ast.def_name
                             imp.Ast.imp_path);
                        None
                      end
                      else begin
                        Hashtbl.add seen_def d.Ast.def_name ();
                        Some (d.Ast.def_name, d.Ast.def_text)
                      end)
                    defs
                in
                frags := (imp.Ast.imp_alias, pairs) :: !frags;
                let tpls =
                  List.filter_map (function Ast.LTemplate t -> Some t | Ast.LDef _ -> None) items
                in
                let seen_tpl = Hashtbl.create 8 in
                List.iter
                  (fun (t : Ast.template_decl) ->
                    if Hashtbl.mem seen_tpl t.Ast.tpl_name then
                      add imp.Ast.imp_loc
                        (Printf.sprintf "duplicate template '%s' in import %S" t.Ast.tpl_name
                           imp.Ast.imp_path)
                    else begin
                      Hashtbl.add seen_tpl t.Ast.tpl_name ();
                      tmpls :=
                        ((imp.Ast.imp_alias, t.Ast.tpl_name), t.Ast.tpl_items) :: !tmpls
                    end)
                  tpls)
      end)
    imports;
  match List.rev !errors with
  | [] -> Ok { fragments = List.rev !frags; templates = List.rev !tmpls }
  | es -> Error es
