-module(vr2).
-include_lib("eunit/include/eunit.hrl").
-export([start/1]).

-record(replica_state, {configuration,
                        replica_number,
                        view_number=0,
                        status="normal",
                        last_normal_view=0,
                        op_number=0,
                        log=[],
                        commit_number=0,
                        client_table=#{},
                        start_vc_count=0,
                        do_vc_count=0,
                        max_vc_commit_number=0,
                        max_do_vc_msg}).

-record(start_viewchange, {view_number, replica_number}).
-record(do_viewchange, {view_number, 
                        log, 
                        last_normal_view, 
                        op_number, 
                        commit_number, 
                        replica_number}).
-record(start_view, {view_number, log, op_number, commit_number}).

%% =============================================================================
%% Exported functions
%% =============================================================================

start(CfgFile) ->
    %% Load initial cluster configuration
    {Ret, Content} = load_config(CfgFile),
    case Ret of
        ok -> io:format("Read configuration: ~p~n", [Content]);
        error -> error(Content)
    end,
    %% Set up initial cluster state
    I = lookup_node_index(node(), Content, 0),
    State = #replica_state{configuration=Content, replica_number=I},
    %% Enter execution loop
    loop(State).

loop(State) ->
    I = State#replica_state.replica_number,
    V = State#replica_state.view_number,
    case {I, V} of
        {Same, Same} -> primary;
        _ -> backup
    end.

%% =============================================================================
%% Message-passing framework functions
%% =============================================================================
send_message_unicast(Msg, Node, Retry) -> 
    Node ! {node(), Msg},
    receive
        {From, ok} when From =:= Node -> ok
    after 500 ->
        case Retry of
            0 -> fail;
            _ -> send_message_unicast(Msg, Node, Retry-1)
        end
    end.

send_message_multicast(Msg, Nodes, Retry) ->
    list:map(fun(X) -> send_message_unicast(Msg, X, Retry) end, Nodes).
    
    

%% =============================================================================
%% Internal functions
%% =============================================================================

%% @doc Loads an initial configuration from a local file.
load_config(File) -> 
    {Ret, Content} = file:read_file(File),
    case Ret of
        ok -> 
            SplitBin = binary:split(Content, <<"\n">>, [global]),
            SortedCfg = lists:sort(SplitBin),
            {ok, SortedCfg};
        error -> {error, Content}
    end.

%% @doc Lookup_node_index does a simple linear search of the list
%% NOTE: Can we do something more efficient, like a binary search?
lookup_node_index(Node, [H|_], Cnt) when H =:= Node -> Cnt;
lookup_node_index(Node, [_|T], Cnt) -> lookup_node_index(Node, T, Cnt+1).

lookup_node_index_test() ->
    TestCfg = [node1, node2, node3, node4, node5],
    ?assertEqual(0, lookup_node_index(node1, TestCfg, 0)),
    ?assertEqual(3, lookup_node_index(node4, TestCfg, 0)).