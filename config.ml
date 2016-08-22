open Mirage

let addr = Ipaddr.V4.of_string_exn

let persist_host =
  let default = addr "10.0.0.1" in
  Key.create "persist-host" @@ Key.Arg.opt Key.Arg.ipv4 default (Key.Arg.info ["persist-host"])

let persist_port =
  let default = 10000 in
  Key.create "persist-port" @@ Key.Arg.opt Key.Arg.int default (Key.Arg.info ["persist-port"])

let keys = Key.[
  abstract persist_host;
  abstract persist_port; ]


let stack =
  if_impl Key.is_xen
    (direct_stackv4_with_default_ipv4 (netif "0"))
    (socket_stackv4 [Ipaddr.V4.any])


let resolver_impl = resolver_dns stack
let conduit_impl = conduit_direct stack

let tls = crunch "xen_cert"


let main =
  let deps = [abstract nocrypto] in
  foreign ~deps "Gatekeeper.Main" (stackv4 @-> resolver @-> conduit @-> kv_ro @-> clock @-> job)


let () =
  let libraries =
    [ "tls.mirage";
      "mirage-http";
      "mirage-xen";
      "irmin.mirage";
      "uuidm";
      "logs";
      "vchan";
      "vchan.xen";
      "pih-store"
    ] in
  register ~libraries ~keys "gatekeeper" [
    main $ stack $ resolver_impl $ conduit_impl $ tls $ default_clock;
  ]

