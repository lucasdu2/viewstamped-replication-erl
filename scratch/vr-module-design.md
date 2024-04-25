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
