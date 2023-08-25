-module(vr).
-export([start/0]).
-record(replica_state, {configuration,
                        replica_number,
                        view_number,
                        status,
                        op_number,
                        log,
                        commit_number,
                        client_table}).
-record(commit, {}).
-record(prepare, {}).
-record(prepare_ok, {}).
-record(start_viewchange, {}).
-record(do_viewchange, {}).

%% TODO: Add types and try to use dialyzer during development
%% TODO: What kinds of structures should we use to store the log/client table?
%% First, implement the system without any requests, just commit messages from
%% primary to backups and view change protocol if primary fails.

%% NOTE: We first implement with a static configuration read from a file on 
%% each node. Reconfiguration can/will be implemented later.

load_config(Filename) -> 
    {ok, Bin} = file:read_file(Filename),
    SplitBin = binary:split(Bin, <<"\n">>, [global]),
    %% Convert binary to strings and sort
    SplitStr = lists:map(fun(X) -> binary:list_to_bin(X) end, SplitBin),
    lists:sort(SplitStr).

%% lookup_node_index does a simple linear search of the list
%% NOTE: Can we do something more efficient, like a binary search?
lookup_node_index(ThisNode, [H|_], Counter) when H =:= ThisNode -> Counter;
lookup_node_index(ThisNode, [_|T], Counter) -> lookup_node_index(ThisNode, T, Counter+1).

start() ->
    %% Initialize replica state
    Config = load_config("init_config.txt"),
    Index = lookup_node_index(node(), Config, 0),
    State = #replica_state{configuration=Config,
                   replica_number=Index,
                   view_number=0,
                   status=normal,
                   op_number=0,
                   commit_number=0},
    void.


    

loop() -> void. 