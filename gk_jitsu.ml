(*
 * Copyright (c) 2014-2015 Magnus Skjegstad <magnus@skjegstad.com>
 * Copyright (c) 2016      Qi Li            <ql272@cl.cam.ac.uk>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open Lwt

let src_log = Logs.Src.create "gk.jitsu"
module Log = (val Logs.src_log src_log : Logs.LOG)

let or_warn_lwt msg f =
  catch (fun () -> f ()) (function
  | Failure m ->
     Log.warn (fun f -> f "Warning: %s\nReceived exception: %s" msg m);
     return_unit
  | e ->
     Log.warn (fun f -> f "Warning: Unhandled exception: %s" (Printexc.to_string e));
     return_unit)

let or_abort f =
  try f () with
  | Failure m ->
     Log.err (fun f -> f "Fatal error: %s" m); exit 1


module Make
    (Vm_backend : Gk_backends.VM_BACKEND)
    (Storage_backend : Gk_backends.STORAGE_BACKEND) = struct

  type t = {
    storage     : Storage_backend.t;
    log         : string -> unit;              (* Log function *)
    vm_backend  : Vm_backend.t;                  (* Backend type *)
    time        : unit -> float;
  }

  let create vm_backend time () =
    let log s = Log.info (fun f -> f "%s" s) in
    let storage_logger s = Log.info (fun f -> f "%s %s" "storage_backend" s) in
    Storage_backend.create ~log:storage_logger () >>= fun storage ->
    Lwt.return {
      storage;
      log;
      vm_backend;
      time;
    }

  let string_of_error e =
    match e with
    | `Invalid_config s -> (Printf.sprintf "Invalid config: %s" s)
    | `Not_found -> "Not found"
    | `Not_supported -> "Not supported"
    | `Disconnected s -> (Printf.sprintf "Disconnected: %s" s)
    | `Unable_to_connect s -> (Printf.sprintf "Unable to connect: %s" s)
    | `Unknown s -> (Printf.sprintf "%s" s)
    | `Server s -> (Printf.sprintf "Server: %s" s)

  let or_vm_backend_error msg fn t =
    fn t >>= function
    | `Error e -> Lwt.fail (Failure (Printf.sprintf "%s: %s" (string_of_error e) msg))
    | `Ok t -> return t

  let get_running_vm_name t vm_uuid =
    or_vm_backend_error "Unable to get VM name from backend" (Vm_backend.get_name t.vm_backend) vm_uuid >>= fun vm_name ->
    match vm_name with
    | None -> Lwt.return "<unknown>"
    | Some s -> Lwt.return s

  let get_vm_state t vm_uuid =
    or_vm_backend_error "Unable to get VM state from backend" (Vm_backend.get_state t.vm_backend) vm_uuid

  let stop_vm t vm_uuid =
    get_vm_state t vm_uuid >>= fun vm_state ->
    match vm_state with
    | Gk_vm_state.Running ->
      get_running_vm_name t vm_uuid >>= fun vm_name ->
      let uuid_s = Uuidm.to_string vm_uuid in
      Storage_backend.get_stop_mode t.storage ~vm_uuid >>= fun stop_mode ->
      begin match stop_mode with
        | Gk_vm_stop_mode.Unknown -> t.log (Printf.sprintf "Unable to stop VM %s (%s). Unknown stop mode requested." uuid_s vm_name);
          Lwt.return_unit
        | Gk_vm_stop_mode.Shutdown -> t.log (Printf.sprintf "VM shutdown: %s (%s)" uuid_s vm_name);
          or_vm_backend_error "Unable to shutdown VM" (Vm_backend.shutdown_vm t.vm_backend) vm_uuid
        | Gk_vm_stop_mode.Suspend  -> t.log (Printf.sprintf "VM suspend: %s (%s)" uuid_s vm_name);
          or_vm_backend_error "Unable to suspend VM" (Vm_backend.suspend_vm t.vm_backend) vm_uuid
        | Gk_vm_stop_mode.Destroy  -> t.log (Printf.sprintf "VM destroy: %s (%s)" uuid_s vm_name) ;
          or_vm_backend_error "Unable to destroy VM" (Vm_backend.destroy_vm t.vm_backend) vm_uuid
      end
    | Gk_vm_state.Off
    | Gk_vm_state.Paused
    | Gk_vm_state.Suspended
    | Gk_vm_state.Unknown -> Lwt.return_unit (* VM already stopped or nothing we can do... *)

  let get_vm_name t vm_uuid =
    Storage_backend.get_vm_config t.storage vm_uuid >>= fun config ->
    return @@ Hashtbl.find config "name"

  let start_vm t vm_uuid =
    get_vm_state t vm_uuid >>= fun vm_state ->
    get_vm_name t vm_uuid >>= fun vm_name ->
    let msg = Printf.sprintf "Starting VM %s (name=%s, state=%s)"
      (Uuidm.to_string vm_uuid) vm_name (Gk_vm_state.to_string vm_state) in
    t.log msg;
    let update_stats () =
      Storage_backend.set_start_timestamp t.storage ~vm_uuid (t.time ()) >>= fun () ->
      Storage_backend.inc_total_starts t.storage ~vm_uuid
    in
    match vm_state with
    | Gk_vm_state.Running -> (* Already running, exit *)
      t.log " --! VM is already running";
      Lwt.return_unit
    | Gk_vm_state.Suspended ->
      t.log " --> resuming VM...";
      or_vm_backend_error "Unable to resume VM" (Vm_backend.resume_vm t.vm_backend) vm_uuid >>= fun () ->
      update_stats ()
    | Gk_vm_state.Paused ->
      t.log " --> unpausing VM...";
      or_vm_backend_error "Unable to unpause VM" (Vm_backend.unpause_vm t.vm_backend) vm_uuid >>= fun () ->
      update_stats ()
    | Gk_vm_state.Off ->
      t.log " --> creating VM...";
      Storage_backend.get_vm_config t.storage ~vm_uuid >>= fun config ->
      or_vm_backend_error "Unable to create VM" (Vm_backend.start_vm t.vm_backend vm_uuid) config >>= fun () ->
      update_stats ()
    | Gk_vm_state.Unknown ->
      t.log " --! VM cannot be started from this state.";
      Lwt.return_unit


  (* add vm to be monitored by jitsu *)
  let add_vm t ~vm_ip ~domain_name ~domain_ttl ~vm_config =
    let vm_stop_mode = Gk_vm_stop_mode.Destroy in
    let response_delay = 0. in
    let wait_for_key = None in
    let use_synjitsu = false in
    let fn = Vm_backend.configure_vm t.vm_backend in
    or_vm_backend_error "Unable to configure VM" fn vm_config >>= fun vm_uuid ->
    Storage_backend.add_vm t.storage ~vm_uuid ~vm_ip ~vm_stop_mode ~response_delay ~wait_for_key ~use_synjitsu ~vm_config >>= fun () ->
    Storage_backend.add_vm_domain t.storage ~vm_uuid ~domain_name ~domain_ttl


  (* iterate through t.name_table and stop VMs that haven't received
     requests for more than ttl*2 seconds *)
  let stop_expired_vms t =
    Storage_backend.get_vm_list t.storage >>= fun vm_uuid_list ->
    (* Check for expired names *)
    Lwt_list.filter_map_s (fun vm_uuid ->
        get_vm_state t vm_uuid >>= fun vm_state ->
        match vm_state with
        | Gk_vm_state.Off
        | Gk_vm_state.Paused
        | Gk_vm_state.Suspended
        | Gk_vm_state.Unknown -> Lwt.return_none (* VM already stopped/paused/crashed.. *)
        | Gk_vm_state.Running ->
          (* Get list of DNS domains that have been requested (has requested timestamp != None) and has NOT expired (timestamp is younger than ttl*2) *)
          Storage_backend.get_vm_domain_name_list t.storage ~vm_uuid >>= fun domain_name_list ->
          Lwt_list.filter_map_s (fun domain_name ->
              Storage_backend.get_last_request_timestamp t.storage ~vm_uuid ~domain_name >>= fun r ->
              match r with
              | None -> Lwt.return_none (* name not requested, can't expire *)
              | Some last_request_ts ->
                let current_time = t.time () in
                Storage_backend.get_ttl t.storage ~vm_uuid ~domain_name >>= fun ttl ->
                if (current_time -. last_request_ts) <= (float_of_int (ttl * 2)) then
                  Lwt.return (Some domain_name)
                else
                  Lwt.return_none
            ) domain_name_list
          >>= fun unexpired_domain_names ->
          if (List.length unexpired_domain_names) > 0 then (* If VM has unexpired DNS domains, DON'T terminate *)
            Lwt.return_none
          else
            Lwt.return (Some vm_uuid) (* VM has no unexpired DNS domains, can be terminated *)
      ) vm_uuid_list >>= fun expired_vms ->
    Lwt_list.iter_s (stop_vm t) expired_vms (* Stop expired VMs *)


  let uuid_of_name t domain_name =
    Storage_backend.get_vm_list t.storage >>= fun vm_uuid_list ->
    Lwt_list.filter_s (fun uuid ->
      get_vm_name t uuid >>= fun name ->
      if name = domain_name then return_true
      else return_false) vm_uuid_list >>= function
    | [] ->
       let m = Printf.sprintf "no vm's name is %s" domain_name in
       Log.err (fun f -> f "%s" m);
       return_none
    | vm_uuid :: _ ->
       return_some vm_uuid
end


module Context = struct let v () = return None end
module Store_Maker = Irmin_mirage.Irmin_git.Memory(Context)(Git.Inflate.None)

module Vm_backend = Gk_libxl_proxy_backend
module Storage_backend = Gk_irmin_backend.Make(Store_Maker)
module Jitsu = Make(Vm_backend)(Storage_backend)


let rec maintenance_thread t timeout =
  OS.Time.sleep timeout >>= fun () ->
  or_warn_lwt "Unable to stop expired VMs" (fun () -> Jitsu.stop_expired_vms t) >>= fun () ->
  maintenance_thread t timeout


let init time timeout conf =
  let add_with_config t conf = (
    let vm_config = Hashtbl.create (List.length conf) in
    (* Use .add to support multiple values per parameter name *)
    let () = List.iter (fun (k,v) -> Hashtbl.add vm_config k v) conf in
    let vm_ip =
      try `Ok (Hashtbl.find vm_config "ip" |> Ipaddr.of_string_exn)
      with e -> `Error (Printf.sprintf "vm_ip %s" (Printexc.to_string e))
    in
    let domain_name =
      try `Ok (Hashtbl.find vm_config "name")
      with e -> `Error (Printf.sprintf "domain_name %s" (Printexc.to_string e))
    in
    let domain_ttl =
      try `Ok (Hashtbl.find vm_config "ttl" |> int_of_string)
      with e -> `Error (Printf.sprintf "domain_ttl %s" (Printexc.to_string e))
    in
    match vm_ip, domain_name, domain_ttl with
    | `Error e, _, _
    | _, `Error e, _
    | _, _, `Error e -> Lwt.fail (Failure e)
    | `Ok vm_ip, `Ok domain_name, `Ok domain_ttl ->
        match (Ipaddr.to_v4 vm_ip) with
        | None ->
           let msg = Printf.sprintf "Ipaddr.to_v4 %s" (Ipaddr.to_string vm_ip) in
           Log.warn (fun f -> f "%s" msg);
           Lwt.fail (Failure msg)
        | Some vm_ip ->
            or_abort (fun () -> Jitsu.add_vm t ~vm_ip ~domain_name ~domain_ttl ~vm_config))
  in

  Vm_backend.connect () >>= function
  | `Error e ->
     Log.err (fun f -> f "Vm_backend.connect %s" (Jitsu.string_of_error e));
     Lwt.fail (Failure "init")
  | `Ok backend_t ->
     Jitsu.create backend_t time () >>= fun t ->
     Lwt_list.iter_s (add_with_config t) conf >>= fun () ->
     (*Lwt.async (fun () -> maintenance_thread t timeout);*)
     return t


let start t domain_name =
  Jitsu.uuid_of_name t domain_name >>= function
  | None -> Lwt.fail (Failure ("no such domain name " ^ domain_name))
  | Some vm_uuid ->
     Jitsu.start_vm t vm_uuid >>= fun () ->
     Storage_backend.get_ip t.Jitsu.storage ~vm_uuid >>= function
     | None ->
        let m = Printf.sprintf "no ip for %s" domain_name in
        Log.err (fun f -> f "%s" m);
        Lwt.fail (Failure m)
     | Some ip ->
     Storage_backend.get_vm_config t.Jitsu.storage ~vm_uuid >>= fun tbl ->
     let port =
       if not (Hashtbl.mem tbl "port") then 8080
       else Hashtbl.find tbl "port" |> int_of_string in
     return port >>= fun port ->
     return (Ipaddr.V4.to_string ip, port)


let get_state t domain_name =
  Jitsu.uuid_of_name t domain_name >>= function
  | None -> return "ERR: no such domain"
  | Some vm_uuid ->
     Jitsu.get_vm_state t vm_uuid
     >|= Gk_vm_state.to_string


