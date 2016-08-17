type config = (string, string) Hashtbl.t
type uuid = Uuidm.t

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
]

type response =
  [ `Ok of string
  | `Error of string
  | `PlaceHolder
]

type msg = {
  mId       : int;
  func_name : string;
  request   : request;
  response  : response;
}

val msg_of_sexp : Sexplib.Sexp.t -> msg
val sexp_of_msg : msg -> Sexplib.Sexp.t

val id_of_msg : msg -> int
