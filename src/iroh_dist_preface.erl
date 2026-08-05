-module(iroh_dist_preface).
-moduledoc false.

-export([outgoing/3, incoming/1]).

-define(MAGIC, <<"IROHDIST1">>).
-define(MAX_NAME, 255).

-spec outgoing(map(), node(), node()) -> ok | {error, term()}.
outgoing(Session, LocalNode, RemoteNode)
  when is_atom(LocalNode), is_atom(RemoteNode) ->
    Local = atom_to_binary(LocalNode, utf8),
    Remote = atom_to_binary(RemoteNode, utf8),
    case byte_size(Local) =< ?MAX_NAME andalso
         byte_size(Remote) =< ?MAX_NAME of
        true ->
            Frame = <<?MAGIC/binary,
                      (byte_size(Local)):16,
                      (byte_size(Remote)):16,
                      Local/binary, Remote/binary>>,
            case send(Session, Frame) of
                ok ->
                    case recv_exact(Session, 1, []) of
                        {ok, <<1>>} -> ok;
                        {ok, _Other} -> {error, unauthorized};
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        false ->
            {error, invalid_node_name}
    end.

-spec incoming(map()) -> {ok, map()} | {error, term()}.
incoming(Session) ->
    HeaderSize = byte_size(?MAGIC) + 4,
    case recv_exact(Session, HeaderSize, []) of
        {ok, <<Magic:9/binary, RemoteSize:16, TargetSize:16>>}
          when Magic =:= ?MAGIC,
               RemoteSize =< ?MAX_NAME, TargetSize =< ?MAX_NAME ->
            case recv_exact(Session, RemoteSize + TargetSize, []) of
                {ok, Names} ->
                    <<Remote:RemoteSize/binary, Target:TargetSize/binary>> = Names,
                    RemoteId = maps:get(remote_id, Session),
                    case iroh_dist_endpoint:validate_preface(
                           Remote, RemoteId, Target) of
                        {ok, Node} ->
                            case send(Session, <<1>>) of
                                ok -> {ok, Session#{claimed_node => Node}};
                                {error, _} = Error -> Error
                            end;
                        {error, _} = Error ->
                            _ = 'Elixir.IrohBeam.Distribution.Telemetry':rejected(
                                  name_binding),
                            Error
                    end;
                {error, _} = Error -> Error
            end;
        {ok, _Malformed} -> {error, malformed_preface};
        {error, _} = Error -> Error
    end.

send(Session, Data) ->
    Stream = maps:get(stream, Session),
    Timeout = maps:get(stream_timeout, Session),
    case 'Elixir.IrohBeam.Stream':send(
           Stream, Data, [{timeout, Timeout}, {max_bytes, 1024}]) of
        ok -> ok;
        {error, Reason} -> {error, safe_reason(Reason)}
    end.

recv_exact(_Session, 0, Chunks) ->
    {ok, iolist_to_binary(lists:reverse(Chunks))};
recv_exact(Session, Remaining, Chunks) ->
    Stream = maps:get(stream, Session),
    Timeout = maps:get(stream_timeout, Session),
    case 'Elixir.IrohBeam.Stream':recv(
           Stream, Remaining, [{timeout, Timeout}]) of
        {ok, Data} when byte_size(Data) > 0 ->
            recv_exact(Session, Remaining - byte_size(Data), [Data | Chunks]);
        eof -> {error, closed};
        {error, Reason} -> {error, safe_reason(Reason)}
    end.

safe_reason(Error) when is_map(Error) ->
    #{category => maps:get(category, Error, internal),
      operation => maps:get(operation, Error, distribution_preface)};
safe_reason(Reason) -> Reason.
