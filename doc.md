## Note

This is the documentation of the whole test/demo process.
It includes not only the part of [pih-gatekeeper], but also that of [pih-bridge] and those of [data serving unikernels].
As different components interact with each other so closely in this project,
it's easier and clearer to show a whole picture here rather than break it up and scatter the pieces into multiple repositories.
You may find duplications here with some other content in related repositories, but the aim of the file is to ensure that you could have a whole overview of the demostration process, so the duplications are difficult to exclude.

Here we suppose the local file system has a layout like the following:
```
  ./
  ../
  pih-bridge/
  pih-gatekeeper/
  pih-store-instance/
  ucn-demo/
  muse/
```
Each of them is a git clone of the corresponding git repo. The following steps all have the assumption that you have built every component successfully. For building instructions, you could find them easily from the `README.md` in each git repo.


#### Start Gatekeeper and Bridge

Firstly, start jitsu, persistence processes, and the muse system, then configure two network bridges:
```bash
#### jitsu ####

$ cd pih-gatekeeper
$ sudo modprobe xen-gntalloc
$ sudo ./libxld

#### persistence ####

$ cd ../pih-store-instance/persist/ucn.bak
$ ./script init
$ ./script start

#### muse ####

$ cd ../../catalog
$ ./start

#### network bridge ####

$ cd ../../pih-bridge
$ sudo ./net_conf.sh
```
The persistence processes are started after we create new directories for each of the data source. You may have multiple empty directories after running `./script init`. When the unikernel starts to serve data, all the data and operations will be persist in its own directory.

Then you could start the gatekeeper unikernel using `xl` command
```bash
$ cd ../../pih-gatekeeper
$ sudo xl create -c gatekeeper.xl
```
If you have multiple terminals running at the same time, you could see lots of output from the jitsu's terminal, basically they are from invocation of new unikernels. This should get you two unikernels up and running, `gatekeeper` and `bridge`. To check this, running
```base
<Ctrl - ]>
$ sudo xl list
```
should give an output similar to:

![][start gatekeeper]

The `Mem` column indicates the memory space that one unikernel consumes, it should conform to the value you've set in the file `vm_configs.ml` from directory `pih-gatekeeper`. For now, we have a running gatekeeper and a running bridge, next we could try to issue some requests to gain the access to some data from the owner.


#### Apply for the Right to Access Data
Following the procedures specified [here](https://github.com/sevenEng/pih-gatekeeper#communication-protocol), we should first issue some requests to the gatekeeper. Assuming the network configuration for the local system and unikernels stay default, and we want to access the data of movie reviews and data catalogue, then we could use `curl` to do:
```bash
curl -i --cert <your client certificate> --cacert <CA certificate> "https://10.0.0.254:8443/domain?ip=10.0.0.1&domain=review"
curl -i --cert <your client certificate> --cacert <CA certificate> "https://10.0.0.254:8443/domain?ip=10.0.0.1&domain=catalog"
```
The option `--cacert` is used here because self-signed server certificates are used to allow the servers to communicate in tls sessions. After issuing these requests, you should see the information also  exist in gatekeeper's own persistence directory:

![][apply access]

The hexadecimal string in the picture is extracted from the client certificate, it serves as the unique identifier to the client who wishes to access the data within domains `review` and `catalog`. It stays under `pending` subdirectory until the data owner makes the decision about the data access application.

To deal with this client application, we use a web interface. To start the server:
```bash
$ cd ucn-demo
$ ./server &
```
In your favorite browser, type in the link where the server listens on, navigate to the `gatekeeper` tab, click the button to pull the up-to-date information from gatekeeper, you should be able to see the pending requets:

![][pending requests]

The three buttons on the right side of each entry represent different operations an owner could carry out on these requests, to ignore it, to reject it, or to approve it. Click any one of them will change the configurations of the gatekeeper immediately. Let's try approve these two requests, and now the two entries should appear intead under the `Approved Data Consumers` section. Now we go back to the terminal and reissue the same requests, you should get the output as following:

![][approved access]

Instead of getting `401`, now we have status code `200` and json object in the response body. The json object specifies the address on the bridge that the external could contact to operate on the data. The concrete port numbers you get will very probably differ from the ones above, cause the bridge allocates new port numbers randomly. After this you could peek into the gatekeeper and bridge configurations (by peeking into its persistence direcotries), and see what really happens there:

![][approved gk bridge]

Noticed that the subdirectory of the requests has been moved from under `pending` to `approved`, and there are also information about which bridge external endpoint should a client use to contact the desired domain behind it. From the specific configuration showed in the picture above, for domain `catalog`, one should try to contact `10.0.0.2:38246`. This is consistent with what we've got from the response by `curl`ing the gatekeeper.

Also another point worth noticed is about the bridge, in its persistence direcotry we find a folder named `entries_inserted`, all the inserted translation rules by gatekeeper could be found here, the files inside this folder contain in their content the address information of each requested domain behind the bridge. This information is given by the gatekeeper, and further from `vm_configs.ml`. After the second time that we `curl` gatekeeper to apply the access right, the gatekeeper confirms that the client has been approved, and invokes requested domains using the configurations from the `vm_configs.ml` file. If started successfully, the address information of the domain will be given to the bridge and let the bridge allocate a new endpoint on the external face to allow the traffic to the requested domain. For what it's worth, right now if you run `xl list`, you should see two more domains, `review` and `catalog` respectively. They are brought up by gatekeeper waiting for requests from outside world. Here are some basic commands you could use to test this:
```bash
$ curl -i -k https://10.0.0.2:45141/list
$ curl -i -k -X POST -d '{"id":"0", "title":"hello", "rating":"5", "comment":"great"}' https://10.0.0.2:45141/create/id0
$ curl -i -k https://10.0.0.2:45141/read/id0

$ curl -i -k https://10.0.0.2:45141/list
$ curl -i -k https://10.0.0.2:45141/delete/id0
$ curl -i -k https://10.0.0.2:45141/list
```

#### Allow the Web Interface to Access Data
So far, only the approved client could access the data through allocated address on the bridge. To extend the functionalities of the web interface, we need to let the web interface to be able to talk to the domains behind the bridge too. To make this possible, we are going to make use of the persisten directoires of the birdge.

Remeber that we could see the runtime configurations of the bridge from its persistence directory. Thanks to the underlying data store based on [irmin], it's also possble to change the runtime configurations from the directory. It provides two-way mapping between the content inside the directory and the runtime configurations of the bridge. Once we change the direcotry, the bridge could pick it up dynamically from the unikernel inside other domUs.

To achieve this, we should add new translations rules into `entries_inserted` directory. Following the format that gatekeeper stores its configuration, we could allocate some ports manually for the web interface. By manually, I mean adding new files with correct file name and content. From the above steps, inside `entries_inserted`, we have two files, one for the domain `review`, with the name `10.0.0.1_10.0.0.2:45141` and content `192.168.252.11:8443`, the other one for the domain `catalog`, with the name `10.0.0.1_10.0.0.2:38246` and content `192.168.252.12:8443`. So the file name suggests that the client would issue requests from the ip address `10.0.0.1` and contact the address `10.0.0.2:45141` (`:38246`) on the bridge, and the address of the domain the client would like to access is acccually `192.168.252.11:8443` (`.12:8443` respectively). So suppose we want the web interface to use port number `10011` for domain `review` and port number `10012` for domain `catalog`. We could do as such:
```bash
$ cp 10.0.0.1_10.0.0.2:45141 10.0.0.1_10.0.0.2:10011
$ cp 10.0.0.1_10.0.0.2:38246 10.0.0.1_10.0.0.2:10012
$ git add 10.0.0.1_10.0.0.2:1001*
$ git commit -m "allow web interface's access"
```
As the port number `10011` and `10012` have already been hardcoded into the server side of the web interface, after the above commands, the bridge know how to translate the traffic for the web interface, and we could access the data directly from there.


#### Movie Review and Data Catalogue
After we make it possible to access data from the webinterface, we could use it to create new movie reviews. And as you could see, the interface for movie reviews is like the following:

![][review interface]

From here, you could search movies, add new review for the movie (you need to fill in your rating and comment). And there is a list of your previous reviews. These can be pulled from the dedicated persistence directory.From the list,  you could delete the review or modify the rating/comment.

As for catalogue, it serves as a panel for the data owner to decide which data he/she wants to expose to the outside world for discovery (through the service of MUSE), and to whom he/she wants them to expose. For this simple example, we have only the data of movie reviews. Click the *eye* button, you could know the meta data for your review data, this is the base from which the external data consumers could decide if your data are of interest to them, cause this meta data contains the description of the data format the owner could provide.

![][catalog meta data]

Then click the *up* button, the meta data will be published through MUSE cloud. From there, your data trun to be discovrable to the data consumers. However, even though being discovrable, still no one could search it cause you haven yet another level of control that you could decide which specific clients could search through the data you've published. Since we've delegated this right to no one, the data are still invisible. From here, by clicking the *pencil* button, you, as the owner of the data, could have a section where you delegate or revoke the search right to or from some specific client. These clients are identified by their IDs from the MUSE cloud.

![][catalog delegate/revoke]

<!-- links -->
[pih-gatekeeper]:https://github.com/sevenEng/pih-gatekeeper
[pih-bridge]:https://github.com/ucn-eu/pih-bridge
[data serving unikernels]:https://github.com/sevenEng/pih-store-instance
[irmin]:https://github.com/mirage/irmin

<!-- pictures -->
[start gatekeeper]:https://www.cl.cam.ac.uk/~ql272/_old/pics/start_gatekeeper.png "start gatekeeper"
[apply access]:https://www.cl.cam.ac.uk/~ql272/_old/pics/apply_access.png "apply access right"
[pending requests]:https://www.cl.cam.ac.uk/~ql272/_old/pics/pending_requests.png "pending requests"
[approved access]:https://www.cl.cam.ac.uk/~ql272/_old/pics/approved_access.png "approved access"
[approved gk bridge]:https://www.cl.cam.ac.uk/~ql272/_old/pics/gk_bridge_approved.png "gatekeeper bridge configuration after approval"
[review interface]:https://www.cl.cam.ac.uk/~ql272/_old/pics/movie_review.png "movie review interface"
[catalog meta data]:https://www.cl.cam.ac.uk/~ql272/_old/pics/catalog1.png "catalog meta data"
[catalog delegate/revoke]:https://www.cl.cam.ac.uk/~ql272/_old/pics/catalog2.png "catalog delegation and revocation"
