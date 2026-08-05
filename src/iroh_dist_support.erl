-module(iroh_dist_support).
-moduledoc false.

-export([check/0, check/1, ensure/0, new_creation/0, new_creation/1]).

-define(SUPPORTED_OTP_MAJOR, 29).
-define(MAX_CREATION, 1 bsl 32).

-spec check() -> ok | {error, {unsupported_otp, term(), string()}}.
check() ->
    check(erlang:system_info(otp_release)).

-spec check(term()) -> ok | {error, {unsupported_otp, term(), string()}}.
check(Release) ->
    case parse_major(Release) of
        ?SUPPORTED_OTP_MAJOR ->
            ok;
        _ ->
            {error,
             {unsupported_otp, Release,
              "Iroh distribution requires OTP 29.x"}}
    end.

-spec ensure() -> ok | no_return().
ensure() ->
    case check() of
        ok -> ok;
        {error, Reason} -> erlang:error(Reason)
    end.

-spec new_creation() -> 4..?MAX_CREATION - 1.
new_creation() ->
    Source =
        try binary:decode_unsigned(crypto:strong_rand_bytes(4))
        catch
            _:_ -> erlang:unique_integer([positive, monotonic])
        end,
    new_creation(Source).

-spec new_creation(integer()) -> 4..?MAX_CREATION - 1.
new_creation(Source) when is_integer(Source) ->
    wrap_creation(Source band (?MAX_CREATION - 1)).

parse_major(Release) when is_binary(Release) ->
    parse_major(binary_to_list(Release));
parse_major(Release) when is_atom(Release) ->
    parse_major(atom_to_list(Release));
parse_major(Release) when is_list(Release) ->
    case string:to_integer(Release) of
        {Major, _Rest} -> Major;
        _ -> error
    end;
parse_major(_) ->
    error.

wrap_creation(Creation)
  when Creation >= 4, Creation < ?MAX_CREATION ->
    Creation;
wrap_creation(Creation) ->
    wrap_creation((Creation + 4) band (?MAX_CREATION - 1)).
