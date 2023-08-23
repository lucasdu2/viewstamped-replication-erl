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

# General Code Structure
Every node should have same structures for stored state, since each node has the
potential to be a primary. Figure 2 illustrates VR state at each replica. We
can probably store all of this state in an Erlang record.

For the log specifically, a simple idea would be to use a list. It's unclear to
me right now what each log entry should contain and how best to store it.


