-module(iroh_dist).
-moduledoc false.

-export([childspecs/0,
         listen/1, listen/2,
         accept/1, accept_connection/5,
         setup/5, close/1,
         select/1, address/0, address/1,
         accept_loop/2, do_accept/6, do_setup/6,
         packet2_frame/1, packet2_send/2, packet2_recv/1]).

-include_lib("kernel/include/net_address.hrl").
-include_lib("kernel/include/dist.hrl").
-include_lib("kernel/include/dist_util.hrl").

-define(PROTOCOL, iroh).
-define(FAMILY, iroh).

-spec childspecs() -> {ok, [supervisor:child_spec()]} | {error, term()}.
childspecs() ->
    case iroh_dist_support:check() of
        ok ->
            {ok,
             [#{id => iroh_dist_endpoint,
                start => {iroh_dist_endpoint, start_link, []},
                restart => permanent,
                shutdown => 5000,
                type => worker,
                modules => [iroh_dist_endpoint]}]};
        {error, _} = Error ->
            Error
    end.

-spec address() -> #net_address{}.
address() ->
    Host =
        case inet:gethostname() of
            {ok, Value} -> Value;
            _ -> "nohost"
        end,
    address(Host).

-spec address(string()) -> #net_address{}.
address(Host) when is_list(Host) ->
    #net_address{host = Host, protocol = ?PROTOCOL, family = ?FAMILY}.

-spec listen(atom()) -> {ok, {pid(), #net_address{}, integer()}} | {error, term()}.
listen(Name) when is_atom(Name) ->
    case inet:gethostname() of
        {ok, Host} -> listen(Name, Host);
        {error, Reason} -> {error, {hostname, Reason}}
    end.

-spec listen(atom(), string()) ->
          {ok, {pid(), #net_address{}, integer()}} | {error, term()}.
listen(_Name, Host) ->
    case iroh_dist_support:check() of
        ok ->
            case iroh_dist_endpoint:listener() of
                {ok, Listener} ->
                    NetAddress =
                        (address(Host))#net_address{
                          address = maps:get(endpoint_id, Listener)},
                    {ok, {maps:get(pid, Listener), NetAddress,
                          maps:get(creation, Listener)}};
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

-spec accept(pid()) -> pid().
accept(Listen) when is_pid(Listen) ->
    spawn_link(?MODULE, accept_loop, [self(), Listen]).

accept_loop(Kernel, Listen) ->
    try iroh_dist_endpoint:take_incoming(infinity) of
        {ok, Session} ->
            Kernel ! {accept, self(), Session, ?FAMILY, ?PROTOCOL},
            receive
                {Kernel, controller, Controller} ->
                    Controller ! {self(), controller},
                    accept_loop(Kernel, Listen);
                {Kernel, unsupported_protocol} ->
                    iroh_dist_endpoint:close_session(Session),
                    exit(unsupported_protocol)
            end;
        {error, Reason} -> exit(Reason)
    catch
        exit:Reason -> exit(Reason)
    end.

-spec accept_connection(pid(), map(), node(), [node()], timeout()) -> pid().
accept_connection(AcceptPid, Session, MyNode, _Allowed, SetupTime) ->
    spawn_opt(?MODULE, do_accept,
              [self(), AcceptPid, Session, MyNode, SetupTime,
               iroh_dist_endpoint:allowed_nodes()],
              dist_util:net_ticker_spawn_options()).

do_accept(Kernel, AcceptPid, Session, MyNode, SetupTime, Allowed) ->
    receive
        {AcceptPid, controller} ->
            Timer = dist_util:start_timer(SetupTime),
            Controller = iroh_dist_controller:start_link(Session),
            HSData =
                (hs_data(Session, Controller))#hs_data{
                  kernel_pid = Kernel,
                  this_node = MyNode,
                  timer = Timer,
                  this_flags = 0,
                  allowed = Allowed},
            dist_util:handshake_other_started(HSData)
    end.

-spec setup(node(), term(), node(), term(), timeout()) -> pid().
setup(Node, Type, MyNode, LongOrShortNames, SetupTime) ->
    spawn_opt(?MODULE, do_setup,
              [self(), Node, Type, MyNode, LongOrShortNames, SetupTime],
              dist_util:net_ticker_spawn_options()).

do_setup(Kernel, Node, Type, MyNode, _LongOrShortNames, SetupTime) ->
    Timer = dist_util:start_timer(SetupTime),
    case iroh_dist_endpoint:connect(Node) of
        {ok, Session} ->
            case iroh_dist_preface:outgoing(Session, MyNode, Node) of
                ok ->
                    dist_util:reset_timer(Timer),
                    Controller = iroh_dist_controller:start_link(Session),
                    HSData =
                        (hs_data(Session, Controller))#hs_data{
                          kernel_pid = Kernel,
                          other_node = Node,
                          this_node = MyNode,
                          timer = Timer,
                          this_flags = 0,
                          other_version = ?ERL_DIST_VER_6,
                          request_type = Type},
                    dist_util:handshake_we_started(HSData);
                {error, Reason} ->
                    iroh_dist_endpoint:close_session(Session),
                    ?shutdown2(Node, {iroh_preface, safe_reason(Reason)})
            end;
        {error, Reason} ->
            ?shutdown2(Node, {iroh_connect, safe_reason(Reason)})
    end.

hs_data(Session, Controller) ->
    #hs_data{
       socket = Session,
       f_send = fun ?MODULE:packet2_send/2,
       f_recv =
           fun (S, 0, infinity) when S =:= Session ->
                   ?MODULE:packet2_recv(S)
           end,
       f_setopts_pre_nodeup = ok_fun(Session),
       f_setopts_post_nodeup = ok_fun(Session),
       f_getll =
           fun (S) when S =:= Session -> {ok, Controller} end,
       f_address =
           fun (S, Node) when S =:= Session ->
                   peer_address(S, Node)
           end,
       f_handshake_complete =
           fun (S, Node, DistHandle) when S =:= Session ->
                   iroh_dist_controller:handshake_complete(
                     Controller, Node, DistHandle)
           end,
       mf_tick =
           fun (S) when S =:= Session ->
                   iroh_dist_controller:tick(Controller)
           end}.

-spec packet2_frame(iodata()) -> {ok, binary()} | {error, emsgsize}.
packet2_frame(Packet) ->
    Size = iolist_size(Packet),
    case Size < 1 bsl 16 of
        true -> {ok, iolist_to_binary([<<Size:16>>, Packet])};
        false -> {error, emsgsize}
    end.

-spec packet2_send(map(), iodata()) -> ok | {error, term()}.
packet2_send(Session, Packet) ->
    case packet2_frame(Packet) of
        {ok, Frame} -> send_binary(Session, Frame);
        {error, _} = Error -> Error
    end.

-spec packet2_recv(map()) -> {ok, [byte()]} | {error, term()}.
packet2_recv(Session) ->
    case recv_exact(Session, 2, []) of
        {ok, <<Size:16>>} ->
            case recv_exact(Session, Size, []) of
                {ok, Data} -> {ok, binary_to_list(Data)};
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

send_binary(Session, Data) ->
    StreamMod = 'Elixir.IrohBeam.Stream',
    Stream = maps:get(stream, Session),
    Timeout = maps:get(stream_timeout, Session),
    case StreamMod:send(Stream, Data, [{timeout, Timeout},
                                       {max_bytes, 65537}]) of
        ok -> ok;
        {error, Reason} -> {error, safe_reason(Reason)}
    end.

recv_exact(_Session, 0, Chunks) ->
    {ok, iolist_to_binary(lists:reverse(Chunks))};
recv_exact(Session, Remaining, Chunks) ->
    StreamMod = 'Elixir.IrohBeam.Stream',
    Stream = maps:get(stream, Session),
    Timeout = maps:get(stream_timeout, Session),
    case StreamMod:recv(Stream, Remaining, [{timeout, Timeout}]) of
        {ok, Data} when byte_size(Data) > 0 ->
            recv_exact(Session, Remaining - byte_size(Data), [Data | Chunks]);
        eof ->
            {error, closed};
        {error, Reason} ->
            {error, safe_reason(Reason)}
    end.

peer_address(Session, Node) ->
    RemoteId = maps:get(remote_id, Session),
    case iroh_dist_endpoint:validate_peer(Node, RemoteId) of
        ok ->
            case dist_util:split_node(Node) of
                {node, _Name, Host} ->
                    #net_address{address = RemoteId,
                                 host = Host,
                                 protocol = ?PROTOCOL,
                                 family = ?FAMILY};
                Other ->
                    ?shutdown2(Node, {split_node, Other})
            end;
        {error, Reason} ->
            ?shutdown2(Node, {identity_binding, Reason})
    end.

ok_fun(Session) ->
    fun (S) when S =:= Session -> ok end.

-spec close(term()) -> ok.
close(_Listen) ->
    ok.

-spec select(term()) -> boolean().
select(Node) when is_atom(Node) ->
    case iroh_dist_endpoint:resolve(Node) of
        {ok, _Peer} -> true;
        _ -> false
    end;
select(_Node) ->
    false.

safe_reason(Error) when is_map(Error) ->
    #{category => maps:get(category, Error, internal),
      operation => maps:get(operation, Error, distribution)};
safe_reason(Reason) -> Reason.
