-module(vr2).
-include_lib("eunit/include/eunit.hrl").
-export([start/1]).

-record(state, {configuration,
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
-type state() :: #state{}.

-record(commit, {view_number, commit_number}).
-type commit() :: #commit{}.

-record(start_viewchange, {view_number, replica_number}).
-type start_vc() :: #start_viewchange{}.

-record(do_viewchange, {view_number, 
                        log, 
                        last_normal_view, 
                        op_number, 
                        commit_number, 
                        replica_number}).
-type do_vc() :: #do_viewchange{}.

-record(start_view, {view_number, log, op_number, commit_number}).
-type start_v() :: #start_view{}.

-type vc_msg() :: start_vc() | do_vc() | start_v().
-type norm_msg() :: commit().

-type msg() :: norm_msg() | vc_msg().

%% =============================================================================
%% Message handlers
%% =============================================================================
%% TODO: below
handle_start_viewchange(State, Msg) -> void.

handle_do_viewchange(State, Msg) -> void.

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
    State = #state{configuration=Content, replica_number=I},
    %% Enter execution loop
    loop(State).

loop(State) ->
    I = State#state.replica_number,
    V = State#state.view_number,
    case {I, V} of
        {Same, Same} -> loop(primary(State));
        _ -> loop(backup(State))
    end.

primary(State) ->
    V = State#state.view_number,
    Commit = State#state.commit_number,
    Msg = #commit{view_number=V, commit_number=Commit},
    Cfg = State#state.configuration,
    case send_msg(Msg, Cfg, 3) of
        ok -> ok;
        {error, Fails} -> io:format("Message failed to send to: ~p~n", Fails)
    end,
    receive
        {From, StartVC} when is_record(StartVC, start_viewchange) -> 
            receive_msg(From, StartVC, fun handle_start_viewchange/2, State);
        {From, DoVC} when is_record(DoVC, do_viewchange) -> 
            receive_msg(From, DoVC, fun handle_do_viewchange/2, State)
    end.
    
backup(State) -> void.

%% =============================================================================
%% Message-passing framework functions
%% =============================================================================

%% @doc Sends a message to a list of nodes, retrying a specified number of times
%% for each node if no ack response is received.
-spec send_msg(msg(), list(node()), integer()) -> ok | {error, list(node())}.
send_msg(Msg, [Node], Retries) -> 
    Node ! {node(), Msg},
    receive
        {From, ok} when From =:= Node -> ok
    after 500 ->
        case Retries of
            0 -> {error, [Node]};
            _ -> send_msg(Msg, [Node], Retries-1)
        end
    end;
send_msg(Msg, Nodes, Retries) ->
    Resp = list:map(fun(X) -> send_msg(Msg, [X], Retries) end, Nodes),
    %% Build a list of nodes that failed to deliver the message
    Fails = [ X || {error, [X]} <- Resp],
    case Fails of
        [] -> ok;
        _L -> {error, Fails}
    end.

%% @doc Sends an ack response back after a message is received and delivered,
%% then runs the specified handler of the message. Should be called within a
%% receive block.
-spec receive_msg(node(), msg(), fun((state(), msg()) -> state()), state()) -> state().
receive_msg(From, Msg, Handler, State) ->
    %% Return message delivered ack to sending node
    From ! {node(), ok},
    %% Run handler using Msg and State
    Handler(State, Msg).
    

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

%% @doc Finds the index number of a node in the configuration
%% NOTE: Can we do something more efficient, like a binary search?
lookup_node_index(Node, [H|_], Cnt) when H =:= Node -> Cnt;
lookup_node_index(Node, [_|T], Cnt) -> lookup_node_index(Node, T, Cnt+1).

lookup_node_index_test() ->
    TestCfg = [node1, node2, node3, node4, node5],
    ?assertEqual(0, lookup_node_index(node1, TestCfg, 0)),
    ?assertEqual(3, lookup_node_index(node4, TestCfg, 0)).