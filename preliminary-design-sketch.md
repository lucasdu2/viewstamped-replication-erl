# Implementation Plan
- Develop working version locally (separate local instances of the Erlang VM)
- Add code to make fully distributed, rent out some servers on the cloud to 
test in a more realistic distributed scenario

- Need to think of a way to run a basic suite of error injection tests on the 
implementation--does not need to be super robust, but needs to at least offer
a baseline indication of correctness

The MIT6.824/MIT6.5840 Raft lab splits Raft into several layers, which I think
could be expedient to follow here:
A. Leader election (view change, in our case, which does not actually require
election--deterministic choice based on view number, # of nodes in cluster)
B. Log
C. Persistence (VR does not actually require persistence to disk, so this
section could be more aptly labeled "node failure recovery")
D. Log compaction (discussed in Section 5 of the VR Revisited paper)

Since this project is not time-bound (like the MIT Raft lab), I also 
(idealistically) plan to implement the reconfiguration protocol as well as 
specific optimizations mentioned in the VR Revisited paper (specifically 
batching and fast reads).

## View Changes
One question to keep in mind: what happens if the new expected primary fails 
during the view change process? how do we ensure liveness and move on to the 
next expected primary?
- In Raft, this is handled by an election timeout. I don't think the VR paper 
explicitly mentions anything to this effect (at least in my reading so far).
The elected leader in Raft sends periodic heartbeats to keep the election
timeout from elapsing--should we do a similar thing in VR?
Also, in the protocol described in Section 4.2 (View Changes), it seems like a 
single replica that does not hear from the primary after some timeout will 
start a view change--but isn't this ok? It could just be due to some small 
network issue, but if the primary is still connected f+1 replicas, aren't we
still safe? Quick answer (I think) is no: if we lose a single replica, our 
correctness guarantees from having 2f+1 active replicas are lost and we need
to rectify the situation as quickly as possible.

What happens in a basic VR view change:
1. 

# General Code Structure
Every node should have same structures for stored state, since each node has the
potential to be a primary. Figure 2 illustrates VR state at each replica. We
can probably store all of this state in an Erlang record.

For the log specifically, a simple idea would be to use a list. It's unclear to
me right now what each log entry should contain and how best to store it. Each
log entry needs to contain enough information to replay each step, so it seems 
to be application-dependent. I think we should keep the log entry structure as
general as possible--e.g. a binary--and let the application specify the logic
to produce them and handle them (in the case of state recovery).


