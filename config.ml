open Mirage

let main =
  let deps = [abstract nocrypto] in
  foreign ~deps "Gatekeeper.Main" (stackv4 @-> resolver @-> conduit @-> kv_ro @-> clock @-> job)


let stack =
  if_impl Key.is_xen
    (direct_stackv4_with_default_ipv4 (netif "0"))
    (socket_stackv4 [Ipaddr.V4.any])


let resolver_impl = resolver_dns stack
let conduit_impl = conduit_direct stack

let keys = generic_kv_ro "cert"


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
    ] in
  register ~libraries "gatekeeper" [
    main $ stack $ resolver_impl $ conduit_impl $ keys $ default_clock;
  ]

