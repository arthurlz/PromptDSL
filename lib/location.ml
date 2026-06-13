type t = {
  start_line : int;
  start_col : int;
  end_line : int;
  end_col : int;
}

let dummy = { start_line = 0; start_col = 0; end_line = 0; end_col = 0 }

let of_positions (s : Lexing.position) (e : Lexing.position) : t =
  {
    start_line = s.Lexing.pos_lnum;
    start_col = s.Lexing.pos_cnum - s.Lexing.pos_bol + 1;
    end_line = e.Lexing.pos_lnum;
    end_col = e.Lexing.pos_cnum - e.Lexing.pos_bol + 1;
  }
