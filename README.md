# pih-gatekeeper

Functionalities that should be provided by this unikernel *(yeah, that's right, this is yet another unikernel)*

- [x] check the credentials of client (hopefully by tls certificates), see if they are allowed to access the data under request
- [x] check the states , boot up if necessary (through jitsu), the corresponding unikernels for clients
- [x] insert/remove new address translation rules into the pih-bridge, so that client could acces the data-holding unikernels behind it


### Basic Design

The gatekeeper is running as another unikernel on xen. It manages the life cycles of the bridge and also the other unikernels that hold users' data behind the bridge. To achieve this, the repo adapts a big part from jitsu, and uses its libxl backend. As the libxl backend has Unix dependency, it is put in the Dom0, and all the operations about unikernels will be proxied to Dom0 through rpc implemented on vchan. So to set up the gatekeeper or test it, basically there are two parts, one for the libxl jitsu daemon in Dom0, the other for the gatekeeper unikernel.


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

### Protocol
