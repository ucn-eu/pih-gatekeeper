type msg = {
  mId : int;
  func_name : string;
  args : string list;
  results : string list;
}
val msg_of_sexp : Sexplib.Sexp.t -> msg
val sexp_of_msg : msg -> Sexplib.Sexp.t

type config = (string, string) Hashtbl.t
val config_of_string : string -> (string, string) Hashtbl.t
val string_of_config : (string, string) Hashtbl.t -> string
