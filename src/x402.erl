-module(x402).
-export([facilitate_payment/1, set_supported_tokens/1, supported_tokens/0]).
-include("include/cargo.hrl").

-on_load(init/0).
-define(NOT_LOADED, not_loaded(?LINE)).

facilitate_payment(_XPayment) ->
    ?NOT_LOADED.

set_supported_tokens(_Tokens) ->
    ?NOT_LOADED.

supported_tokens() ->
    ?NOT_LOADED.

init() ->
    ?load_nif_from_crate(x402, 0).

not_loaded(Line) ->
    erlang:nif_error({not_loaded, [{module, ?MODULE}, {line, Line}]}).
