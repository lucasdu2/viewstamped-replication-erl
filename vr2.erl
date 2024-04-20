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
                client_table=maps:new(),
                %% Below: state needed for view change protocol
                start_vc_count=0,
                do_vc_count=0,
                max_vc_commit_number=0,
                max_do_vc_msg,
                %% Below: state needed for protocol message deduplication
                start_vc_cache=sets:new(),
                do_vc_cache=sets:new()}).
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
%% Message handlers and senders
%% =============================================================================

send_commit(State) ->
    V = State#state.view_number,
    Commit = State#state.commit_number,
    Msg = #commit{view_number=V, commit_number=Commit},
    Cfg = State#state.configuration,
    case send2others(Msg, Cfg, 3) of
        ok -> ok;
        {error, Fails} -> io:format("Message failed to send to: ~p~n", Fails)
    end.

handle_commit(State, Msg) ->
    %% Set status and view number to ones given in message; reset STARTVIEWCHANGE
    %% message counter and cache
    %% NOTE: This handles the case where a replica enters the view-change
    %% protocol, but then reconnects with the primary
    State#state{status         = "normal",
                view_number    = Msg#commit.view_number,
                commit_number  = Msg#commit.commit_number,
                start_vc_count = 0,
                start_vc_cache = sets:new()}.

send_start_viewchange(State) ->
    V = State#state.view_number,
    I = State#state.replica_number,
    Cfg = State#state.configuration,
    case State#state.status of
        "normal" ->
            %% Increment view number
            NewV = V + 1,
            %% Increment local STARTVIEWCHANGE message counter
            NewCnt = State#state.start_vc_count + 1,
            Msg = #start_viewchange{view_number=NewV, replica_number=I},
            %% Update state
            NewState = State#state{view_number=NewV,
                                   status="view-change",
                                   start_vc_count=NewCnt};
        "view-change" ->
            Msg = #start_viewchange{view_number=V, replica_number=I},
            %% Retain current state
            NewState = State
    end,
    %% Send STARTVIEWCHANGE message to other replicas
    case send2others(Msg, Cfg, 3) of
        ok -> ok;
        {error, Fails} ->
            io:format("Message failed to send to: ~p~n", Fails)
    end,
    NewState.

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

send_do_viewchange(C, Q, State) when C >= Q ->
    DoVCMsg = build_do_viewchange(State),
    NextPrimary = calculate_primary_from_view(State),
    case send_msg(DoVCMsg, [NextPrimary], 3) of
        ok -> ok;
        {error, _} ->
            io:format("Message failed to send to: ~p~n", NextPrimary)
    end,
    %% Reset STARTVIEWCHANGE counter and message cache
    %% NOTE: If we don't reset here after sending a DOVIEWCHANGE message, we
    %% will only stop sending DOVIEWCHANGE messages when a view change actually
    %% completes and we do a reset there. Since replicas can reconnect, the
    %% completion of a view change at this point in the protocol is not
    %% guaranteed--we do not want to send DOVIEWCHANGE messages indefinitely.
    State#state{start_vc_count = 0,
                start_vc_cache = sets:new()};
send_do_viewchange(_, _, _) -> void.

%% @doc: Processes STARTVIEWCHANGE message when view numbers match
process_start_viewchange(StateV, MsgV, State, Msg) when StateV =:= MsgV ->
    #state{start_vc_count = Cnt, start_vc_cache = MsgCache} = State,
    #start_viewchange{replica_number = MsgI} = Msg,
    %% Skip duplicate messages (i.e. messages from the same replica)
    case sets:is_element(MsgI, MsgCache) of
        true -> State;
        false ->
            %% Increment message counter
            NewCnt = Cnt + 1,
            %% Add message replica number to cache
            NewCache = sets:add_element(MsgI, MsgCache),
            NewState = State#state{start_vc_count = NewCnt, start_vc_cache = NewCache},
            Quorum = calculate_quorum(NewState),
            %% Send DOVIEWCHANGE message when quorum is reached
            send_do_viewchange(NewCnt, Quorum, NewState),
            NewState
    end;
process_start_viewchange(_, _, State, _) -> State.

%% @doc: Handles STARTVIEWCHANGE messages sent to a replica.
handle_start_viewchange(State, Msg) ->
    #state{view_number = StateV} = State,
    #start_viewchange{view_number = MsgV} = Msg,
    %% Process message when view numbers match, do nothing otherwise
    process_start_viewchange(StateV, MsgV, State, Msg).

send_start_view(C, Q, State) when C >= Q ->
    %% Update state, clear view change metadata
    MaxDoVC   = State#state.max_do_vc_msg,
    NewV      = MaxDoVC#do_viewchange.view_number,
    NewLog    = MaxDoVC#do_viewchange.log,
    %% NOTE: Since, in our Erlang implementation, every action within a replica
    %% should be serial, we can just directly get the new op number from the
    %% message itself (instead of having to get it from the log). There should
    %% be no risk that the max op number in the log and the op number in the
    %% message are de-synced.
    NewOp     = MaxDoVC#do_viewchange.op_number,
    MaxCommit = State#state.max_vc_commit_number,
    NewState = State#state{view_number   = NewV,
                           log           = NewLog,
                           op_number     = NewOp,
                           commit_number = MaxCommit,
                           status        = "normal",
                           %% Clear relevant view change metadata
                           do_vc_count          = 0,
                           max_vc_commit_number = 0,
                           max_do_vc_msg        = #do_viewchange{},
                           do_vc_cache          = sets:new()},
    Msg = #start_view{view_number   = NewV,
                      log           = NewLog,
                      op_number     = NewOp,
                      commit_number = MaxCommit},
    Cfg = State#state.configuration,
    case send2others(Msg, Cfg, 3) of
        ok -> ok;
        {error, Fails} ->
            io:format("Message failed to send to: ~p~n", Fails)
    end,
    NewState;
send_start_view(_, _, State) -> State.

compare_commit_numbers(NewDoVC, State) ->
    NewCommit = NewDoVC#do_viewchange.commit_number,
    MaxCommit = State#state.max_vc_commit_number,
    compare_take_larger(NewCommit, MaxCommit).

compare_do_viewchanges(NewDoVC, State) ->
    MaxDoVC = State#state.max_do_vc_msg,
    MaxNormal = MaxDoVC#do_viewchange.last_normal_view,
    case NewDoVC#do_viewchange.last_normal_view of
        NewNormal when NewNormal > MaxNormal   -> NewDoVC;
        NewNormal when NewNormal =:= MaxNormal ->
            N1 = NewDoVC#do_viewchange.op_number,
            N2 = MaxDoVC#do_viewchange.op_number,
            case N1 > N2 of
                true  -> NewDoVC;
                false -> MaxDoVC
            end;
        _ -> MaxDoVC
    end.

process_do_viewchange(StateV, MsgV, State, Msg) when MsgV >= StateV ->
    #state{do_vc_count = Cnt, do_vc_cache = MsgCache} = State,
    #do_viewchange{replica_number = MsgI} = Msg,
    %% Skip duplicate messages (i.e. messages from the same replica)
    case sets:is_element(MsgI, MsgCache) of
        true -> State;
        false ->
            %% Increment message counter
            NewCnt = Cnt + 1,
            %% Add message replica number to cache
            NewCache = sets:add_element(MsgI, MsgCache),
            %% Update state with necessary view change metadata
            NewState = State#state{
                         do_vc_count          = NewCnt,
                         do_vc_cache          = NewCache,
                         max_vc_commit_number = compare_commit_numbers(Msg, State),
                         max_do_vc_msg        = compare_do_viewchanges(Msg, State)
                        },
            Quorum = calculate_quorum(NewState),
            %% Send STARTVIEW message when quorum is reached
            send_start_view(NewCnt, Quorum, NewState),
            NewState
    end;
process_do_viewchange(_, _, State, _) -> State.

handle_do_viewchange(State, Msg) ->
    #state{view_number = StateV} = State,
    #start_viewchange{view_number = MsgV} = Msg,
    process_do_viewchange(StateV, MsgV, State, Msg).

handle_start_view(State, Msg) -> State.

%% =============================================================================
%% Exported functions, main execution loop
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
    %% Send commit message to all backup replicas
    send_commit(State),
    %% Handle view change protocol messages
    receive
        {From, StartVC} when is_record(StartVC, start_viewchange) ->
            receive_msg(From, StartVC, fun handle_start_viewchange/2, State);
        {From, DoVC} when is_record(DoVC, do_viewchange) ->
            receive_msg(From, DoVC, fun handle_do_viewchange/2, State);
        {From, StartV} when is_record(StartV, start_view) ->
            receive_msg(From, StartV, fun handle_start_view/2, State);
        Unexpected ->
           io:format("Unexpected message on primary ~p~n", [Unexpected]),
            State
    after
        %% If no messages after brief interval, return state to continue
        200 -> State
    end.

backup(State) ->
    %% If no communication from primary after a specified timeout, start view
    %% change protocol
    NewState = receive
        {Primary, Commit} when is_record(Commit, commit) ->
            receive_msg(Primary, Commit, fun handle_commit/2, State)
    after
        %% Send STARTVIEWCHANGE to all other replicas
        1000 -> send_start_viewchange(State)
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
            io:format("Unexpected message on backup ~p~n", [Unexpected]),
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
%% Internal helper functions
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

compare_take_larger(A, B) when A > B -> A;
compare_take_larger(_, B) -> B.
