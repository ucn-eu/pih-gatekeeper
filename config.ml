open Mirage

let addr = Ipaddr.V4.of_string_exn

let persist_host =
  Key.create "persist-host" @@ Key.Arg.required Key.Arg.ipv4 (Key.Arg.info ["persist-host"])

let persist_port =
  Key.create "persist-port" @@ Key.Arg.required Key.Arg.int (Key.Arg.info ["persist-port"])

let keys = Key.[
  abstract persist_host;
  abstract persist_port; ]


let stack = generic_stackv4 (netif "0")

let resolver_impl = resolver_dns stack
let conduit_impl = conduit_direct stack

let tls = crunch "xen_cert"

let main =
  let deps = [abstract nocrypto] in
  foreign ~deps "Gatekeeper.Main" (stackv4 @-> resolver @-> conduit @-> kv_ro @-> pclock @-> job)


let () =
  let packages =
    [ "uuidm";
      "git";
      "mirage-git";
      "irmin";
      "tls"; ] in
  let libraries =
    [ "uuidm";
      "irmin";
      "irmin.git";
      "mirage-http";
      "pih-store";
      "tls.mirage"; ] in
  register ~keys ~packages ~libraries "gatekeeper" [
    main $ stack $ resolver_impl $ conduit_impl $ tls $ default_posix_clock;
  ]

