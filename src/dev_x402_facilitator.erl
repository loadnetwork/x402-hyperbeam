-module(dev_x402_facilitator).
-export([request/3, supported/3, premium/3, protected/3]).
-include("include/hb.hrl").

-define(X_PAYMENT_HEADER, <<"x-payment">>).
-define(X402_VERSION, 1).
-define(ERR_HEADER_REQUIRED, <<"X-PAYMENT header is required">>).
-define(ERR_INVALID_HEADER, <<"Invalid or malformed payment header">>).

request(Base, RawReq, NodeMsg) ->
    Profiles = ensure_profiles(payment_profiles(NodeMsg), NodeMsg),
    maybe_update_supported_tokens(Profiles),
    Req = hb_ao:get(<<"request">>, RawReq, not_found, NodeMsg#{ hashpath => ignore }),
    case Req of
        not_found ->
            {ok, RawReq};
        Request ->
            case maybe_handle_supported(Request, Profiles, NodeMsg) of
                continue ->
                    Path = request_path(Request, NodeMsg),
                    case match_protected(Path, protected_paths(Base, NodeMsg)) of
                        false ->
                            {ok, RawReq};
                        {true, Pattern} ->
                            io:format("[x402_facilitator] matched protected path=~p pattern=~p~n", [Path, Pattern]),
                            process_protected(Request, RawReq, Path, Profiles, NodeMsg, preprocess)
                    end;
                Response ->
                    Response
            end
    end.

maybe_handle_supported(Request, Profiles, NodeMsg) ->
    Method = request_method(Request, NodeMsg),
    Path = request_path(Request, NodeMsg),
    io:format("[x402_facilitator] hook entry method=~p path=~p~n", [Method, Path]),
    case {Method, Path} of
        {<<"GET">>, <<"/supported">>} ->
            io:format("[x402_facilitator] serving /supported profiles=~p~n", [Profiles]),
            supported_response(Profiles);
        _ ->
            continue
    end.

process_protected(Request, RawReq, Path, Profiles, NodeMsg, Context) ->
    case payment_header(Request, NodeMsg) of
        missing ->
            payment_required(Path, ?ERR_HEADER_REQUIRED, Profiles);
        invalid ->
            payment_required(Path, ?ERR_INVALID_HEADER, Profiles);
        {ok, Payment} ->
            try x402:facilitate_payment(Payment) of
                {ok, PaymentId} ->
                    io:format("[x402_facilitator] payment verified path=~p payment_id=~p~n", [Path, PaymentId]),
                    UpdatedReq = hb_maps:put(<<"x402-payment-id">>, PaymentId, Request),
                    UpdatedRaw = hb_maps:put(<<"request">>, UpdatedReq, RawReq),
                    io:format("[x402_facilitator] unlocking protected resource ~p~n", [Path]),
                    success_result(Context, UpdatedRaw, Path, PaymentId);
                {error, Reason} ->
                    payment_required(Path, normalize_reason(Reason), Profiles)
            catch
                Class:Reason ->
                    internal_error(Path, Class, Reason)
            end
    end.

protected_paths(Base, NodeMsg) ->
    Default = hb_opts:get(x402_protected_paths, [], NodeMsg),
    Raw =
        case hb_ao:get(<<"protected-paths">>, Base, not_found, NodeMsg) of
            not_found -> Default;
            Value -> Value
        end,
    normalize_patterns(Raw).

normalize_patterns(Value) when Value == undefined; Value == not_found -> [];
normalize_patterns(Value) when is_list(Value) ->
    case hb_util:is_string_list(Value) of
        true -> [hb_path:normalize(Value)];
        false -> [hb_path:normalize(V) || V <- Value]
    end;
normalize_patterns(Value) ->
    [hb_path:normalize(Value)].

request_method(Request, NodeMsg) ->
    hb_ao:get(<<"method">>, Request, <<"GET">>, NodeMsg#{ hashpath => ignore }).

request_path(Request, NodeMsg) ->
    case hb_ao:get(<<"path">>, Request, not_found, NodeMsg#{ hashpath => ignore }) of
        not_found -> undefined;
        Path -> hb_path:normalize(Path)
    end.

match_protected(undefined, _) -> false;
match_protected(_, []) -> false;
match_protected(Path, Patterns) ->
    lists:foldl(
        fun(Pattern, Acc) ->
            case Acc of
                false ->
                    case path_matches(Path, Pattern) of
                        true -> {true, Pattern};
                        false -> false
                    end;
                _ -> Acc
            end
        end,
        false,
        Patterns
    ).

path_matches(Path, Pattern) ->
    PathSegs = path_segments(Path),
    PatternSegs = path_segments(Pattern),
    case PatternSegs of
        [] -> PathSegs == [];
        _ ->
            case lists:last(PatternSegs) of
                <<"*">> ->
                    PrefixLen = length(PatternSegs) - 1,
                    Prefix = lists:sublist(PatternSegs, PrefixLen),
                    lists:prefix(Prefix, PathSegs);
                _ ->
                    PathSegs == PatternSegs
            end
    end.

path_segments(undefined) -> [];
path_segments(Path) ->
    case hb_path:normalize(Path) of
        <<"/">> -> [];
        Normalized -> binary:split(Normalized, <<"/">>, [global, trim_all])
    end.

payment_header(Request, NodeMsg) ->
    case hb_ao:get(?X_PAYMENT_HEADER, Request, not_found, NodeMsg#{ hashpath => ignore }) of
        not_found -> missing;
        Value ->
            try {ok, iolist_to_binary(Value)} of
                {ok, Payment} -> {ok, Payment}
            catch
                error:badarg -> invalid
            end
    end.

payment_required(Path, Reason, Profiles) ->
    Requirements = build_payment_requirements(Path, Profiles),
    Body = #{
        <<"x402Version">> => ?X402_VERSION,
        <<"error">> => Reason,
        <<"accepts">> => Requirements
    },
    io:format("[x402_facilitator] payment required path=~p reason=~p accepts=~p~n", [Path, Reason, Requirements]),
    respond_json(402, Body).

supported_response(Profiles) ->
    Kinds = supported_kinds(Profiles),
    io:format("[x402_facilitator] supported kinds=~p~n", [Kinds]),
    Body = #{ <<"kinds">> => Kinds },

    respond_json(200, Body).

supported(_Base, _Req, NodeMsg) ->
    % hardcoded for
    % todo: dynamic loading
    Kinds = [
        #{
            <<"x402Version">> => ?X402_VERSION,
            <<"scheme">> => <<"exact">>,
            <<"network">> => <<"ao">>,
            <<"extra">> => #{ <<"feePayer">> => <<"auto">> }
        }
    ],
    Profiles = ensure_profiles(payment_profiles(NodeMsg), NodeMsg),
    maybe_update_supported_tokens(Profiles),
    Body = hb_json:encode(#{ <<"kinds">> => Kinds }),
    {ok,
        #{
            <<"status">> => 200,
            <<"content-type">> => <<"application/json">>,
            <<"body">> => Body
        }}.

premium(Base, Req, NodeMsg) ->
    handle_device_request(<<"/premium">>, Base, Req, NodeMsg).

protected(Base, Req, NodeMsg) ->
    Path =
        case request_path(Req, NodeMsg) of
            undefined ->
                case hb_ao:get(<<"path">>, Req, <<"/">>, NodeMsg#{ hashpath => ignore }) of
                    Bin when is_binary(Bin) -> hb_path:normalize(Bin);
                    _ -> <<"/">>
                end;
            Value -> Value
        end,
    handle_device_request(Path, Base, Req, NodeMsg).

handle_device_request(Path0, _Base, Req, NodeMsg) ->
    Path =
        case Path0 of
            undefined -> <<"/">>;
            <<"/", _/binary>> -> Path0;
            Bin when is_binary(Bin) -> <<"/", Bin/binary>>;
            _ -> <<"/">>
        end,
    Profiles = ensure_profiles(payment_profiles(NodeMsg), NodeMsg),
    maybe_update_supported_tokens(Profiles),
    RawReq = #{ <<"request">> => Req },
    process_protected(Req, RawReq, Path, Profiles, NodeMsg, device).

success_result(preprocess, UpdatedRaw, _Path, _PaymentId) ->
    {ok, UpdatedRaw};
success_result(device, _UpdatedRaw, Path, PaymentId) ->
    success_response(Path, PaymentId).

success_response(Path, PaymentId) ->
    BodyMap = #{
        <<"message">> => <<"hello world from the x402 nif side">>,
        <<"path">> => Path,
        <<"paymentId">> => PaymentId
    },
    Body = hb_json:encode(BodyMap),
    {ok,
        #{
            <<"status">> => 200,
            <<"content-type">> => <<"application/json">>,
            <<"body">> => Body
        }}.

respond_json(Status, BodyMap) ->
    Encoded =
        case catch hb_json:encode(BodyMap) of
            {'EXIT', _} -> hb_json:encode(#{<<"error">> => <<"invalid_body">>});
            Json -> Json
        end,
    io:format("[x402_facilitator] responding status=~p body=~p~n", [Status, BodyMap]),
    {error,
        #{
            <<"status">> => Status,
            <<"content-type">> => <<"application/json">>,
            <<"body">> => Encoded
        }}.

internal_error(Path, Class, Reason) ->
    Body0 = #{
        <<"error">> => <<"x402_internal_error">>,
        <<"details">> => normalize_reason({Class, Reason})
    },
    Body =
        case Path of
            undefined -> Body0;
            _ -> Body0#{ <<"path">> => Path }
        end,
    respond_json(500, Body).

normalize_reason(Reason) when is_binary(Reason) -> Reason;
normalize_reason(Reason) ->
    try iolist_to_binary(Reason) of
        Binary -> Binary
    catch
        _:_ -> iolist_to_binary(io_lib:format("~p", [Reason]))
    end.

build_payment_requirements(Path, Profiles) ->
    [maps:put(<<"resource">>, Path, sanitize_profile(Profile)) || Profile <- Profiles].

supported_kinds(Profiles) ->
    lists:usort([kind_from_profile(Profile) || Profile <- Profiles]).

kind_from_profile(Profile) ->
    Kind0 = #{
        <<"x402Version">> => ?X402_VERSION,
        <<"scheme">> => maps:get(<<"scheme">>, Profile),
        <<"network">> => maps:get(<<"network">>, Profile)
    },
    case maps:get(<<"extra">>, Profile, undefined) of
        undefined -> Kind0;
        Extra -> Kind0#{ <<"extra">> => Extra }
    end.

sanitize_profile(Profile) ->
    maps:filter(
        fun(_Key, Value) ->
            case Value of
                undefined -> false;
                [] -> false;
                <<>> -> false;
                _ -> true
            end
        end,
        Profile
    ).


ensure_profiles([], NodeMsg) ->
    case catch x402:supported_tokens() of
        {ok, Tokens} when is_list(Tokens), Tokens =/= [] ->
            [base_profile(hb_util:bin(Token), NodeMsg) || Token <- Tokens];
        {ok, _} -> [];
        {error, _} -> [];
        {'EXIT', _} -> []
    end;
ensure_profiles(Profiles, _NodeMsg) -> Profiles.

maybe_update_supported_tokens(Profiles) ->
    Assets = profile_assets(Profiles),
    case Assets of
        [] -> ok;
        _ ->
            Trimmed = [hb_util:bin(Asset) || Asset <- Assets],
            case catch x402:set_supported_tokens(Trimmed) of
                {ok, _Result} -> ok;
                ok -> ok;
                {error, Reason} ->
                    io:format("[x402_facilitator] set_supported_tokens failed: ~p~n", [Reason]),
                    ok;
                {'EXIT', Reason} ->
                    io:format("[x402_facilitator] set_supported_tokens raised: ~p~n", [Reason]),
                    ok
            end
    end.

profile_assets(Profiles) ->
    lists:usort(
        [Asset || Profile <- Profiles, Asset <- [maps:get(<<"asset">>, Profile, undefined)], is_binary(Asset), Asset =/= <<>>]
    ).

payment_profiles(NodeMsg) ->
    RawProfiles = hb_opts:get(x402_supported_tokens, undefined, NodeMsg),
    Profiles0 =
        case RawProfiles of
            undefined -> [default_payment_profile(NodeMsg)];
            List when is_list(List) ->
                lists:filtermap(fun(Entry) -> normalize_profile_entry(Entry, NodeMsg) end, List);
            Entry ->
                case normalize_profile_entry(Entry, NodeMsg) of
                    {true, Profile} -> [Profile];
                    false -> [default_payment_profile(NodeMsg)]
                end
        end,
    [Profile || Profile <- Profiles0, is_binary(maps:get(<<"asset">>, Profile, undefined)), maps:get(<<"asset">>, Profile, <<>>) =/= <<>>].

normalize_profile_entry(Entry, NodeMsg) when is_map(Entry) ->
    Norm = hb_ao:normalize_keys(Entry, NodeMsg),
    Asset = maybe_binary(maps:get(<<"asset">>, Norm, undefined)),
    case Asset of
        undefined -> false;
        _ ->
            Base = base_profile(Asset, NodeMsg),
            Price = amount_to_binary(
                maps:get(
                    <<"price">>,
                    Norm,
                    maps:get(
                        <<"max-amount-required">>,
                        Norm,
                        maps:get(<<"maxAmountRequired">>, Base)
                    )
                )
            ),
            Profile = Base#{
                <<"scheme">> => maybe_binary(maps:get(<<"scheme">>, Norm, maps:get(<<"scheme">>, Base))),
                <<"network">> => maybe_binary(maps:get(<<"network">>, Norm, maps:get(<<"network">>, Base))),
                <<"maxAmountRequired">> => Price,
                <<"description">> => maybe_binary(maps:get(<<"description">>, Norm, maps:get(<<"description">>, Base))),
                <<"mimeType">> => maybe_binary(maps:get(<<"mime-type">>, Norm, maps:get(<<"mimeType">>, Base))),
                <<"payTo">> => resolve_pay_to(maps:get(<<"pay-to">>, Norm, maps:get(<<"payTo">>, Base)), NodeMsg),
                <<"maxTimeoutSeconds">> => maps:get(<<"max-timeout-seconds">>, Norm, maps:get(<<"maxTimeoutSeconds">>, Base)),
                <<"extra">> => normalize_extra(maps:get(<<"extra">>, Norm, maps:get(<<"extra">>, Base))),
                <<"outputSchema">> => maps:get(<<"output-schema">>, Norm, maps:get(<<"outputSchema">>, Base))
            },
            {true, Profile}
    end;
normalize_profile_entry(Entry, NodeMsg) when is_binary(Entry) ->
    {true, base_profile(Entry, NodeMsg)};
normalize_profile_entry(Entry, NodeMsg) when is_list(Entry) ->
    case hb_util:is_string_list(Entry) of
        true -> {true, base_profile(list_to_binary(Entry), NodeMsg)};
        false -> false
    end;
normalize_profile_entry(_, _NodeMsg) ->
    false.

default_payment_profile(NodeMsg) ->
    Asset = hb_opts:get(x402_token_process, <<>>, NodeMsg),
    base_profile(Asset, NodeMsg).

base_profile(Asset, NodeMsg) ->
    Price = resolve_price(NodeMsg),
    Description = hb_opts:get(x402_description, <<"Payment required">>, NodeMsg),
    Mime = hb_opts:get(x402_mime_type, <<"application/json">>, NodeMsg),
    Network = hb_opts:get(x402_network, <<"ao">>, NodeMsg),
    Timeout = hb_opts:get(x402_max_timeout_seconds, 300, NodeMsg),
    PayTo = resolve_pay_to(hb_opts:get(x402_recipient, <<"auto">>, NodeMsg), NodeMsg),
    #{
        <<"scheme">> => <<"exact">>,
        <<"network">> => maybe_binary(Network),
        <<"maxAmountRequired">> => amount_to_binary(Price),
        <<"description">> => maybe_binary(Description),
        <<"mimeType">> => maybe_binary(Mime),
        <<"payTo">> => PayTo,
        <<"maxTimeoutSeconds">> => Timeout,
        <<"asset">> => maybe_binary(Asset),
        <<"extra">> => undefined,
        <<"outputSchema">> => undefined
    }.

resolve_pay_to(Value, NodeMsg) ->
    case maybe_binary(Value) of
        <<"auto">> -> auto_pay_to(NodeMsg);
        Bin -> Bin
    end.

auto_pay_to(_NodeMsg) ->
    Wallet = hb:wallet(),
    hb_util:human_id(ar_wallet:to_address(Wallet)).

amount_to_binary(Value) when is_integer(Value) -> integer_to_binary(Value);
amount_to_binary(Value) when is_binary(Value) -> Value;
amount_to_binary(Value) when is_list(Value) -> list_to_binary(Value);
amount_to_binary(Value) -> hb_util:bin(Value).

maybe_binary(undefined) -> undefined;
maybe_binary(Value) when is_binary(Value) -> Value;
maybe_binary(Value) when is_list(Value) -> list_to_binary(Value);
maybe_binary(Value) when is_integer(Value) -> integer_to_binary(Value);
maybe_binary(Value) -> hb_util:bin(Value).

normalize_extra(undefined) -> undefined;
normalize_extra(Map) when is_map(Map) -> hb_ao:normalize_keys(Map, #{});
normalize_extra(_) -> undefined.

resolve_price(NodeMsg) ->
    Price0 = hb_opts:get(x402_price_per_request, undefined, NodeMsg),
    case Price0 of
        undefined ->
            hb_opts:get(x402_price_per_request, 1, hb_opts:default_message());
        0 ->
            hb_opts:get(x402_price_per_request, 1, hb_opts:default_message());
        Value -> Value
    end.
