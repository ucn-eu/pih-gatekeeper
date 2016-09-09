# pih-gatekeeper

Functionalities that should be provided by this unikernel *(yeah, that's right, this is yet another unikernel)*

- [x] check the credentials of client (hopefully by tls certificates), see if they are allowed to access the data under request
- [x] check the states , boot up if necessary (through jitsu), the corresponding unikernels for clients
- [x] insert/remove new address translation rules into the pih-bridge, so that client could acces the data-holding unikernels behind it


### Basic Design

The gatekeeper is running as another unikernel on xen. It manages the life cycles of the [pih-bridge] and also [the other unikernels] that hold users' data behind the bridge. To achieve this, the repo adapts a big part from [jitsu], and uses its libxl backend. As the libxl backend has Unix dependency, it is put in the Dom0, and all the operations about unikernels will be proxied to Dom0 through rpc implemented on [vchan]. So to set up the gatekeeper or test it, basically there are two parts, one for the libxl jitsu daemon in Dom0, the other for the gatekeeper unikernel.


### Build and Run 
#### jitsu in Dom0
There is a script `libxld.sh` you can use to compile the source files for jitsu, running
```bash
$ ./libxld.sh build
$ sudo modprobe xen-gntalloc 
$ sudo ./libxld
```
will get you a jitsu instance up in Dom0. You will need ocaml compiler and several other ocaml libraries to make this work, referring to `PKG` in the script would be of some help.

#### gatekeeper unikernel
It tries to read configurations of other managed unikernels from a source file with the name `vm_configs.ml`. While testing, a file with the following content and format is used:
```ocaml
let conf = 
  [ [ "name", "bridge";
      "kernel", "/path/to/mir-pih-bridge.xen";
      "memory", "128000";
      "ip", "10.0.0.3";
      "port", "8080";
      "nic", "br0";
      "nic", "br0";
      "nic", "br1";
      "ttl", "300"; ];
    [ "name", "review";
      "kernel", "/path/to/mir-review.xen";
      "memory", "64000";
      "ip", "192.168.252.11";
      "port", "8443";
      "nic", "br1";
      "ttl", "120"; ];
    [ "name", "catalog";
    　"kernel", "/path/to/mir-catalog.xen";
    　"memory", "64000";
    　"ip", "192.168.252.12";
    　"port", "8443";
    　"nic", "br1";
    　"ttl", "120"; ]]
```
Basically, the fields `name`, `kernel`, `memory`, `ip`, `port`, `nic` are necessary. The gatekeeper needs `ip` and `port` to insert new translation entry inside [pih-bridge], it needs `kernel`, `memory` and `nic` to tell [jitsu] where to find the kernel and how to start it.

The gatekeeper authenticates third parties by checking their client certificates which are extracted from tls sessions. So there is a corresponding part in the gatekeeper that maks sure it can understand the tls protocol, and this part requires a directory to contain the server tls certificates when building the unikernel. As seeing from the [config.ml], the default directory name is `xen_cert`, but it could be changed as you need.

Another point worth mentioning is that the gatekeeper will persist its runtime configuration to a data server. These data contain information about which client is approved or disallowed to access data from a specific domain. The data server is an irmin server listenning on a specific port. [Here](https://github.com/sevenEng/pih-store-instance/blob/master/persist/persist_server/main.ml) is a simple snnipet about how to set up the server. The endpoint information of this data server is required during configuration phase through the `mirage config` command. You can see this in [build.sh] and change them as needed.
After you have every part in place, to build and run the gatekeeper, you can do:
```bash
./build.sh
sudo xl create -c gatekeeper.xl
```
### Communication Protocol
Basically, there are three steps when some external client wants to access the data through the gatekeeper and behind the bridge. Assuming the gatekeeper has an ip address of `10.0.0.254` and listens on the port `8443`, and the data it wants to access are served at the domain `review`, the very **first** step would be issuing a request to
```
https://10.0.0.254:8443/domain
```
with the query string: `ip=10.0.0.1&domain=review`. This is to say that as an external client, I want to access the data within `review`, and I would issue requests from the ip address `10.0.0.1`later when accessing the data. And please note that this has to be an tls session with client certificate attached, the owner of the data will approve/disallow this request based on it. And **secondly**, the owner has to make the decision about this request, we have [a web interface] to do this in the demo, this part has no concern as with the client. Then the **third** step would be the client issuing the same request to the same endpoint again.

Without the owner's approval, the request will return `401 unauthorized`, however if the data's owner approves this request, it will return `200 OK` and a json object in the body specifying the endpoint that the client could contact to access the data in the store. The object would have two fields `ip` and `port` respectively. This endpoint is on the external interface of the [pih-bridge], it will translate the traffic automatically for you if you have got the right to access the data. Different domains could have different REST APIs, these are built into the data stores that hold data from different sources, but the procedures of client authentication before that are the same for all the domains and all the clients.



[pih-bridge]:https://github.com/ucn-eu/pih-bridge
[the other unikernels]:https://github.com/sevenEng/pih-store-instance
[jitsu]:https://github.com/mirage/jitsu
[vchan]:https://github.com/mirage/ocaml-vchan
[config.ml]:https://github.com/sevenEng/pih-gatekeeper/blob/master/config.ml#L25
[build.sh]:https://github.com/sevenEng/pih-gatekeeper/blob/master/build.sh#L4
[a web interface]:https://github.com/sevenEng/ucn-demo
