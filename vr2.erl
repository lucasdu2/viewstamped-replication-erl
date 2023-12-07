-module(vr2).
-include_lib("eunit/include/eunit.hrl").
-export([start/1, send2others/3]).

-record(state, {%% Below: state specified in paper
                configuration,
                replica_number,
                view_number=0,
                status="normal",
                last_normal_view=0,
                op_number=0,
                log=[],
                commit_number=0,
                client_table=#{},
                %% Below: state needed for view change protocol
                start_vc_count=0,
                do_vc_count=0,
                max_vc_commit_number=0,
                max_do_vc_msg,
                %% Below: state needed for protocol message deduplication
                start_vc_cache=#{}}).
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

build_do_viewchange(State) ->
    #state{view_number = V,
           log = L,
           last_normal_view = NV,
           op_number = Op,
           commit_number = C,
           replica_number = I} = State,
    #do_viewchange{view_number = V,
                   log = L,
                   last_normal_view = NV,
                   op_number = Op,
                   commit_number = C,
                   replica_number = I}.

send_do_viewchange(C, Q, State) when C =:= Q ->
    DoVCMsg = build_do_viewchange(State),
    NextPrimary = calculate_primary_from_view(State),
    send_msg(DoVCMsg, [NextPrimary], 3);
send_do_viewchange(_, _, _) -> void.

%% @doc: TODO (and spec for this function and above functions)
process_start_viewchange(StateV, MsgV, State, Msg) when StateV =:= MsgV ->
    #state{start_vc_count = Cnt, start_vc_cache = MsgCache} = State,
    #do_viewchange{replica_number = MsgI} = Msg,
    %% Only process non-duplicate messages
    case maps:find(MsgI, MsgCache) of
        {ok, _} ->
            %% Increment message counter
            NewCnt = Cnt + 1,
            NewState = State#state{start_vc_count = NewCnt},
            %% TODO: Add message to the cache
            Quorum = calculate_quorum(NewState),
            send_do_viewchange(NewCnt, Quorum, NewState),
            NewState;
        error -> State
    end;
process_start_viewchange(_, _, State, _) ->
    State.

handle_start_viewchange(State, Msg) ->
    #state{view_number = StateV} = State,
    #start_viewchange{view_number = MsgV} = Msg,
    %% Process message when view numbers match, do nothing otherwise
    process_start_viewchange(StateV, MsgV, State, Msg).

handle_do_viewchange(State, Msg) -> State.

handle_commit(State, Msg) -> State.

handle_start_view(State, Msg) -> State.

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
    State = #state{configuration=Content,
                   replica_number=I,
                   client_table=maps:new(),
                   start_vc_cache=maps:new()},
    %% Spawn execution loop, register process with same name as module
    register(?MODULE, spawn(fun() -> loop(State) end)).

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
    case send2others(Msg, Cfg, 3) of
        ok -> ok;
        {error, Fails} -> io:format("Message failed to send to: ~p~n", Fails)
    end,
    receive
        {From, StartVC} when is_record(StartVC, start_viewchange) ->
            receive_msg(From, StartVC, fun handle_start_viewchange/2, State);
        {From, DoVC} when is_record(DoVC, do_viewchange) ->
            receive_msg(From, DoVC, fun handle_do_viewchange/2, State);
        {From, StartV} when is_record(StartV, start_view) ->
            receive_msg(From, StartV, fun handle_start_view/2, State);
        Unexpected ->
           io:format("Unexpected message ~p~n", [Unexpected]),
            State
    after
        %% If no messages after brief interval, return current state and
        %% continue execution loop
        200 ->
            State
    end.

backup(State) ->
    %% If no communication from primary after a specified timeout, start view
    %% change protocol
    NewState = receive
        {Primary, Commit} when is_record(Commit, commit) ->
            receive_msg(Primary, Commit, fun handle_commit/2, State)
    after
      1000 ->
            %% Send STARTVIEWCHANGE to all other replicas
            V = State#state.view_number,
            I = State#state.replica_number,
            Msg = #start_viewchange{view_number=V+1, replica_number=I},
            Cfg = State#state.configuration,
            case send2others(Msg, Cfg, 3) of
                ok -> ok;
                {eror, Fails} -> io:format("Message failed to send to: ~p~n", Fails)
            end,
            %% Update and return new state
            ViewChangeState = State#state{view_number=V+1, status="view-change"},
            ViewChangeState
    end,
    %% Handle view change protocol messages
    receive
        {From, StartVC} when is_record(StartVC, start_viewchange) ->
            receive_msg(From, StartVC, fun handle_start_viewchange/2, NewState);
        {From, DoVC} when is_record(DoVC, do_viewchange) ->
            receive_msg(From, DoVC, fun handle_do_viewchange/2, NewState);
        {From, StartV} when is_record(StartV, start_view) ->
            receive_msg(From, StartV, fun handle_start_view/2, NewState);
        Unexpected ->
            io:format("Unexpected message ~p~n", [Unexpected]),
            NewState
    end.

%% =============================================================================
%% Message-passing framework functions
%% =============================================================================

%% @doc Sends a message to a list of nodes, retrying a specified number of times
%% for each node if no ack response is received.
-spec send_msg(msg(), list(node()), integer()) -> ok | {error, list(node())}.
send_msg(Msg, [Node], Retries) ->
    %% Pass message to registered process on other node
    {?MODULE, Node} ! {node(), Msg},
    receive
        {From, ok} when From =:= Node -> ok
    after 500 ->
        case Retries of
            0 -> {error, [Node]};
            _ -> send_msg(Msg, [Node], Retries-1)
        end
    end;
send_msg(Msg, Nodes, Retries) ->
    Resp = lists:map(fun(X) -> send_msg(Msg, [X], Retries) end, Nodes),
    %% Build a list of nodes that failed to deliver the message
    Fails = [ X || {error, [X]} <- Resp],
    case Fails of
        [] -> ok;
        _L -> {error, Fails}
    end.

%% @doc Sends a message using send_msg to all nodes except itself, given a list
%% of nodes.
-spec send2others(msg(), list(node()), integer()) -> ok | {error, list(node())}.
send2others(Msg, Nodes, Retries) ->
    Rest = lists:filter(fun(X) -> X /= node() end, Nodes),
    send_msg(Msg, Rest, Retries).


%% @doc Sends an ack response back after a message is received and delivered,
%% then runs the specified handler of the message. Should be called within a
%% receive block.
-spec receive_msg(node(), msg(), fun((state(), msg()) -> state()), state()) -> state().
receive_msg(From, Msg, Handler, State) ->
    %% Return message delivered ack to sending node
    {?MODULE, From} ! {node(), ok},
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
            SortBin = lists:sort(SplitBin),
            SortedCfg = lists:map(fun(Bin) -> binary_to_atom(Bin) end, SortBin),
            {ok, SortedCfg};
        error -> {error, Content}
    end.

%% @doc Finds the index number of a node in the configuration
%% NOTE: Can we do something more efficient, like a binary search?
lookup_node_index(_, [], _) -> -1;
lookup_node_index(Node, [H|_], Cnt) when H =:= Node -> Cnt;
lookup_node_index(Node, [_|T], Cnt) -> lookup_node_index(Node, T, Cnt+1).

lookup_node_index_test() ->
    TestCfg = [node1, node2, node3, node4, node5],
    ?assertEqual(0, lookup_node_index(node1, TestCfg, 0)),
    ?assertEqual(3, lookup_node_index(node4, TestCfg, 0)).

%% @doc Modification of lists:nth/2 that is 0-indexed instead of 1-indexed.
nth0index(0, [H|_]) -> H;
nth0index(N, [_|T]) when N > 0 ->
    nth0index(N - 1, T).

%% @doc Finds the name of primary node associated with a view number.
calculate_primary_from_view(State) ->
    #state{configuration = Cfg, view_number = V} = State,
    TotalReplicas = erlang:length(Cfg),
    PrimaryI = V rem TotalReplicas,
    nth0index(PrimaryI, Cfg).

calculate_primary_from_view_test() ->
    TestState = #state{configuration = [node1, node2, node3], view_number = 1},
    ?assertEqual(node2, calculate_primary_from_view(TestState)).

%% @doc Calculates the quorum of the system (a majority of the total number of
%% nodes in the system).
calculate_quorum(State) ->
    erlang:length(State#state.configuration) div 2 + 1.

calculate_quorum_test() ->
    TestState = #state{configuration = [n1, n2, n3, n4, n5, n6, n7]},
    ?assertEqual(4, calculate_quorum(TestState)).
