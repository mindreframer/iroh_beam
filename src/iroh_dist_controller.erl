-module(iroh_dist_controller).
-moduledoc false.

-export([start_link/1, handshake_complete/3, tick/1, close/1,
         parser_new/0, parser_feed/3]).

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
    receive
        {handshake_complete, From, Ref, Node, DistHandle} ->
            start_controller(Parent, Session, Node, DistHandle, From, Ref);
        close ->
            close_session(undefined, Session);
        {'EXIT', Parent, Reason} ->
            close_session(undefined, Session),
            exit(Reason)
    end.

start_controller(Parent, Session, Node, DistHandle, From, Ref) ->
    Controller = self(),
    Input =
        spawn_link(
          fun () ->
                  receive
                      {Controller, start} ->
                          input_loop(Session, DistHandle, parser_new())
                  end
          end),
    false = erlang:dist_ctrl_set_opt(DistHandle, get_size, true),
    ok = erlang:dist_ctrl_input_handler(DistHandle, Input),
    Input ! {Controller, start},
    ok = iroh_dist_endpoint:register_link(Node, Session, self()),
    From ! {Ref, ok},
    try
        erlang:dist_ctrl_get_data_notification(DistHandle),
        output_wait(Parent, Input, Session, DistHandle, Node)
    catch
        Class:Reason:Stacktrace ->
            exit({distribution_controller, Class, safe_reason(Reason),
                  sanitize_stacktrace(Stacktrace)})
    after
        _ = iroh_dist_endpoint:unregister_link(Node, self()),
        _ = iroh_dist_endpoint:close_session(Session)
    end.

output_wait(Parent, Input, Session, DistHandle, Node) ->
    receive
        dist_data ->
            output_data(Parent, Input, Session, DistHandle, Node);
        dist_tick ->
            ok = send_packet(Session, 0, []),
            output_wait(Parent, Input, Session, DistHandle, Node);
        close ->
            exit(normal);
        {'EXIT', Parent, Reason} ->
            exit(Reason);
        {'EXIT', Input, Reason} ->
            exit({input_handler, safe_reason(Reason)});
        {'EXIT', _Pid, _Reason} ->
            output_wait(Parent, Input, Session, DistHandle, Node);
        _Other ->
            output_wait(Parent, Input, Session, DistHandle, Node)
    end.

output_data(Parent, Input, Session, DistHandle, Node) ->
    case erlang:dist_ctrl_get_data(DistHandle) of
        none ->
            erlang:dist_ctrl_get_data_notification(DistHandle),
            output_wait(Parent, Input, Session, DistHandle, Node);
        {Length, Iovec} when is_integer(Length), Length >= 0 ->
            MaxFrame = maps:get(max_frame, Session),
            case Length =< MaxFrame of
                true ->
                    ok = send_packet(Session, Length, Iovec),
                    output_data(Parent, Input, Session, DistHandle, Node);
                false ->
                    exit({frame_too_large, Length})
            end
    end.

send_packet(Session, Length, Iovec) ->
    IO = 'Elixir.IrohBeam.Distribution.IO',
    Stream = maps:get(stream, Session),
    Timeout = maps:get(stream_timeout, Session),
    MaxFrame = maps:get(max_frame, Session),
    IO:send_iodata(Stream, [<<Length:32>>, Iovec], Length + 4,
                   MaxFrame + 4, Timeout).

input_loop(Session, DistHandle, Parser) ->
    IO = 'Elixir.IrohBeam.Distribution.IO',
    Stream = maps:get(stream, Session),
    ChunkSize = maps:get(receive_chunk, Session),
    Timeout = erlang:max(maps:get(stream_timeout, Session), 60000),
    case IO:recv(Stream, ChunkSize, Timeout) of
        {ok, Data} ->
            case parser_feed(Parser, Data, maps:get(max_frame, Session)) of
                {ok, Packets, Parser1} ->
                    lists:foreach(
                      fun (Packet) ->
                              ok = erlang:dist_ctrl_put_data(DistHandle, Packet)
                      end,
                      Packets),
                    input_loop(Session, DistHandle, Parser1);
                {error, Reason} ->
                    exit(Reason)
            end;
        eof ->
            exit(closed);
        {error, Reason} ->
            exit(safe_reason(Reason))
    end.

-spec parser_new() -> tuple().
parser_new() ->
    {header, <<>>}.

-spec parser_feed(tuple(), binary(), non_neg_integer()) ->
          {ok, [iodata()], tuple()} | {error, term()}.
parser_feed(Parser, Data, MaxFrame)
  when is_binary(Data), is_integer(MaxFrame), MaxFrame >= 0 ->
    parser_feed(Parser, Data, MaxFrame, []).

parser_feed({header, Header}, Data, MaxFrame, Packets) ->
    Need = 4 - byte_size(Header),
    case byte_size(Data) < Need of
        true ->
            {ok, lists:reverse(Packets),
             {header, <<Header/binary, Data/binary>>}};
        false ->
            <<HeaderPart:Need/binary, Rest/binary>> = Data,
            <<Length:32>> = <<Header/binary, HeaderPart/binary>>,
            case Length =< MaxFrame of
                true -> parser_feed({body, Length, [], 0}, Rest,
                                    MaxFrame, Packets);
                false -> {error, {frame_too_large, Length}}
            end
    end;
parser_feed({body, Length, Chunks, Size}, Data, MaxFrame, Packets) ->
    Remaining = Length - Size,
    case byte_size(Data) < Remaining of
        true ->
            Chunks1 = case Data of <<>> -> Chunks; _ -> [Data | Chunks] end,
            {ok, lists:reverse(Packets),
             {body, Length, Chunks1, Size + byte_size(Data)}};
        false ->
            <<Last:Remaining/binary, Rest/binary>> = Data,
            PacketChunks =
                case Last of
                    <<>> -> Chunks;
                    _ -> [Last | Chunks]
                end,
            Packet = lists:reverse(PacketChunks),
            parser_feed({header, <<>>}, Rest, MaxFrame,
                        [Packet | Packets])
    end.

close_session(undefined, Session) ->
    _ = iroh_dist_endpoint:close_session(Session),
    exit(normal);
close_session(Node, Session) ->
    _ = iroh_dist_endpoint:unregister_link(Node, self()),
    _ = iroh_dist_endpoint:close_session(Session),
    exit(normal).

safe_reason(Error) when is_map(Error) ->
    #{category => maps:get(category, Error, internal),
      operation => maps:get(operation, Error, distribution_controller)};
safe_reason(Reason) -> Reason.

sanitize_stacktrace(Stacktrace) ->
    [{Module, Function, Arity} ||
        {Module, Function, Arity, _Info} <- Stacktrace].
