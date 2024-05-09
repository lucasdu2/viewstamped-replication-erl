-module(kv).
-behaviour(gen_server).

start_link() ->
    gen_server:start_link(?MODULE, [], []).

%% Client functions
create_entry(Pid, Key, Value) ->
     gen_server:call(Pid, {create, Key, Value}).

delete_entry(Pid, Key) ->
    gen_server:call(Pid, {delete, Key}).

update_value(Pid, Key, Value) ->
    gen_server:call(Pid, {update, Key, Value}).

get_value(Pid, Key) ->
    gen_server:call(Pid, {get, Key}).

%% Server functions
init([]) ->
    {ok, maps:new()}.

handle_call({create, Key, Value}, _From, KV) ->
    NewKV = maps:put(Key, Value, KV),
    {reply, {Key, Value}, NewKV};
handle_call({delete, Key}, _From, KV) ->
    NewKV = maps:remove(Key, KV),
    {reply, deleted, NewKV};
handle_call({update, Key, Value}, _From, KV) ->
    NewKV = maps:update(Key, Value, KV),
    {reply, {Key, Value}, NewKV};
handle_call({get, Key}, _From, KV) ->
    Value = maps:get(Key, KV),
    {reply, Value, KV}.

handle_cast(_Msg, State) ->
    {noreply, State}.
handle_info(_Info, State) ->
    {noreply, State}.
terminate(_Reason, _State) ->
    ok.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
