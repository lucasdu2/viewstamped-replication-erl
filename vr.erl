-module(vr).
-export([start/0]).
-record(replica_state, {configuration,
                        replica_number,
                        view_number=0,
                        status="normal",
                        last_normal_view=0,
                        op_number=0,
                        log=[],
                        commit_number=0,
                        client_table=#{}}).
-record(viewchange_state, {start_viewchange_count=0,
                           do_viewchange_count=0,
                           max_commit_number=0,
                           max_do_viewchange_message}).



-record(commit, {view_number, commit_number}).
%% -record(prepare, {}).
%% -record(prepare_ok, {}).
%% -record(reply, {}).
-record(start_viewchange, {view_number, replica_number}).
-record(do_viewchange, {view_number, 
                        log, 
                        last_normal_view, 
                        op_number, 
                        commit_number, 
                        replica_number}).
-record(start_view, {view_number, log, op_number, commit_number}).

%% =============================================================================
%% Auxiliary helper functions
%% =============================================================================
%% load_config loads an initial configuration from a local file
load_config(Filename) -> 
    {ok, Bin} = file:read_file(Filename),
    SplitBin = binary:split(Bin, <<"\n">>, [global]),
    %% Convert binary to strings and sort
    SplitAtom = lists:map(fun(X) -> erlang:bin_to_atom(X) end, SplitBin),
    lists:sort(SplitAtom).

%% lookup_node_index does a simple linear search of the list
%% TODO: Can we do something more efficient, like a binary search?
lookup_node_index(ThisNode, [H|_], Counter) when H =:= ThisNode -> 
    Counter;
lookup_node_index(ThisNode, [_|T], Counter) -> 
    lookup_node_index(ThisNode, T, Counter+1).

broadcast_message(State, Msg) ->
    Cfg = State#replica_state.configuration,
    list:foreach(fun(X) -> X ! Msg end, Cfg).

unicast_message(State, Msg, I) ->
    NodeName = lists:nth(I, State#replica_state.configuration),
    NodeName ! Msg.

calculate_primary_from_view(State) ->
    NumReplicas = erlang:length(State#replica_state.configuration),
    State#replica_state.view_number rem NumReplicas.

calculate_quorum(State) ->
    erlang:length(State#replica_state.configuration) div 2 + 1.

compare_do_viewchanges(#do_viewchange{last_normal_view=V1} = New, 
                       #do_viewchange{last_normal_view=V2} = _Max) when V1 > V2 ->
    New;
compare_do_viewchanges(#do_viewchange{last_normal_view=V1} = New, 
                       #do_viewchange{last_normal_view=V2} = Max) when V1 =:= V2 ->
    case New#do_viewchange.op_number > Max#do_viewchange.op_number of
        true -> New;
        false -> Max
    end;
compare_do_viewchanges(_New, Max) -> Max.

compare_commit_numbers(C1, C2) when C1 > C2 -> C1;
compare_commit_numbers(_C1, C2) -> C2.

%% =============================================================================
%% Core view change logic
%% =============================================================================
handle_start_viewchange(#replica_state{view_number=V} = State, 
                        VCState, 
                        MsgV) when MsgV > V ->
    %% NOTE: I believe an easy optimization here is to skip ahead to the view-
    %% number given in the message (instead of simply incrementing our local
    %% view-number). I currently cannot think of a way that this optimization
    %% would violate any correctness guarantees, but keep this in mind.
    NewState = State#replica_state{view_number=MsgV, status="view-change"},
    %% Reset start_viewchange counter
    NewVCState = VCState#viewchange_state{start_viewchange_count=0},
    Msg = #start_viewchange{view_number=MsgV, 
                            replica_number=State#replica_state.replica_number},
    broadcast_message(NewState, Msg),
    {NewState, NewVCState};
handle_start_viewchange(#replica_state{view_number=V} = State, 
                        VCState, 
                        MsgV) when MsgV =:= V ->
    NewCnt = VCState#viewchange_state.start_viewchange_count + 1,
    case NewCnt =:= calculate_quorum(State) of
        true ->
            Msg = #do_viewchange{view_number=V,
                                 log=State#replica_state.log,
                                 last_normal_view=State#replica_state.last_normal_view,
                                 op_number=State#replica_state.op_number,
                                 commit_number=State#replica_state.commit_number,
                                 replica_number=State#replica_state.replica_number},
            %% Unicast this message to the next primary
            NextPrimary = calculate_primary_from_view(State),
            unicast_message(State, Msg, NextPrimary);
        false -> noop
    end,
    NewVCState = VCState#viewchange_state{start_viewchange_count=NewCnt},
    {State, NewVCState};
handle_start_viewchange(State, VCState, _MsgV) -> {State, VCState}.

handle_do_viewchange(#replica_state{view_number=V} = State, 
                     VCState, 
                     #do_viewchange{view_number=MsgV}) when MsgV > V -> 
    %% NOTE: We also skip ahead to the latest view-number given in the message
    %% (which we also do--and give rationale for--in handle_start_viewchange).
    NewState = State#replica_state{view_number=MsgV, status="view-change"},
    %% Reset do_viewchange counter
    NewVCState = VCState#viewchange_state{do_viewchange_count=0},
    %% In this case, we also start accumulating our do_viewchange counter
    Msg = #start_viewchange{view_number=MsgV, 
                            replica_number=State#replica_state.replica_number},
    broadcast_message(NewState, Msg),
    {NewState, NewVCState};
handle_do_viewchange(#replica_state{view_number=V} = State, 
                     VCState,
                     #do_viewchange{view_number=MsgV} = DoVC) when MsgV =:= V -> 
    %% Increment our counter, and then check if we have reached quorum.
    MaxDoVC = VCState#viewchange_state.max_do_viewchange_message,
    NewCnt = VCState#viewchange_state.do_viewchange_count + 1,
    %% Compare to see if the latest DoVC message is "greater than" our previous 
    %% max (and set our max to the latest DoVC message if it is)    
    NewMaxDoVC = compare_do_viewchanges(DoVC, MaxDoVC),
    %% Get up-to-date max commit number from do_viewchange messages
    DoVCCommit = DoVC#do_viewchange.commit_number,
    MaxCommit = VCState#viewchange_state.max_commit_number,
    NewMaxCommit = compare_commit_numbers(DoVCCommit, MaxCommit),
    %% Update VCState
    NewVCState = VCState#viewchange_state{do_viewchange_count=NewCnt,
                                          max_commit_number=NewMaxCommit,
                                          max_do_viewchange_message=NewMaxDoVC},
    case NewCnt =:= calculate_quorum(State) of
        true -> 
            #do_viewchange{log=MaxLog, op_number=MaxOp} = NewMaxDoVC,
            NewState = State#replica_state{log=MaxLog, 
                                           op_number=MaxOp, 
                                           commit_number=NewMaxCommit,
                                           status="normal",
                                           last_normal_view=V},
            %% Send StartViewChange message to all replicas
            Msg = #start_view{view_number=V, log=MaxLog, op_number=MaxOp, 
                              commit_number=NewMaxCommit},
            broadcast_message(NewState, Msg),
            {NewState, NewVCState};
        false -> {State, NewVCState}
    end;
handle_do_viewchange(State, VCState, _DoVC) -> {State, VCState}.

handle_start_view(State, StartV) -> 
    NewLog = StartV#start_view.log,
    NewOp = StartV#start_view.op_number,
    NewView = StartV#start_view.view_number,
    NewState = State#replica_state{log=NewLog, 
                                   op_number=NewOp, 
                                   view_number=NewView,
                                   status="normal",
                                   last_normal_view=NewView},
    %% TODO: Need to check if there are uncommitted operations in the log, send
    %% a PrepareOK message to primary for all of them, execute the operations
    %% locally if they have not yet been, and then advance the commit number and
    %% update their client table accordingly. NOTE: Why does the StartView
    %% message include a commit number? Answer: probably because, if all log
    %% entries are committed, we could just immediately update to the latest
    %% commit number.
    %% NOTES:
    %% - try to compare op_number to commit_number sent in the StartV message
    %% - op_number *should* always be synced with the log, but what if it's  not?
    %%   increment the op_number and appending to log is not an atomic operation...
    %% - but basically, if the op_number is greater than the commit_number, we know
    %%   that there are uncommitted operations in the log and should enter that protocol.
    %% - then, somehow, we have to determine what operations haven't been executed...
    NewState.
%% =============================================================================
%% Main execution loop
%% =============================================================================
start() ->
    %% Initialize replica state
    ReplicaCfg = load_config("init_config.txt"),
    ReplicaI = lookup_node_index(node(), ReplicaCfg, 0),
    State = #replica_state{configuration=ReplicaCfg, replica_number=ReplicaI},
    VCState = #viewchange_state{},
    case ReplicaI =:= 0 of
        true -> primary_loop(State, VCState);
        false -> backup_loop(State, VCState)
    end.

primary_loop(State, VCState) ->
    Msg = #commit{view_number=State#replica_state.view_number, 
                  commit_number=State#replica_state.commit_number},
    list:foreach(fun(X) -> X ! Msg end, State#replica_state.configuration),
    receive
        #start_viewchange{view_number=V, replica_number=_I} ->
            {NewState, NewVCState} = handle_start_viewchange(State, VCState, V),
            primary_loop(NewState, NewVCState);
        DoVC when is_record(DoVC, do_viewchange) -> 
            {NewState, NewVCState} = handle_do_viewchange(State, VCState, DoVC),
            %% If a view change has completed and this replica is still the
            %% primary, remain primary--otherwise, become a backup
            ReplicaNum = State#replica_state.replica_number,
            case calculate_primary_from_view(NewState) =:= ReplicaNum of
                %% TODO: If this is the new primary, we need to perform some
                %% actions to catch it up the latest committed operation (if the
                %% replica is not entirely up-to-date)
                true -> primary_loop(NewState, NewVCState);
                false -> backup_loop(NewState, NewVCState)
            end;
        %% Do nothing with StartView message if primary (primary already knows)
        StartV when is_record(StartV, start_view) -> noop
    after
        100 ->
            primary_loop(State, VCState)
    end.

backup_loop(State, VCState) ->
    receive 
        #commit{} -> backup_loop(State, VCState);
        #start_viewchange{view_number=V} -> 
            {NewState, NewVCState} = handle_start_viewchange(State, VCState, V),
            backup_loop(NewState, NewVCState);
        DoVC when is_record(DoVC, do_viewchange) -> 
            {NewState, NewVCState} = handle_do_viewchange(State, VCState, DoVC),
            %% If a view change has completed and this replica is the new 
            %% primary, become the primary--otherwise, remain backup
            ReplicaNum = State#replica_state.replica_number,
            case calculate_primary_from_view(NewState) =:= ReplicaNum of
                %% TODO: If this is the new primary, we need to perform some
                %% actions to catch it up the latest committed operation (if the
                %% replica is not entirely up-to-date)
                true -> primary_loop(NewState, NewVCState);
                false -> backup_loop(NewState, NewVCState)
            end;
        %% TODO: Figure out what to in this case...
        StartV when is_record(StartV, start_view) ->
            handle_start_view(State, StartV)
    after
        %% If the timeout expires without receiving a message from the primary, 
        %% enter view change protocol
        1000 ->
            V = State#replica_state.view_number,
            NewState = State#replica_state{view_number=V+1, status="view-change"},
            Msg = #start_viewchange{view_number=V+1, 
                                    replica_number=State#replica_state.replica_number},
            broadcast_message(NewState, Msg),
            backup_loop(NewState, VCState)
    end.
