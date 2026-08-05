-module(iroh_dist).
-moduledoc false.

-export([childspecs/0,
         listen/1, listen/2,
         accept/1, accept_connection/5,
         setup/5, close/1,
         select/1, address/0, address/1,
         accept_loop/2]).

-include_lib("kernel/include/net_address.hrl").

-define(PROTOCOL, iroh).
-define(FAMILY, iroh).
-define(NOT_READY, {iroh_distribution, handshake_not_ready}).

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
                    exit(unsupported_protocol)
            end;
        {error, Reason} -> exit(Reason)
    catch
        exit:Reason -> exit(Reason)
    end.

-spec accept_connection(pid(), term(), node(), [node()], timeout()) -> pid().
accept_connection(_AcceptPid, _Session, _MyNode, _Allowed, _SetupTime) ->
    spawn(fun not_ready/0).

-spec setup(node(), term(), node(), term(), timeout()) -> pid().
setup(_Node, _Type, _MyNode, _LongOrShortNames, _SetupTime) ->
    spawn(fun not_ready/0).

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

not_ready() ->
    receive
    after 1 -> exit(?NOT_READY)
    end.
