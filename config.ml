open Mirage

let stack =
  if_impl Key.is_xen
    (direct_stackv4_with_default_ipv4 (netif "0"))
    (socket_stackv4 [Ipaddr.V4.any])

let keys = generic_kv_ro "cert"

let main =
  let deps = [abstract nocrypto] in
  foreign ~deps "Gatekeeper.Main" (stackv4 @-> kv_ro @-> clock @-> job)

let () =
  let libraries = ["tls.mirage"; "mirage-http"] in
  register ~libraries "gatekeeper" [
    main $ stack $ keys $ default_clock;
  ]

