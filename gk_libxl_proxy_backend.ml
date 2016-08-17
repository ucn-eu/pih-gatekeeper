open Lwt
open Gk_msg

module Vc = Vchan_xen
module Xs = OS.Xs

let log_src = Logs.Src.create "proxy.backend"
module Log = (val Logs.src_log log_src : Logs.LOG)

type t = {
  vchan               : Vc.t;
  domid               : int;
  mutable msg_counter : int;
}

let parse_response fn msg =
  Lwt.catch (fun () -> match msg.response with
    | `Ok ok -> fn ok >>= fun ok -> return @@ `Ok ok
    | `Error e -> return @@ `Error (`Server e)
    | `PlaceHolder -> return @@ `Error (`Unknown "`PlaceHolder response"))
    (fun exn ->
     let e = Printf.sprintf "parse_response %s %s"
       msg.func_name (Printexc.to_string exn) in
     return @@ `Error (`Unknown e))


let with_endline s = s ^ "\n"
let send_req t ~func_name ~request fn =
  let mId = t.msg_counter in
  let () = t.msg_counter <- mId + 1 in
  let msg = {mId; func_name; request; response=`PlaceHolder} in
  let buf =
    msg |> sexp_of_msg
    |> Sexplib.Sexp.to_string
    |> with_endline
    |> Cstruct.of_string in
  let send mId func_name buf =
    Log.info (fun f -> f "[%d] call %s" mId func_name);
    Vc.write t.vchan buf >>= function
    | `Ok () -> begin
        Vc.read t.vchan >>= function
        | `Ok buf ->
           buf |> Cstruct.to_string
           |> fun str ->
              Log.info (fun f -> f "response %s" str);
              Sexplib.Sexp.of_string str
              |> msg_of_sexp
              |> parse_response fn
        | `Eof | `Error _ ->
          Log.err (fun f -> f "request Vc.read");
          return @@ `Error (`Unknown "Vc.read") end
    | `Eof | `Error _ ->
       Log.err (fun f -> f "request Vc.write");
       return @@ `Error (`Unknown "Vc.write") in

  let rec try_hard cnt =
    Lwt.catch (fun () -> send mId func_name buf) (function
    | exn ->
       if cnt < 3 then begin
         Log.err (fun f -> f "retry after exn: %s" (Printexc.to_string exn));
         try_hard (succ cnt) end
       else begin
         Log.err (fun f -> f "give up after %d times" cnt);
         Lwt.fail exn end) in
  try_hard 0


let register_client xs =
  let (/) = Filename.concat in
  Xs.(immediate xs (fun h -> read h "domid")) >>= fun domid ->
  Xs.(immediate xs (fun h -> write h ("/jitsu"/"clients"/"domid") domid)) >>= fun () ->
  return @@ int_of_string domid


let connect_server xs ~server_name =
  let (/) = Filename.concat in
  Xs.(immediate xs (fun h -> read h ("/jitsu"/server_name/"domid"))) >>= fun domid ->
  Xs.(immediate xs (fun h -> read h ("/jitsu"/server_name/"port"))) >>= fun port ->
  let domid = int_of_string domid in
  match Vchan.Port.of_string port with
  | `Error e -> return @@ `Error (`Unknown ("Vchan.Port.of_string " ^ e))
  | `Ok port ->
      Vc.client ~domid ~port () >>= fun t ->
      return @@ `Ok t


(********** Gk_backends.VM_BACKEND *********)

let connect ?log_f ?connstr () =
  Xs.make () >>= fun xs ->
  (* first register as a client, hoping the server pick it up, then make connection *)
  register_client xs >>= fun domid ->
  let server_name = "proxy_server" in
  connect_server xs ~server_name >>= function
  | `Ok vchan ->
     let t = {vchan; domid; msg_counter = 0} in
     let request = `Connect (domid, None) in
     let fn = fun _ -> return_unit in
     send_req t ~func_name:"connect" ~request fn >>= (function
     | `Ok _ -> return @@ `Ok t
     | `Error _ as e -> return e)
  | `Error _ as e -> return e


let parse_uuidm s =
  match Uuidm.of_string s with
  | Some id -> return id
  | None -> Lwt.fail (Invalid_argument ("Uuidm.of_string " ^ s))


let configure_vm t config =
  let request = `Configure (t.domid, config) in
  let fn = parse_uuidm in
  send_req t ~func_name:"configure_vm" ~request fn


(* directly from libxl_backend.xl *)
let get_config_option_list =
  [ ("name", "Name of created VM (required)") ;
    ("dns", "DNS name (required)") ;
    ("ip", "IP to return in DNS reply (required)");
    ("kernel", "VM kernel file name (required)") ;
    ("memory", "VM memory in bytes (required)") ;
    ("cmdline", "Extra parameters passed to kernel (optional)") ;
    ("nic", "Network device (br0, eth0 etc). Can be set more than once to configure multiple NICs (optional)") ;
    ("script", "Virtual interface (VIF) configuration script. Can be set more than once to specify a VIF script per network device (optional)") ;
    ("disk", "Disk to connect to the Xen VM. Format '[dom0 device or file]@[hdX/xvdX/sdX etc]'. Can be set more than once to configure multiple disks (optional)") ;
    ("rumprun_config", "Path to file with rumprun unikernel JSON config (optional)") ;
  ]


let lookup_vm_by_name t name =
  let args = [name] in
  let request = `Lookup (t.domid, name) in
  let fn = parse_uuidm in
  send_req t ~func_name:"lookup_vm_by_name" ~request fn


let get_state t uuid =
  let func_name = "get_state" in
  let request = `State (t.domid, uuid) in
  let fn = fun s -> return @@ Gk_vm_state.of_string s in
  send_req t ~func_name ~request fn


let get_name t uuid =
  let func_name = "get_name" in
  let request = `Name (t.domid, uuid) in
  let fn = fun s ->
    if s = "none" then return_none
    else return_some s
  in
  send_req t ~func_name ~request fn


let get_domain_id t uuid =
  let func_name = "get_domain_id" in
  let request = `DomainId (t.domid, uuid) in
  let fn = fun s -> return @@ int_of_string s in
  send_req t ~func_name ~request fn


let get_mac t uuid =
  let func_name = "get_mac" in
  let request = `Mac (t.domid, uuid) in
  let fn = fun s ->
    Sexplib.Sexp.of_string s
    |> Sexplib.Std.list_of_sexp Macaddr.t_of_sexp
    |> return
  in
  send_req t ~func_name ~request fn


let shutdown_vm t uuid =
  let func_name = "shutdown_vm" in
  let request = `Shutdown (t.domid, uuid) in
  let fn = fun _ -> return_unit in
  send_req t ~func_name ~request fn


let suspend_vm t uuid =
  let func_name = "suspend_vm" in
  let request = `Suspend (t.domid, uuid) in
  let fn = fun _ -> return_unit in
  send_req t ~func_name ~request fn


let destroy_vm t uuid =
  let func_name = "destroy_vm" in
  let request = `Destroy (t.domid, uuid) in
  let fn = fun _ -> return_unit in
  send_req t ~func_name ~request fn


let resume_vm t uuid =
  let func_name = "resume_vm" in
  let request = `Resume (t.domid, uuid) in
  let fn = fun _ -> return_unit in
  send_req t ~func_name ~request fn


let unpause_vm t uuid =
  let func_name = "unpause_vm" in
  let request = `Resume (t.domid, uuid) in
  let fn = fun _ -> return_unit in
  send_req t ~func_name ~request fn


let start_vm t uuid config =
  let func_name = "start_vm" in
  let request = `Start (t.domid, uuid, config) in
  let fn = fun _ -> return_unit in
  send_req t ~func_name ~request fn
