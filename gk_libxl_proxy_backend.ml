open Lwt
open Gk_msg

module Vc = Vchan_xen
module Xs = OS.Xs

let log_src = Logs.Src.create "proxy.backend"
module Log = (val Logs.src_log log_src : Logs.LOG)

type t = {
  vchan               : Vc.t;
  mutable msg_counter : int;
}


let request t ~func_name ~args =
  let mId = t.msg_counter in
  let () = t.msg_counter <- mId + 1 in
  let msg = {mId; func_name; args; results = []} in
  let buf =
    msg |> sexp_of_msg
    |> Sexplib.Sexp.to_string
    |> Cstruct.of_string in
  Vc.write t.vchan buf >>= function
  | `Ok () -> begin
     Vc.read t.vchan >>= function
     | `Ok buf ->
        buf |> Cstruct.to_string
        |> Sexplib.Sexp.of_string
        |> msg_of_sexp
        |> fun msg -> return @@ `Ok msg
     | `Eof | `Error _ ->
        Log.err (fun f -> f "request Vc.read");
        return @@ `Error (`Unknown "Vc.read") end
  | `Eof | `Error _ ->
     Log.err (fun f -> f "request Vc.write");
     return @@ `Error (`Unknown "Vc.write")


let connect_server ~server_name =
  let (/) = Filename.concat in
  Xs.make () >>= fun xs ->
  Xs.(immediate xs (fun h -> read h ("jitsu"/server_name/"domid"))) >>= fun domid ->
  Xs.(immediate xs (fun h -> read h ("jitsu"/server_name/"port"))) >>= fun port ->
  let domid = int_of_string domid in
  match Vchan.Port.of_string port with
  | `Error e -> return @@ `Error (`Unknown ("Vchan.Port.of_string " ^ e))
  | `Ok port ->
      Vc.client ~domid ~port () >>= fun t ->
      return @@ `Ok t


let connect ?log_f ?connstr () =
  let server_name = match connstr with
    | Some uri ->
       match Uri.host uri with Some h -> h | None -> "server"
    | None -> "server" in
  connect_server ~server_name >>= function
  | `Ok vchan ->
     let t = {vchan; msg_counter = 0} in
     request t ~func_name:"connect" ~args:[] >>= (function
     | `Ok _ -> return @@ `Ok t
     | `Error _ as e -> return e)
  | `Error _ as e -> return e


let configure_vm t config =
  let args = [string_of_config config] in
  request t ~func_name:"configure_vm" ~args >>= function
  | `Ok {results; _} ->
     let uuid = List.hd results in begin
     match Uuidm.of_string uuid with
     | Some id -> return @@ `Ok id
     | None -> return @@ `Error (`Unknown "Uuidm.of_string") end
  | `Error _ as e -> return e


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
  request t ~func_name:"lookup_vm_by_name" ~args >>= function
  | `Ok {results; _} ->
     let uuid = List.hd results in begin
     match Uuidm.of_string uuid with
     | Some id -> return @@ `Ok id
     | None -> return @@ `Error (`Unknown "Uuidm.of_string") end
  | `Error _ as e -> return e


let getop_by_uuid t func_name uuid fn =
  let args = [Uuidm.to_string uuid] in
  request t ~func_name ~args >>= function
  | `Ok {results; _} -> return @@ fn results
  | `Error _ as e -> return e


let get_state t uuid =
  let func_name = "get_state" in
  let fn = fun results ->
    let state =
      List.hd results
      |> Gk_vm_state.of_string in
     `Ok state
  in
  getop_by_uuid t func_name uuid fn


let get_name t uuid =
  let func_name = "get_name" in
  let fn = fun results ->
    let name = List.hd results in
    if name = "none" then `Ok None
    else `Ok (Some name)
  in
  getop_by_uuid t func_name uuid fn


let get_domain_id t uuid =
  let func_name = "get_domain_id" in
  let fn = fun results ->
    let id =
      List.hd results
      |> int_of_string in
    `Ok id
  in
  getop_by_uuid t func_name uuid fn


let get_mac t uuid =
  let func_name = "get_mac" in
  let fn = fun results ->
    let macs = List.map Macaddr.of_string_exn results in
    `Ok macs
  in
  getop_by_uuid t func_name uuid fn


let vm_op t func_name uuid ?(other_args = []) () =
  let args = (Uuidm.to_string uuid) :: other_args in
  request t ~func_name ~args >>= function
  | `Ok _ -> return @@ `Ok ()
  | `Error _ as e -> return e


let shutdown_vm t uuid =
  let func_name = "shutdown_vm" in
  vm_op t func_name uuid ()


let suspend_vm t uuid =
  let func_name = "suspend_vm" in
  vm_op t func_name uuid ()


let destroy_vm t uuid =
  let func_name = "destroy_vm" in
  vm_op t func_name uuid ()

let resume_vm t uuid =
  let func_name = "resume_vm" in
  vm_op t func_name uuid ()


let unpause_vm t uuid =
  let func_name = "unpause_vm" in
  vm_op t func_name uuid ()


let start_vm t uuid config =
  let func_name = "start_vm" in
  let other_args = [string_of_config config] in
  vm_op t func_name uuid ~other_args ()
