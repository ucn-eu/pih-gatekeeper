open V1_LWT
open Lwt
open Result

let log_src = Logs.Src.create "ucn.gatekeeper"
module Log = (val Logs.src_log log_src : Logs.LOG)
module Client = Cohttp_mirage.Client


module Tbl = struct

  module S = Data_store

  let approved_dir = ["approved"]
  let rejected_dir = ["rejected"]
  let pending_dir = ["pending"]
  let approved_key id domain = approved_dir @ [id; domain]
  let rejected_key id domain = rejected_dir @ [id; domain]
  let pending_key id domain = pending_dir @ [id; domain]

  let id_of_cert cert =
    let buf = Buffer.create 40 in
    X509.public_key cert
    |> X509.key_id
    |> Cstruct.hexdump_to_buffer buf
    |> fun _ ->
       let dump = Buffer.contents buf in
       Buffer.clear buf;
       String.iter (fun c ->
         if c <> ' ' && c <> '\n' then Buffer.add_char buf c
         else ()) dump;
       Buffer.contents buf

  let approve_access s ?src id domain =
    let old_key = pending_key id domain
    and new_key = approved_key id domain in
    S.remove s ?src old_key >>= function
    | Error _ as e -> return e
    | Ok () -> S.create s ?src new_key ""

  let reject_access s ?src id domain =
    let old_key = pending_key id domain
    and new_key = rejected_key id domain in
    S.remove s ?src old_key >>= function
    | Error _ as e -> return e
    | Ok () -> S.create s ?src new_key ""

  let check s cert domain =
    let id = id_of_cert cert in
    let key = approved_key id domain in
    let src = "gatekeeper", 0 in
    S.read s ~src key >>= function
    | Ok _ -> return_true
    | Error _ ->
       let key = rejected_key id domain in
       S.read s ~src key >>= function
       | Ok _ -> return_false
       | Error _ ->
          let key = pending_key id domain in
          S.create s ~src key "" >>= function
          | Error exn ->
             Log.err (fun f -> f "check update pending: %s" (Printexc.to_string exn));
             return_false
          | Ok () -> return_false


  let dispatch s ?src = function
    | "list" :: parent ->
       S.list s ?src ~parent () >>= (function
       | Error _ as e -> return e
       | Ok id_lst ->
          let json = Ezjsonm.(list string id_lst |> to_string) in
          return @@ Ok json)
    | "remove" :: c :: id :: [domain] ->
       let key =
         (if c = "approved" then approved_key
         else if c = "rejected" then rejected_key
         else if c = "pending" then pending_key
         else failwith ("no such category: " ^ c))
           id domain in
       S.remove s ?src key >>= (function
       | Error _ as e -> return e
       | Ok () -> return @@ Ok "")
    | op :: id :: [domain] ->
       let fn =
         if op = "approve" then approve_access
         else if op = "reject" then reject_access
         else failwith ("unknown operation: " ^ op) in
       fn s ?src id domain >>= (function
       | Error _ as e -> return e
       | Ok () -> return @@ Ok "")
    | _ as steps ->
       let path = String.concat "/" steps in
       let info = Printf.sprintf "dispatch unknown path: %s" path in
       Log.err (fun f -> f "%s" info);
       return @@ Error (Failure info)


  let persist s head ctx uri =
    let min = match !head with
      | None -> None
      | Some h -> Some [h] in
    S.export ?min s >>= function
    | Error e ->
       Log.err (fun f -> f "gatekeeper persist: %s" (Printexc.to_string e));
       return_unit
    | Ok None -> return_unit
    | Ok (Some (h, dump)) ->
       let body = Cohttp_lwt_body.of_string dump in
       Client.post ~ctx ~body uri >>= fun (res, _) ->
       let status =
         Cohttp.Response.status res
         |> Cohttp.Code.string_of_status in
       Log.info (fun f -> f "persist to %s: %s" (Uri.to_string uri) status);
       head := (Some h);
       return_unit


  let init_with_dump ctx (host, port) path store =
    let (/) d f = Printf.sprintf "%s/%s" d f in
    let uri = Uri.make ~scheme:"http" ~host ~port () in
    let list_uri = Uri.with_path uri (path / "list") in
    Client.get ~ctx list_uri >>= fun (res, body) ->
    let status = Cohttp.Response.status res in
    if status <> `OK then begin
      Log.err (fun f -> f "init_with_dump list: %s"
        (Cohttp.Code.string_of_status status));
      return_none end
    else
      Cohttp_lwt_body.to_string body >>= fun s ->
      return Ezjsonm.(s |> from_string |> value |> get_list get_string)
      >>= fun l ->
      Log.info (fun f -> f "init with %d files" (List.length l));
      let l =
        List.map int_of_string l
        |> List.sort compare |> List.map string_of_int in
      Lwt_list.fold_left_s (fun acc file ->
        let file_uri = Uri.with_path uri (path / file) in
        Client.get ~ctx file_uri >>= fun (res, dump) ->
        let s = Cohttp.Response.status res in
        if s <> `OK then return_none else
          Cohttp_lwt_body.to_string dump >>= fun dump ->
          S.import dump store >>= function
          | Error e ->
             Log.err (fun f -> f "error init_with_dump: %s"
               (Printexc.to_string e));
             return_none
          | Ok h ->
             Log.info (fun f -> f "init_with_dump: import %s" file);
             return_some h) None l


  let init ctx endp ~time () =
    let owner = "ucn.gatekeeper" in
    S.make ~owner ~time () >>= fun s ->
    init_with_dump ctx endp owner s >>= fun head ->
    return (s, ref head)

end


module Main
         (Stack: STACKV4)
         (Resolver: Resolver_lwt.S)
         (Conduit: Conduit_mirage.S)
         (Keys: KV_RO)
         (Clock: V1.CLOCK)= struct

  module Client = Cohttp_mirage.Client
  module TLS = Tls_mirage.Make(Stack.TCPV4)
  module Http = Cohttp_mirage.Server(Stack.TCPV4)
  module Https = Cohttp_mirage.Server(TLS)

  let headers =
    Cohttp.Header.of_list [
      "Access-Control-Allow-Origin", "*"]
  let empty_body = Cohttp_lwt_body.empty

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
        Gk_jitsu.start jitsu domain >>= fun domain_endp ->
        return @@ `Ok domain_endp)
        (function exn -> return @@ `Error ())


  let insert_nat_rule ctx (ip, port) req_endp dst_endp =
    let open Ezjsonm in
    let l = ["ip", fst req_endp |> string;
             "port", snd req_endp |> int;
             "dst_ip", fst dst_endp |> string;
             "dst_port", snd dst_endp |> int] in
    let body =
      dict l |> to_string
      |> Cohttp_lwt_body.of_string in
    let uri = Uri.make ~scheme:"http" ~host:ip ~port ~path:"insert" () in

    Log.info (fun f -> f "try to insert %s to %s" (dict l |> to_string) (Uri.to_string uri));
    Client.post ~ctx ~body ~headers uri >>= fun (res, body) ->
    Log.info (fun f -> f "returned");
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


  let https_handler (jitsu, br_endp, (s, min, persist_uri), ctx) (f, _) req body =
    let uri = Cohttp.Request.uri req in
    let path = Uri.path uri in
    let steps = Astring.String.cuts ~empty:false ~sep:"/" path in
    match steps with
    | "domain" :: _ ->
       peer_cert f >>= (function
       | None -> Https.respond ~status:`Unauthorized ~body:Cohttp_lwt_body.empty ()
       | Some cert ->
          let ip, port, domain = query_params req in
          Tbl.check s cert domain >>= function
          | true ->
            wakeup_domain jitsu domain >>= (function
            | `Error _ -> Lwt.fail (Failure "wakeup_domain")
            | `Ok dst_endp ->
               insert_nat_rule ctx br_endp (ip, port) dst_endp >>= function
               | `Error _ -> Lwt.fail (Failure "insert_nat_rule")
               | `Ok (ex_ip, ex_port) ->
                  let body =
                    let l = ["ip", ex_ip |> Ezjsonm.string;
                             "port", string_of_int ex_port |> Ezjsonm.string] in
                    let obj = Ezjsonm.dict l in
                    Ezjsonm.to_string obj
                    |> Cohttp_lwt_body.of_string in
                  Https.respond ~status:`OK ~body ())
          | false ->
             Tbl.persist s min ctx persist_uri >>= fun () ->
             Https.respond ~status:`Unauthorized ~body:Cohttp_lwt_body.empty ())


  let upgrade conf tls_conf f =
    TLS.server_of_flow tls_conf f >>= function
    | `Error e ->
       Log.err (fun f -> f "upgrade: %s" (TLS.error_message e));
       return_unit
    | `Eof ->
       Log.err (fun f -> f "upgrade: EOF");
       return_unit
    | `Ok f ->
       let t = Https.make ~callback:(https_handler conf) () in
       Https.(listen t f)


  let http_callback conf f =
    let handler ((s, min, persist_uri), ctx) _ req body =
      let uri = Cohttp.Request.uri req in
      let path = Uri.path uri in
      let steps = Astring.String.cuts ~empty:false ~sep:"/" path in
      match steps with
      | "op" :: steps ->
         let src = None in
         Tbl.dispatch s ?src steps >>= fun r ->
         Tbl.persist s min ctx persist_uri >>= fun () ->
         match r with
         | Ok "" -> Http.respond ~headers ~status:`OK ~body:empty_body ()
         | Ok json ->
            let headers = Cohttp.Header.add headers
              "content-type" "application/json" in
            let body = Cohttp_lwt_body.of_string json in
            Http.respond ~headers ~status:`OK ~body ()
         | Error exn ->
            let body = Printexc.to_string exn in
            Http.respond_error ~headers ~status:`Internal_server_error ~body () in
    let callback = handler conf in
    let t = Http.make ~callback () in
    Http.listen t f


  let time () = Clock.(
    let t = time () |> gmtime in
    Printf.sprintf "%d:%d:%d:%d:%d:%d"
      t.tm_year t.tm_mon t.tm_mday t.tm_hour t.tm_min t.tm_sec)

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

    Gk_jitsu.init Clock.time 200.0 Vm_configs.conf >>= fun jitsu ->
    wakeup_domain jitsu "bridge" >>= function
    | `Error _ -> Lwt.fail (Failure "can't start pih-bridge")
    | `Ok br_endp ->

    let persist_host = Key_gen.persist_host () |> Ipaddr.V4.to_string in
    let persist_port = Key_gen.persist_port () in
    let persist_uri = Uri.make ~scheme:"http" ~host:persist_host ~port:persist_port ~path:"ucn.gatekeeper" () in

    let ctx = Client.ctx resolver conduit in
    Tbl.init ctx (persist_host, persist_port) ~time () >>= fun (s, min) ->

    let tbl = s, min, persist_uri in
    Stack.listen_tcpv4 stack ~port:8443 (upgrade (jitsu, br_endp, tbl, ctx) tls_conf);
    Stack.listen_tcpv4 stack ~port:8080 (http_callback (tbl, ctx));
    Stack.listen stack
end
