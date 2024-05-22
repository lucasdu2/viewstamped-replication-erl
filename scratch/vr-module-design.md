# VR module design
## Problem
Ideally, the Viewstamped Replication implementation would be completely
decoupled from any service that it is being used in, i.e. a key-value storage
service. This is somewhat difficult (at first glance, at least, for me) because
the specifics of the data we are replicating appear tightly coupled with A) the
way VR log entries should be structured and B) the structure of responses stored
in the client table.

## Possible solutions
- As a general idea, VR implementation should only handle keeping the log
consistent--the log is really the most important piece of VR-managed state
- Very simply, the service code should provide a function to execute an
operation as indicated by a log entry
    - the VR implementation should provide a way take in this service-defined
    function and execute it within the VR logic
- The service code should also provide an appropriate representation of
operations to be stored as log entries and a representation of responses to be
stored within the client table
    - again, the VR implementation should be able to plug these service-defined
    representations into its logic
- The most natural way to do this in Erlang appears to be to take in these
service-defined structures as parameters to our functions
    - we can just pass the log entry structure and the client table response
    structure to whatever VR module function will create the initial state for
    each replica (and thus will also create the log and the client table)
    - we can pass the operation execution function to any VR module function
    that needs to execute operations
    - as long as the service code fulfills a certain contract, specifically that
    the operation execution function *takes in the defined operation structure
    (which is also the log entry structure)* and *outputs the defined response
    structure (which is also the client table response entry structure)*,
    everything should work out
    - the VR module implementation should not have to touch anything related to
    the nitty gritty of actually executing an operation--it simply passes that
    functionality off to the service code and expects the service code to behave
    properly according to the above contract

## Functions to export from VR module
We also need to imagine importing the VR module into another program--the
service program--so we may need to rethink what functions we want to export
for the service program to have access to.

## Some things to consider
- Possibly have one VR server on the same node as each KV server
- KV client communicates with KV server, KV server communicates with VR server
in order to do the replication
- KV server takes client request, passes it to VR server for log replication;
once request is committed to the VR log, VR server communicates this with the
KV server, KV server actually executes the operation
- One difficulty: clients always need to be communicating with the primary
server from VR's perspective
    - how can we get this to work with a gen_server setup? is it even possible?
    - we need to have some kind of upcall mechanism to communicate primary
    changes to the client
    - the other possibility is having a stable name for the server that clients
    can always communicate with and that does the request routing to the primary
    behind the scenes--but unsure if this is possible with Erlang/BEAM

## VR module interface
We can try to get some insight from MIT6.824 lab handouts, which use Raft. But
weirdly, there is a difference in the way that their Raft module is structured
vs. how our VR module can be structured.

They implement their Raft module as a library that can be called by the service
code, i.e. the KV store they are writing. The client directly calls the KV
service code, and the KV service code will then ask the VR instance on the node
place the operation into the replicated log. Once the operation is committed,
the VR instance will pass a message to the KV service code telling it to execute
the operation. When the operation is executed, the KV service code will respond
to the client.

In VR, there is a feature where *VR itself will check the client request number,
and will simply send the previous response if the client request number is less
than the request number for that client in the client table.* So while we could
put VR "behind" the KV store and just have the KV service transparently pass
client requests to VR and VR responses to the client, it might make more sense
to put VR "in front" of the KV service and have the client communicate directly
with the VR instance.

By putting VR "in front" of the KV service (or any other user-defined service),
we would somewhat muck up Erlang's nice client/server abstraction with
gen_servers. The user would need to write a client that communicates with the
VR client interface and a server that needs to adhere to the VR execution
interface (where VR acts as a client to the user-defined server).

If VR is "behind" the KV service, there is only a limitation on the execution
interface, where the KV server needs to communicate with the interface
exposed by the VR instance. The KV client code is under so such limitation,
since it will communicate directly with the KV server (which is also
user-defined).

In the case of VR, because the VR instances themselves maintain a client table
that stores some information about client state, it makes the most sense to
put VR "in front" of the KV service (in my view). This does seem to put a bit
more burden on the service code, but only slightly. VR could also just come
with a client implementation that allows the user to simply fill in some blanks
to create their own client.

In hindsight, all of this is discussed in the paper, in Figure 1 and Section 4:
The VR Protocol. We need a VR proxy on the client side and the VR code in front
of the service code.

The client is able to tell what the current primary is because it stores the
configuration of the cluster as well as what it believes is the current view
number. This view number gets sent the client with every response message so
the client can track it and properly calculate the current primary. The
configuration should be given to the client before the client first connects and
registers with the VR cluster.

The client also needs to store its client ID and its current request number. The
client ID can be given to the client by the VR cluster when the client first
connects. The client will need to track its current request number on its own.

-----

So a structure that could work for a KV service is as follows:

VR proxy (interface with user code):
- Pass a representation of the operation that is usable by the service code
transparently to the VR proxy

VR proxy (interface with VR code):
[Sent Messages]
- REQUEST: (request operation, client ID, request number)
[Received Messages]
- REPLY: (view number, request number, result)

VR code (interface with service code):
[Sent Messages]
- EXECUTE: (request operation)
[Received Messages]
- RESULT: (result)

The user essentially just needs to write the service code, which takes in some
set of operations and returns an appropriate result to the VR code, which will
then actually respond to the client. The code to interact with the VR proxy
should be trivial.

-----

All that said, I would want a structure where the user, when writing their
service or client code, should just be able to pull in the VR module and
call some functions without actually modifying the VR module code itself.

What would a good abstraction be?

The parts of concern are:
- Passing the request operation structure to the VR proxy.
- Executing the operation with the service code and getting the result.

The second part is the harder one. One nice way to do it would be to use
Erlang's hot code reloading to dynamically load service code execution
behaviour. I think this might be the most "Erlang"-ish way to do it. The other,
perhaps easier way to do it is just to write the service code as a server and
then pass the PID of the service code server to the VR code server when starting
up the VR instance. Then the VR instance can simply communicate with the service
code by passing messages to and from that PID. We can still do hot code
reloading by dynamically passing the PID to communicate with at runtime.

Unfortunately, doing things this way means that the user code will not fit
cleanly into the gen_server framework. The VR code will essentially be a
middleman between the user client and server, which messes up the direct
client-server interaction that gen_server assumes.
