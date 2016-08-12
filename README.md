## pih-gatekeeper

functionalities that should be provided by this unikernel *(yeah, that's right, this is yet another unikernel)*, iiuc

- [x] check the credentials of client (hopefully by tls certificates), see if they are allowed to access the data under request
- [x] check the states , boot up if necessary (through jitsu), the corresponding unikernels for clients
- [ ] insert new address translation rules into the pih-bridge, so that client could acces the data-holding unikernels behind it
