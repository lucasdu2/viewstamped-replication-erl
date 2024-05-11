-module(kv).
-behaviour(gen_server).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).
-export([start_link/0, create_entry/3, delete_entry/2, update_value/3,
         get_value/2]).

%% NOTE: From the documentation, if a callback function fails or returns a bad
%%% value, the gen_server process terminates.

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
    io:format("I'm here!~n"),
    {ok, maps:new()}.

handle_call({create, Key, Value}, _From, KV) ->
    NewKV = maps:put(Key, Value, KV),
    {reply, {Key, Value}, NewKV};
handle_call({delete, Key}, _From, KV) ->
    NewKV = maps:remove(Key, KV),
    {reply, deleted, NewKV};
handle_call({update, Key, Value}, _From, KV) ->
    %% Handle smoothly if value does not exist
    try NewKV = maps:update(Key, Value, KV) of
        _ ->
            {reply, {Key, Value}, NewKV}
    catch
        error:{badkey, _Key} ->
            {reply, badkey, KV}
    end;
handle_call({get, Key}, _From, KV) ->
    %% Handle smoothly if value does not exist
    try Value = maps:get(Key, KV) of
        _ ->
            {reply, {Key, Value}, KV}
    catch
        error:{badkey, _Key} ->
            {reply, badkey, KV}
    end.

handle_cast(_Msg, KV) ->
    {noreply, KV}.
handle_info(_Info, State) ->
    {noreply, State}.
terminate(_Reason, _State) ->
    ok.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
