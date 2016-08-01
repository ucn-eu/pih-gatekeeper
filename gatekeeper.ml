open V1_LWT
open Lwt

let log_src = Logs.Src.create "ucn.gatekeeper"
module Log = (val Logs.src_log log_src : Logs.LOG)

module Main
         (Stack: STACKV4)
         (Keys: KV_RO)
         (Clock: V1.CLOCK)= struct

  module TLS = Tls_mirage.Make(Stack.TCPV4)
  module Http = Cohttp_mirage.Server(TLS)

  let headers =
    Cohttp.Header.of_list [
      "Access-Control-Allow-Origin", "*"]

  let handler (f, _) req body =
    match TLS.epoch f with
    | `Error ->
       Http.respond_error ~status:`Unauthorized ~body:"" ()
    | `Ok data ->
       let log =
         Tls.Core.sexp_of_epoch_data data
         |> Sexplib.Sexp.to_string in
       Log.app (fun f -> f "%s" log);
       Http.respond ~status:`OK ~body:Cohttp_lwt_body.empty ()


  let upgrade tls_conf f =
    TLS.server_of_flow tls_conf f >>= function
    | `Error e ->
       Log.err (fun f -> f "upgrade: %s" (TLS.error_message e));
       return_unit
    | `Eof ->
       Log.err (fun f -> f "upgrade: EOF");
       return_unit
    | `Ok f ->
       let t = Http.make ~callback:handler () in
       Http.(listen t f)


  let tls_init kv =
    let module X509 = Tls_mirage.X509(Keys)(Clock) in
    X509.certificate kv `Default >>= fun cert ->
    X509.authenticator kv `CAs >>= fun authenticator ->
    let conf = Tls.Config.server ~certificates:(`Single cert) ~authenticator () in
    Lwt.return conf


  let start stack kv _ _ =
    tls_init kv >>= fun tls_conf ->
    Stack.listen_tcpv4 stack ~port:4433 (upgrade tls_conf);
    Stack.listen stack
end
