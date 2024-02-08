# View change protocol
Let's try this again, now that you've had a chance to grapple with the protocol
for a bit. Here's a second attempt at organizing the code structure in service
of the view change protocol.

## General philosophy
Everything revolves around replica state. Within the replica state, arguably the
most important piece is the log. The state is the source of truth for what is
happening in the system. At the beginning of every execution loop, each replica
should look to its state to understand its current role and status in the system.

## Common structures
- Replica state should be contained in a record. You should also add all the
state necessary to handle view changes into the common replica state--this will
save us from having to pass 2 separate pieces of state around.
- Messages should also be records. When sending a message, we should also prefix
it with the Name of the sender--perhaps it would also be more efficient to
prefix it with an atom denoting the message type as well, so we don't have to
do a record type check.
- We should use the Name of the sender to send back a response upon successful
reception and delivery of the message. This is the mechanism to determine if we
should resend a message. This also implies we need to handle duplicate messages
on the receiver's side.

## Code flow
- Execution on each replica starts by gaining knowledge of the cluster
configuration (e.g. the other nodes in the system), setting up its initial
default state, then beginning its execution loop.
- Instead of having 2 separate execution loops for primary and backup replicas,
have a single execution loop that checks at the top if the replica is
currently a primary or a backup. You can abstract out the actual primary and
backup behavior into separate functions if that feels more organized.
- Instead of programming the message receive behavior into the execution loops
themselves, it may be cleaner to simply move that logic into the message handler
functions--just have a check at the message handler level if the replica is a
primary or a backup, then execute differently depending on the result of the
check. This may also allow us to generalize the message reception portion of the
execution loop code between primary and backup. Generally, moving logic out
of the main loop and into message-specific handlers seems to make the code
more flexible in the long run.
- Attempt to generalize message send and receive behavior, since you'll need
to add resend and duplicate management logic for all messages.
  - For now, attempt resend 3 times. If no confirmation is received after 3
  attempts, assume disconnection (either network or node failure).
- What should be done when a node is considered disconnected?
- What should be done if the next primary fails during a view change? How do we
guarantee that the protocol will move on to the next possible primary?

### Message de-deduplication in the view change protocol
- De-duplication is hard to generalize--we don't want to store a history of all
the messages ever passed to a node and certain messages may require different
de-duplication policies. For example, the handling of some messages may already
be idempotent and not require any de-duplication. Other messages require
de-duplication, but only up to a certain point, after which the protocol will
automatically discard the messages (e.g. if they are from a previous view). As
a result, I think we should *do de-duplication in the message-specific handlers.*
- We only need to save the *replica numbers* of each type of message in the view
change protocol, since each replica should send each message type at most once
to each other replica during the protocol.
- I think we should have a separate set for each type of message, storing the
*replica numbers* of all messages that get sent in a certain interval of time.
The nice thing about VR is that there are pretty defined scopes of time, so we
can clear each set (or each cache, if we want to call it that) once its contents
are no longer needed. For example, all messages related to view changes can be
discarded once a view change is completed, since the protocol will already
(I think) reject future messages related to a past view change.

## Development plan
- Write code and test in small increments. Once tests pass and you're reasonably
sure the code that was written does what it should do, write up a spec for the
dialyzer.
