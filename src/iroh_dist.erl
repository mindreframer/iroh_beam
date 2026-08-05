-module(iroh_dist).
-moduledoc false.

-export([childspecs/0,
         listen/1, listen/2,
         accept/1, accept_connection/5,
         setup/5, close/1,
         select/1, address/0, address/1]).

-include_lib("kernel/include/net_address.hrl").

-define(PROTOCOL, iroh).
-define(FAMILY, iroh).
-define(NOT_READY, {iroh_distribution, not_ready}).

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

-spec listen(atom()) -> {error, term()}.
listen(Name) when is_atom(Name) ->
    case inet:gethostname() of
        {ok, Host} -> listen(Name, Host);
        {error, Reason} -> {error, {hostname, Reason}}
    end.

-spec listen(atom(), string()) -> {error, term()}.
listen(_Name, _Host) ->
    case iroh_dist_support:check() of
        ok ->
            case whereis(iroh_dist_endpoint) of
                undefined -> {error, {iroh_distribution, endpoint_not_started}};
                _Pid -> {error, ?NOT_READY}
            end;
        {error, _} = Error -> Error
    end.

-spec accept(term()) -> pid().
accept(_Listen) ->
    spawn(fun not_ready/0).

-spec accept_connection(pid(), term(), node(), [node()], timeout()) -> pid().
accept_connection(_AcceptPid, _Socket, _MyNode, _Allowed, _SetupTime) ->
    spawn(fun not_ready/0).

-spec setup(node(), term(), node(), term(), timeout()) -> pid().
setup(_Node, _Type, _MyNode, _LongOrShortNames, _SetupTime) ->
    spawn(fun not_ready/0).

-spec close(term()) -> ok.
close(_Listen) ->
    ok.

-spec select(term()) -> false.
select(_Node) ->
    false.

not_ready() ->
    receive
    after 1 -> exit(?NOT_READY)
    end.
