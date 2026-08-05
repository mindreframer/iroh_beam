-module(iroh_dist_endpoint).
-moduledoc false.

-behaviour(gen_server).

-export([start_link/0, status/0, peer_info/1, listener/0,
         resolve/1, allowed_nodes/0, validate_peer/2, validate_preface/3,
         connect/1, take_incoming/1, register_link/3, unregister_link/2,
         close_session/1, stop/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2]).

-record(state, {config,
                endpoint,
                endpoint_id,
                endpoint_addr,
                creation,
                acceptor,
                incoming = queue:new(),
                waiter = undefined,
                links = #{}}).

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec status() -> {ok, map()} | {error, not_started}.
status() ->
    call_if_started(status).

-spec peer_info(node()) -> {ok, map()} | {error, term()}.
peer_info(Node) ->
    call_if_started({peer_info, Node}).

-spec listener() -> {ok, map()} | {error, term()}.
listener() ->
    call_if_started(listener).

-spec resolve(node()) -> {ok, map()} | {error, term()}.
resolve(Node) ->
    call_if_started({resolve, Node}).

-spec allowed_nodes() -> [node()].
allowed_nodes() ->
    call_if_started(allowed_nodes).

-spec validate_peer(node(), term()) -> ok | {error, term()}.
validate_peer(Node, RemoteId) ->
    call_if_started({validate_peer, Node, RemoteId}).

-spec validate_preface(binary(), term(), binary()) ->
          {ok, node()} | {error, term()}.
validate_preface(RemoteName, RemoteId, TargetName) ->
    call_if_started({validate_preface, RemoteName, RemoteId, TargetName}).

-spec connect(node()) -> {ok, map()} | {error, term()}.
connect(Node) ->
    case resolve(Node) of
        {ok, Peer} -> connect_peer(Peer);
        {error, _} = Error -> Error
    end.

-spec take_incoming(timeout()) -> {ok, map()} | {error, term()}.
take_incoming(Timeout) ->
    gen_server:call(?MODULE, take_incoming, Timeout).

-spec register_link(node(), map(), pid()) -> ok.
register_link(Node, Session, Owner) ->
    gen_server:call(?MODULE, {register_link, Node, Session, Owner}).

-spec unregister_link(node(), pid()) -> ok.
unregister_link(Node, Owner) ->
    gen_server:call(?MODULE, {unregister_link, Node, Owner}).

-spec stop() -> ok.
stop() ->
    case whereis(?MODULE) of
        undefined -> ok;
        _Pid ->
            try gen_server:stop(?MODULE) of
                ok -> ok
            catch
                exit:_Reason -> ok
            end
    end.

init([]) ->
    process_flag(trap_exit, true),
    case iroh_dist_support:check() of
        ok -> init_endpoint();
        {error, Reason} -> {stop, Reason}
    end.

init_endpoint() ->
    ConfigMod = 'Elixir.IrohBeam.Distribution.Config',
    EndpointMod = 'Elixir.IrohBeam.Endpoint',
    case ConfigMod:load() of
        {ok, Config} ->
            Options = ConfigMod:endpoint_options(Config),
            case EndpointMod:start_link(Options) of
                {ok, Endpoint} ->
                    case EndpointMod:await_online(
                           Endpoint, maps:get(startup_timeout, Config)) of
                        ok -> finish_init(Config, Endpoint);
                        {error, Reason} ->
                            _ = EndpointMod:close(Endpoint),
                            {stop, {endpoint_online, safe_reason(Reason)}}
                    end;
                {error, Reason} ->
                    {stop, {endpoint_start, safe_reason(Reason)}}
            end;
        {error, Reason} ->
            {stop, {distribution_config, safe_reason(Reason)}}
    end.

finish_init(Config, Endpoint) ->
    EndpointMod = 'Elixir.IrohBeam.Endpoint',
    {ok, Id} = EndpointMod:id(Endpoint),
    {ok, Addr} = EndpointMod:addr(Endpoint),
    Owner = self(),
    Acceptor = spawn_link(fun () -> accept_loop(Owner, Endpoint, Config) end),
    {ok, #state{config = Config,
                endpoint = Endpoint,
                endpoint_id = Id,
                endpoint_addr = Addr,
                creation = iroh_dist_support:new_creation(),
                acceptor = Acceptor}}.

handle_call(status, _From, State) ->
    ConfigMod = 'Elixir.IrohBeam.Distribution.Config',
    Safe = ConfigMod:safe(State#state.config),
    Reply = Safe#{ready => true,
                  endpoint_id => State#state.endpoint_id,
                  endpoint_addr => State#state.endpoint_addr,
                  pending_incoming => queue:len(State#state.incoming),
                  active_links => map_size(State#state.links)},
    {reply, {ok, Reply}, State};
handle_call(listener, _From, State) ->
    Reply = #{pid => self(),
              endpoint_id => State#state.endpoint_id,
              endpoint_addr => State#state.endpoint_addr,
              creation => State#state.creation},
    {reply, {ok, Reply}, State};
handle_call({resolve, Node}, _From, State) ->
    ConfigMod = 'Elixir.IrohBeam.Distribution.Config',
    Reply =
        case ConfigMod:resolve(State#state.config, Node) of
            {ok, Peer} ->
                {ok, Peer#{endpoint => State#state.endpoint,
                           connect_timeout => maps:get(connect_timeout, State#state.config),
                           stream_timeout => maps:get(stream_timeout, State#state.config),
                           receive_chunk => maps:get(receive_chunk, State#state.config),
                           max_frame => maps:get(max_frame, State#state.config)}};
            {error, Reason} -> {error, Reason}
        end,
    {reply, Reply, State};
handle_call(allowed_nodes, _From, State) ->
    ConfigMod = 'Elixir.IrohBeam.Distribution.Config',
    {reply, ConfigMod:allowed_nodes(State#state.config), State};
handle_call({validate_peer, Node, RemoteId}, _From, State) ->
    ConfigMod = 'Elixir.IrohBeam.Distribution.Config',
    Reply =
        case ConfigMod:expected_id(State#state.config, Node) of
            {ok, RemoteId} -> ok;
            {ok, _OtherId} -> {error, identity_mismatch};
            {error, Reason} -> {error, Reason}
        end,
    {reply, Reply, State};
handle_call({validate_preface, RemoteName, RemoteId, TargetName},
            _From, State) ->
    ConfigMod = 'Elixir.IrohBeam.Distribution.Config',
    Reply = ConfigMod:authorize_claim(
              State#state.config, RemoteName, RemoteId, TargetName),
    {reply, Reply, State};
handle_call({peer_info, Node}, _From, State) ->
    ConfigMod = 'Elixir.IrohBeam.Distribution.Config',
    Reply =
        case ConfigMod:resolve(State#state.config, Node) of
            {ok, Peer} ->
                Link = maps:get(Node, State#state.links, undefined),
                SafeLink =
                    case Link of
                        undefined -> undefined;
                        _ -> maps:without([owner], Link)
                    end,
                {ok, #{node => Node,
                       expected_id => maps:get(id, Peer),
                       state => case Link of undefined -> configured; _ -> connected end,
                       link => SafeLink}};
            {error, Reason} -> {error, Reason}
        end,
    {reply, Reply, State};
handle_call({register_link, Node, Session, Owner}, _From, State) ->
    Connection = maps:get(connection, Session),
    Path =
        case 'Elixir.IrohBeam.Connection':path(Connection) of
            {ok, Value} -> Value;
            _ -> undefined
        end,
    Link = #{owner => Owner,
             remote_id => maps:get(remote_id, Session),
             path => Path},
    {reply, ok, State#state{links = maps:put(Node, Link, State#state.links)}};
handle_call({unregister_link, Node, Owner}, _From, State) ->
    Links =
        case maps:get(Node, State#state.links, undefined) of
            #{owner := Owner} -> maps:remove(Node, State#state.links);
            _ -> State#state.links
        end,
    {reply, ok, State#state{links = Links}};
handle_call(take_incoming, From, #state{waiter = undefined} = State) ->
    case queue:out(State#state.incoming) of
        {{value, Session}, Queue} ->
            {reply, {ok, Session}, State#state{incoming = Queue}};
        {empty, _Queue} ->
            {noreply, State#state{waiter = From}}
    end;
handle_call(take_incoming, _From, State) ->
    {reply, {error, busy}, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_call}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({incoming, Session}, #state{waiter = undefined} = State) ->
    case queue:len(State#state.incoming) of
        0 -> {noreply, State#state{incoming = queue:in(Session, State#state.incoming)}};
        _ ->
            close_session(Session),
            {noreply, State}
    end;
handle_info({incoming, Session}, #state{waiter = From} = State) ->
    gen_server:reply(From, {ok, Session}),
    {noreply, State#state{waiter = undefined}};
handle_info({'EXIT', Pid, normal}, #state{endpoint = Pid} = State) ->
    {stop, endpoint_closed, State};
handle_info({'EXIT', Pid, Reason}, #state{endpoint = Pid} = State) ->
    {stop, {endpoint_exit, Reason}, State};
handle_info({'EXIT', Pid, Reason}, #state{acceptor = Pid} = State) ->
    {stop, {acceptor_exit, Reason}, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    close_queued(State#state.incoming),
    EndpointMod = 'Elixir.IrohBeam.Endpoint',
    case is_process_alive(State#state.endpoint) of
        true ->
            unlink(State#state.endpoint),
            _ = EndpointMod:close(State#state.endpoint,
                                  maps:get(shutdown_timeout, State#state.config));
        false -> ok
    end,
    ok.

accept_loop(Owner, Endpoint, Config) ->
    EndpointMod = 'Elixir.IrohBeam.Endpoint',
    ConnectionMod = 'Elixir.IrohBeam.Connection',
    Timeout = maps:get(accept_timeout, Config),
    StreamTimeout = maps:get(stream_timeout, Config),
    case EndpointMod:accept(Endpoint, [{timeout, Timeout}]) of
        {ok, Connection} ->
            case ConnectionMod:accept_bi(Connection, [{timeout, StreamTimeout}]) of
                {ok, Stream} ->
                    Info = #{connection => Connection,
                             stream => Stream,
                             remote_id => ConnectionMod:remote_id(Connection),
                             stream_timeout => StreamTimeout,
                             receive_chunk => maps:get(receive_chunk, Config),
                             max_frame => maps:get(max_frame, Config)},
                    case iroh_dist_preface:incoming(Info) of
                        {ok, Session} -> Owner ! {incoming, Session};
                        {error, _Reason} -> close_session(Info)
                    end;
                {error, _Reason} ->
                    _ = ConnectionMod:close(Connection)
            end,
            accept_loop(Owner, Endpoint, Config);
        {error, Error} ->
            case error_category(Error) of
                timeout -> accept_loop(Owner, Endpoint, Config);
                unauthorized -> accept_loop(Owner, Endpoint, Config);
                closed -> exit(normal);
                _ -> accept_loop(Owner, Endpoint, Config)
            end
    end.

call_if_started(Request) ->
    case whereis(?MODULE) of
        undefined -> {error, not_started};
        _Pid -> gen_server:call(?MODULE, Request)
    end.

error_category(Error) when is_map(Error) -> maps:get(category, Error, internal);
error_category(_) -> internal.

safe_reason(Error) when is_map(Error) ->
    #{category => maps:get(category, Error, internal),
      operation => maps:get(operation, Error, distribution)};
safe_reason(Reason) -> Reason.

close_queued(Queue) ->
    case queue:out(Queue) of
        {{value, Session}, Rest} -> close_session(Session), close_queued(Rest);
        {empty, _} -> ok
    end.

connect_peer(Peer) ->
    EndpointMod = 'Elixir.IrohBeam.Endpoint',
    ConnectionMod = 'Elixir.IrohBeam.Connection',
    Endpoint = maps:get(endpoint, Peer),
    Target = maps:get(target, Peer),
    ConnectTimeout = maps:get(connect_timeout, Peer),
    StreamTimeout = maps:get(stream_timeout, Peer),
    case EndpointMod:connect(
           Endpoint, Target,
           'Elixir.IrohBeam.Distribution.Config':alpn(),
           [{timeout, ConnectTimeout}]) of
        {ok, Connection} ->
            RemoteId = ConnectionMod:remote_id(Connection),
            case RemoteId =:= maps:get(id, Peer) of
                true ->
                    case ConnectionMod:open_bi(
                           Connection, [{timeout, StreamTimeout}]) of
                        {ok, Stream} ->
                            {ok, #{connection => Connection,
                                   stream => Stream,
                                   remote_id => RemoteId,
                                   stream_timeout => StreamTimeout,
                                   receive_chunk =>  maps:get(receive_chunk, Peer, 65536),
                                   max_frame => maps:get(max_frame, Peer, 16777216)}};
                        {error, Reason} ->
                            _ = ConnectionMod:close(Connection),
                            {error, Reason}
                    end;
                false ->
                    _ = ConnectionMod:close(Connection),
                    {error, identity_mismatch}
            end;
        {error, _} = Error -> Error
    end.

close_session(#{stream := Stream, connection := Connection}) ->
    _ = 'Elixir.IrohBeam.Stream':abort(Stream),
    _ = 'Elixir.IrohBeam.Connection':close(Connection),
    ok.
