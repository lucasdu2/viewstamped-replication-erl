# Current to-dos
## First pass implementation goal
- First, implement the system without any requests, just commit messages 
from primary to backups and view change protocol if primary fails.
- Start by writing this for a concurrent, local program where each node
is represented by a process. Move to a distributed setup later.
- Write a bit of code, then run it and test it with unit tests or some
small-scale integration tests

## View change logic todos
%% TODO: Do I need to use the replica number anywhere? Should we be checking for
%% duplicate messages from the same replica? On a related note, should we be
%% resending messages if we don't get a message back confirming the message was
%% received? This would clearly require use of the replica number.
**Answer:** Yes, need to check for duplicates. Figure out how to do this.
%% NOTE: Let's just not resend messages for now. I think we can assume that if 
%% a message is not received/delivered, there is a problem with the network or
%% with the target replica that VR is already designed to work in spite of.
%% TODO: For last normal view field in replica state, set it every time we 
%% increment the view number and the replica status in the new view is "normal"

# Implementation Plan
- Develop working version locally (separate local instances of the Erlang VM)
- Add code to make fully distributed, rent out some servers on the cloud to 
test in a more realistic distributed scenario

- Try to use some built-in Erlang tooling: Dialyzer for type-checking, EUnit for
unit tests

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

As an update on 10.2.23: I think the above was quite idealistic...let's just get
the basic, barebones VR protocol implemented and tested. There are other things
I want to get around to starting in 2024 and I don't think it's worth dragging
this particular project out over these details, particularly when the bare-bones
implementation is already proving to be a challenge for me.

## View Changes
### Some questions...
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
to rectify the situation as quickly as possible. Need to consider this some 
more though...

Also, what if we get through so many views that the view numbers overflow and
wrap around? Some of the logic surrounding handling STARTVIEWCHANGE/DOVIEWCHANGE
messages will have to change.

What happens in a basic VR view change:
1. When some replica i has not heard from a primary after a certain timeout, it
will initiate a view change by advancing its view number and sending a
STARTVIEWCHANGE message to all other replicas
2. When replica i gets a STARTVIEWCHANGE from f+1 replicas, submit a DOVIEWCHANGE
message to the primary
3. When the primary gets f+1 DOVIEWCHANGE messages, it makes sure its internal
state for the new view is up-to-date, then it sends a STARTVIEW message to all 
other replicas so that everyone's "idea" of the view is consistent

What should be the behavior of the new primary at the conclusion of a view
change? what if the new log it has contains uncommitted entries--does the primary
need to do anything, or is it correct to just wait for PrepareOK messages from
the new backups? Is it possible that the previous primary executed the operation
but was not able to increment its commit number/send out a Reply message to all
backups--and if yes (I think it is), how should we handle it? It appears that if
we don't handle it, the same operation may get executed twice on the previous 
primary--this is bad if the operation is not idempotent (which it may not 
necessarily be).

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

For the client table, use a map from client ID to a tuple containing the most
recent request number and the result sent for that request (if the request was
executed). 


