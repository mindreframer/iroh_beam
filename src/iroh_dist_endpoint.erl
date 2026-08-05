-module(iroh_dist_endpoint).
-moduledoc false.

-behaviour(gen_server).

-export([start_link/0, status/0, stop/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2]).

-record(state, {started_at}).

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec status() -> {ok, map()} | {error, not_started}.
status() ->
    case whereis(?MODULE) of
        undefined -> {error, not_started};
        _Pid -> gen_server:call(?MODULE, status)
    end.

-spec stop() -> ok.
stop() ->
    case whereis(?MODULE) of
        undefined -> ok;
        _Pid -> gen_server:stop(?MODULE)
    end.

init([]) ->
    case iroh_dist_support:check() of
        ok ->
            {ok, #state{started_at = erlang:monotonic_time()}};
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call(status, _From, State) ->
    Reply = #{state => inert,
              network_started => false,
              started_at => State#state.started_at},
    {reply, {ok, Reply}, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_call}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.
