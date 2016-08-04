open Sexplib.Std

type msg = {
  mId       : int;
  func_name : string;
  args      : string list;
  results   : string list;
} [@@deriving sexp]

type config = (string, string) Hashtbl.t

let config_of_string s =
  Sexplib.Sexp.of_string s
  |> Hashtbl.t_of_sexp string_of_sexp string_of_sexp

let string_of_config c =
  Hashtbl.sexp_of_t sexp_of_string sexp_of_string c
  |> Sexplib.Sexp.to_string

