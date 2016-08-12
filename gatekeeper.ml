open V1_LWT
open Lwt

let log_src = Logs.Src.create "ucn.gatekeeper"
module Log = (val Logs.src_log log_src : Logs.LOG)

module Tbl = struct
  type t = (X509.t, string list) Hashtbl.t

  let init () : t = Hashtbl.create 7

  let check t cert domain =
    let l = Hashtbl.find t cert in
    List.mem domain l

  let check_always_true t cert domain =
    let key_id cert =
      let len = 6 in
      let buf = Buffer.create len in
      X509.public_key cert
      |> X509.key_id
      |> fun cst -> Cstruct.sub cst 0 len
      |> Cstruct.hexdump_to_buffer buf
      |> fun () -> Buffer.contents buf in
    Log.info (fun f -> f "check true: %s for %s" (key_id cert) domain);
    true
end


module Main
         (Stack: STACKV4)
         (Resolver: Resolver_lwt.S)
         (Conduit: Conduit_mirage.S)
         (Keys: KV_RO)
         (Clock: V1.CLOCK)= struct

  module Client = Cohttp_mirage.Client
  module TLS = Tls_mirage.Make(Stack.TCPV4)
  module Http = Cohttp_mirage.Server(TLS)

  let headers =
    Cohttp.Header.of_list [
      "Access-Control-Allow-Origin", "*"]

  let peer_cert f = match TLS.epoch f with
    | `Error -> return None
    | `Ok data ->
       let log =
         Tls.Core.sexp_of_epoch_data data
         |> Sexplib.Sexp.to_string in
       Log.debug (fun f -> f "%s" log);
       return data.Tls.Core.peer_certificate


  let query_params req =
    let uri = Cohttp.Request.uri req in
    let params = Uri.query uri in
    let ip = List.assoc "ip" params |> List.hd in
    let port = List.assoc "port" params |> List.hd |> int_of_string in
    let domain = List.assoc "domain" params |> List.hd in
    (ip, port, domain)


  (* start NAT and coressponding unikernels for [domain] *)
  let wakeup_domain jitsu domain =
      Lwt.catch (fun () ->
        Gk_jitsu.start jitsu domain >>= fun endp ->
        return @@ `Ok (endp, endp))
        (function exn -> return @@ `Error ())


  let insert_nat_rule ctx (ip, port) req_endp dst_endp =
    let open Ezjsonm in
    let l = ["ip", fst req_endp |> string;
             "port", snd req_endp |> string_of_int |> string;
             "dst_ip", fst dst_endp |> string;
             "dst_port", snd dst_endp |> string_of_int |> string] in
    let body =
      dict l |> to_string
      |> Cohttp_lwt_body.of_string in
    let uri = Uri.make ~scheme:"http" ~host:ip ~port ~path:"insert" () in

    Client.post ~ctx ~body ~headers uri >>= fun (res, body) ->
    let status = Cohttp.Response.status res in
    if status <> `OK then begin
      Cohttp_lwt_body.to_string body >>= fun b ->
      Log.err (fun f -> f "insert_nat_rule %s" b);
      return (`Error ()) end
    else
      Cohttp_lwt_body.to_string body >>= fun str ->
      from_string str
      |> value
      |> get_dict
      |> fun obj ->
         let ip = List.assoc "ip" obj |> get_string in
         let port = List.assoc "port" obj |> get_int in
         return (`Ok (ip, port))


  let handler (jitsu, tbl, ctx) (f, _) req body =
    peer_cert f >>= function
    | None -> Http.respond ~status:`Unauthorized ~body:Cohttp_lwt_body.empty ()
    | Some cert ->
      let ip, port, domain = query_params req in
      if Tbl.check_always_true tbl cert domain then
        wakeup_domain jitsu domain >>= function
        | `Error _ -> Lwt.fail (Failure "wakeup_domain")
        | `Ok (nat_endp, dst_endp) ->
        insert_nat_rule ctx nat_endp (ip, port) dst_endp >>= function
        | `Error _ -> Lwt.fail (Failure "insert_nat_rule")
        | `Ok (ex_ip, ex_port) ->
           let body =
             let l = ["ip", ex_ip |> Ezjsonm.string;
                      "port", string_of_int ex_port |> Ezjsonm.string] in
             let obj = Ezjsonm.dict l in
             Ezjsonm.to_string obj
             |> Cohttp_lwt_body.of_string in
           Http.respond ~status:`OK ~body ()
      else
        Http.respond ~status:`Unauthorized ~body:Cohttp_lwt_body.empty ()


  let upgrade conf tls_conf f =
    TLS.server_of_flow tls_conf f >>= function
    | `Error e ->
       Log.err (fun f -> f "upgrade: %s" (TLS.error_message e));
       return_unit
    | `Eof ->
       Log.err (fun f -> f "upgrade: EOF");
       return_unit
    | `Ok f ->
       let t = Http.make ~callback:(handler conf) () in
       Http.(listen t f)


  let tls_init kv =
    let module X509 = Tls_mirage.X509(Keys)(Clock) in
    X509.certificate kv `Default >>= fun cert ->
    X509.authenticator kv `CAs >>= fun authenticator ->
    let conf = Tls.Config.server ~certificates:(`Single cert) ~authenticator () in
    Lwt.return conf


  let async_hook = function
    | exn -> Log.err (fun f -> f "async_hook %s" (Printexc.to_string exn))


  let start stack resolver conduit kv _ _ =
    let () = Lwt.async_exception_hook := async_hook in
    tls_init kv >>= fun tls_conf ->

    Gk_jitsu.init Clock.time 10.0 Vm_configs.conf >>= fun jitsu ->

    let tbl = Tbl.init () in
    let ctx = Client.ctx resolver conduit in
    Stack.listen_tcpv4 stack ~port:4433 (upgrade (jitsu, tbl, ctx) tls_conf);
    Stack.listen stack
end
