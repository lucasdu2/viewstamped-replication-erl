# Key/Value Service Specification
- Client should be able to communicate with remote servers
- All operations on the server should be linearizable
- All operations should be idempotent (to avoid deduplication)
- Allowed operations:
  - create entry: create a (key, value) entry
  - delete entry: delete an entry by key
  - update value: update value of a key
  - get value: get value of a key

Erlang makes the hard parts (the first two points) pretty easy, provided we
can assume the client is also written in Erlang. For the sake of this exercise,
where the hard part should be implementing VR logic, we just assume that.
