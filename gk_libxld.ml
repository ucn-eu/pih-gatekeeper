open Lwt
open Gk_msg

module Vc = Vchan_lwt_unix
module Xs = Xs_client_lwt.Client(Xs_transport_lwt_unix_client)
module VM = Gk_libxl_backend.Make

let (/) d f = Filename.concat d f
let log s = Printf.printf "%s\n" s
let log_s s = Lwt_io.printlf "%s" s
let tbl : (int, VM.t) Hashtbl.t = Hashtbl.create 7

let register_server xs server_name port =
  Xs.(immediate xs (fun h -> read h "domid")) >>= fun domid ->
  let perm = Xs_protocol.ACL.({owner=(int_of_string domid); other=RDWR; acl=[]}) in
  Xs.(immediate xs (fun h -> rm h "/jitsu")) >>= fun () ->

  let () = if domid <> "0" then failwith "should run in dom0" in
  let path = "/jitsu"/server_name/"domid" in
  Xs.(immediate xs (fun h -> write h path domid)) >>= fun () ->
  Xs.(immediate xs (fun h -> setperms h path perm)) >>= fun () ->

  let path = "/jitsu"/server_name/"port" in
  Xs.(immediate xs (fun h -> write h path port)) >>= fun () ->
  Xs.(immediate xs (fun h -> setperms h path perm)) >>= fun () ->

  let path = "/jitsu/clients" in
  Xs.(immediate xs (fun h -> rm h path)) >>= fun () ->
  Xs.(immediate xs (fun h -> mkdir h path)) >>= fun () ->
  Xs.(immediate xs (fun h -> setperms h path perm)) >>= fun () ->

  return_unit


let read_client_domid xs =
  Xs.(wait xs (fun h ->
    Lwt.catch (fun () -> read h "/jitsu/clients/domid") (function
      | Xs_protocol.Enoent e ->
         log_s ("read_client_domid Enoent " ^ e) >>= fun () ->
         Lwt.fail Xs_protocol.Eagain
      | _ as e -> Lwt.fail e)))


let listen xs server_name port =
  register_server xs server_name port >>= fun () ->
  log_s (Printf.sprintf "registered as %s:%s" server_name port) >>= fun () ->
  read_client_domid xs >>= fun domid ->
  log_s ("found client at dom" ^ domid) >>= fun () ->
  let domid = int_of_string domid in
  let port = match Vchan.Port.of_string port with
    | `Ok p -> p | `Error s -> failwith s in
  Vc.open_server ~domid ~port ~buffer_size:1024 ()


let error_message = function
  | `Not_found -> "Not found"
  | `Disconnected d -> "Disconnected " ^ d
  | `Unknown u -> "Unknown " ^ u
  | `Unable_to_connect u -> "Unable to connect " ^ u
  | `Not_supported -> "Not supported"
  | `Invalid_config i -> "Invalid config " ^ i
  | _ -> "no info"


let to_response m = function
  | `Ok o -> log_s "OK" >>= fun () -> return @@ `Ok (m o)
  | `Error e -> log_s "ERROR" >>= fun () -> return @@ `Error (error_message e)


let dispatch_call msg =
  log_s ("call for " ^ msg.func_name) >>= fun () ->
  match msg.request with
  | `Connect (domid, uri) ->
     let m t =
       let () = Hashtbl.add tbl domid t in
       "" in
     VM.connect ~connstr:uri () >>= to_response m
  | `Configure (domid, config) ->
     let t = Hashtbl.find tbl domid in
     let m = Uuidm.to_string in
     VM.configure_vm t config >>= to_response m
  | `Lookup (domid, name) ->
     let t = Hashtbl.find tbl domid in
     let m = Uuidm.to_string in
     VM.lookup_vm_by_name t name >>= to_response m
  | `State (domid, uuid) ->
     let t = Hashtbl.find tbl domid in
     let m = Gk_vm_state.to_string in
     VM.get_state t uuid >>= to_response m
  | `Name (domid, uuid) ->
     let t = Hashtbl.find tbl domid in
     let m opt = match opt with None -> "none" | Some n -> n in
     VM.get_name t uuid >>= to_response m
  | `DomainId (domid, uuid) ->
     let t = Hashtbl.find tbl domid in
     let m = string_of_int in
     VM.get_domain_id t uuid >>= to_response m
  | `Mac (domid, uuid) ->
     let t = Hashtbl.find tbl domid in
     let m macs =
       Sexplib.Std.sexp_of_list Macaddr.sexp_of_t macs
       |> Sexplib.Sexp.to_string in
     VM.get_mac t uuid >>= to_response m
  | `Shutdown (domid, uuid) ->
     let t = Hashtbl.find tbl domid in
     let m = fun _ -> "" in
     VM.shutdown_vm t uuid >>= to_response m
  | `Suspend (domid, uuid) ->
     let t = Hashtbl.find tbl domid in
     let m = fun _ -> "" in
     VM.suspend_vm t uuid >>= to_response m
  | `Destroy  (domid, uuid) ->
     let t = Hashtbl.find tbl domid in
     let m = fun _ -> "" in
     VM.destroy_vm t uuid >>= to_response m
  | `Resume  (domid, uuid) ->
     let t = Hashtbl.find tbl domid in
     let m = fun _ -> "" in
     VM.resume_vm t uuid >>= to_response m
  | `Unpause (domid, uuid) ->
     let t = Hashtbl.find tbl domid in
     let m = fun _ -> "" in
     VM.unpause_vm t uuid >>= to_response m
  | `Start (domid, uuid, config) ->
     let t = Hashtbl.find tbl domid in
     let m = fun _ -> "" in
     VM.start_vm t uuid config >>= to_response m


let rec process (ic, oc) =
  Vc.IO.read_line ic >>= function
  | None -> log_s "EOF" >>= return
  | Some str ->
     let msg = str
       |> Sexplib.Sexp.of_string
       |> Gk_msg.msg_of_sexp in
     dispatch_call msg >>= fun response ->
     let res_msg = {msg with response}
       |> Gk_msg.sexp_of_msg
       |> Sexplib.Sexp.to_string in
     Vc.IO.write oc res_msg >>= fun () ->
     Vc.IO.flush oc >>= fun () ->
     process (ic, oc)


let main () =
  let server_name, port =
    try Sys.argv.(1), Sys.argv.(2)
    with _ ->
      let server_name = "proxy_server" and port = "port" in
      log (Printf.sprintf "go with default %s %s" server_name port);
      server_name, port in

  Xs.make () >>= fun xs ->
  let rec aux () =
    listen xs server_name port >>= fun client ->
    process client in
  aux ()


let () = Lwt_main.run @@ main ()
