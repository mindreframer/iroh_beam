-module(iroh_dist_controller).
-moduledoc false.

-export([start_link/1, handshake_complete/3, tick/1, close/1]).

-spec start_link(map()) -> pid().
start_link(Session) ->
    Parent = self(),
    spawn_link(fun () -> holder(Parent, Session) end).

-spec handshake_complete(pid(), node(), term()) -> ok.
handshake_complete(Controller, Node, DistHandle) ->
    Ref = make_ref(),
    Controller ! {handshake_complete, self(), Ref, Node, DistHandle},
    receive
        {Ref, ok} -> ok
    after 5000 ->
        exit({distribution_controller, handshake_complete_timeout})
    end.

-spec tick(pid()) -> ok.
tick(Controller) ->
    Controller ! dist_tick,
    ok.

-spec close(pid()) -> ok.
close(Controller) ->
    Controller ! close,
    ok.

holder(Parent, Session) ->
    process_flag(trap_exit, true),
    link(Parent),
    holder_loop(Parent, Session, undefined, undefined).

holder_loop(Parent, Session, Node, DistHandle) ->
    receive
        {handshake_complete, From, Ref, PeerNode, Handle} ->
            ok = iroh_dist_endpoint:register_link(PeerNode, Session, self()),
            From ! {Ref, ok},
            holder_loop(Parent, Session, PeerNode, Handle);
        dist_tick ->
            holder_loop(Parent, Session, Node, DistHandle);
        close ->
            close_session(Node, Session);
        {'EXIT', Parent, _Reason} ->
            close_session(Node, Session);
        {'EXIT', _Pid, _Reason} ->
            holder_loop(Parent, Session, Node, DistHandle);
        _Other ->
            holder_loop(Parent, Session, Node, DistHandle)
    end.

close_session(undefined, Session) ->
    _ = iroh_dist_endpoint:close_session(Session),
    exit(normal);
close_session(Node, Session) ->
    _ = iroh_dist_endpoint:unregister_link(Node, self()),
    _ = iroh_dist_endpoint:close_session(Session),
    exit(normal).
