open Sexplib.Std


type config = (string, string) Hashtbl.t

let config_of_string s =
  Sexplib.Sexp.of_string s
  |> Hashtbl.t_of_sexp string_of_sexp string_of_sexp

let string_of_config c =
  Hashtbl.sexp_of_t sexp_of_string sexp_of_string c
  |> Sexplib.Sexp.to_string

let sexp_of_config config =
  Hashtbl.sexp_of_t sexp_of_string sexp_of_string config

let config_of_sexp sexp =
  Hashtbl.t_of_sexp string_of_sexp string_of_sexp sexp


type uuid = Uuidm.t

let sexp_of_uuid uuid =
  Uuidm.to_string uuid |> sexp_of_string

let uuid_of_sexp sexp =
  string_of_sexp sexp |> Uuidm.of_string |> function
  | None -> failwith "uuid_of_sexp"
  | Some u -> u


type request =
  [ `Connect of int * Uri.t option
  | `Configure of int * config
  | `Lookup of int * string
  | `State of int * uuid
  | `Name of int * uuid
  | `DomainId of int * uuid
  | `Mac of int * uuid
  | `Shutdown of int * uuid
  | `Suspend of int * uuid
  | `Destroy of int * uuid
  | `Resume of int * uuid
  | `Unpause of int * uuid
  | `Start of int * uuid * config
] [@@deriving sexp]


type response =
  [ `Ok of string
  | `Error of string
  | `PlaceHolder
] [@@deriving sexp]


type msg = {
  mId       : int;
  func_name : string;
  request   : request;
  response  : response;
} [@@deriving sexp]


