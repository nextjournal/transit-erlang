-module(transit_reader).
-include("transit_format.hrl").
-include("transit.hrl").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([read/2, decode/2]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

read(Obj, Config) ->
  Format = format(Config),
  Cache = transit_rolling_cache:empty(Format),

  case unpack(Obj, Format) of
    {ok, Rep} ->
      {Val, _} = decode(Cache, Rep, value, Config),
      Val;
    {error, unknown_format} ->
      error(badarg)
  end.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

unpack(Obj, msgpack) -> msgpack:unpack(Obj, [{format, jsx}]);
unpack(Obj, json) -> {ok, jsx:decode(Obj)};
unpack(Obj, json_verbose) -> {ok, jsx:decode(Obj)};
unpack(_Obj, undefined) -> {error, unknown_format}.

format(#{ format := F }) -> F;
format(#{}) -> undefined;
format(Config) when is_list(Config) ->
    proplists:get_value(format, Config, undefined).

decode(Rep, Config) ->
  Format = format(Config),
  Cache = transit_rolling_cache:empty(Format),
  {Val, _} = decode(Cache, Rep, value, Config),
  Val.

decode(Cache, Str, Kind, Config) when is_binary(Str) ->
  {OrigStr, Cache1} = transit_rolling_cache:decode(Cache, Str, Kind),
  {parse_string(OrigStr, Config), Cache1};
decode(Cache, [?MAP_AS_ARR|Tail], Kind, Config) ->
  {L, C} = decode_array_hash(Cache, Tail, Kind, Config),
  {maps:from_list(L), C};
%% If the output is from a verbose write, it will be encoded as a hash
decode(Cache, [{Key, Val}], Kind, Config) ->
  case decode(Cache, Key, key, Config) of
    {{tag, Tag}, C1} ->
      {DVal, C2} = decode(C1, Val, Kind, Config),
      {decode_tag(Tag, DVal, Config), C2};
    {DKey, C1} ->
      {DVal, C2} = decode(C1, Val, value, Config),
      {maps:from_list([{DKey, DVal}]), C2}
  end;
decode(Cache, [{_, _}|_] = Obj, Kind, Config) ->
  {L, C} = decode_hash(Cache, Obj, Kind, Config),
  {maps:from_list(L), C};
decode(Cache, [EscapedTag, Rep] = Name, Kind, Config) when is_binary(EscapedTag) ->
  {OrigTag, C} = transit_rolling_cache:decode(Cache, EscapedTag, Kind),
  case OrigTag of
    <<"~#", Tag/binary>> ->
      {DRep, C1} = decode(C, Rep, Kind, Config),
      {decode_tag(Tag, DRep, Config), C1};
    _ ->
      %% Abort the above and decode as an array. Note the reference back to the original cache
      decode_array(Cache, Name, Kind, Config)
  end;
decode(Cache, [{}], _Kind, _Config) -> {#{}, Cache};
decode(Cache, Obj, Kind, Config) when is_list(Obj) -> decode_array(Cache, Obj, Kind, Config);
decode(Cache, null, _Kind, #{ translate_fun := TR }) -> {TR(undefined), Cache};
decode(Cache, null, _Kind, _Config) -> {undefined, Cache};
decode(Cache, Obj, _Kind, _Config) -> {Obj, Cache}.

rem_fst(<<_, Data/binary>>) -> Data.

parse_string(<< $~, $~, _/binary>> = Bin, _Config) -> rem_fst(Bin);
parse_string(<< $~, $^, _/binary>> = Bin, _Config) -> rem_fst(Bin);
parse_string(<< $~, $`, _/binary>> = Bin, _Config) -> rem_fst(Bin);
parse_string(<< $~, $#, Rep/binary>>, _Config) -> {tag, Rep};
parse_string(<< $~, X:1/binary, Rep/binary>>, Config) -> handle(X, Rep, Config);
parse_string(S, _Config) -> S.

decode_array_hash(Cache, [Key,Val|Name], Kind, Config) ->
  {DKey, C1} = decode(Cache, Key, key, Config),
  {DVal, C2} = decode(C1, Val, value, Config),
  {Tail, C3} = decode_array_hash(C2, Name, Kind, Config),
  {[{DKey, DVal}|Tail], C3};
decode_array_hash(Cache, [], _Kind, _Config) ->
  {[], Cache}.

decode_array(Cache, Obj, Kind, Config) ->
  lists:mapfoldl(fun(El, C) -> decode(C, El, Kind, Config) end, Cache, Obj).

decode_tag(Tag, Rep, Config) -> handle(Tag, Rep, Config).

decode_hash(Cache, [{Key, Val}], Kind, Config) ->
  case decode(Cache, Key, Kind, Config) of
    {#tagged_value{tag=Tag}, C1} ->
      {DecodedVal, C2} = decode(C1, Val, Kind, Config),
      {decode_tag(Tag, DecodedVal, Config), C2};
    {DecodedKey, C3} ->
      {Rep, C4} = decode(C3, Val, value, Config),
      {[{DecodedKey, Rep}], C4}
  end;
decode_hash(_Cache, [_], _Kind, _Config) ->
  exit(unidentified_read);
decode_hash(Cache, Name, _Kind, Config) ->
  lists:mapfoldl(fun({Key, Val}, C) ->
                      {DKey, C1} = decode(C, Key, key, Config),
                      {DVal, C2} = decode(C1, Val, value, Config),
                      {{DKey, DVal}, C2}
                 end, Cache, Name).

collect_pairs([]) -> [];
collect_pairs([K,V | Tail]) -> [{K, V} | collect_pairs(Tail)].

handle(Ty, Rep, #{ translate_fun := TR }) ->
    TR(handle(Ty, Rep));
handle(Ty, Rep, _) -> handle(Ty, Rep).

handle(?CMAP, Rep) -> maps:from_list(collect_pairs(Rep));
handle(?NULL, _) -> undefined;
handle(?BOOLEAN, <<"t">>) -> true;
handle(?BOOLEAN, <<"f">>) -> false;
handle(?INT, Rep) -> binary_to_integer(Rep);
handle(?BIGINT, Rep) -> binary_to_integer(Rep);
handle(?FLOAT, Rep) -> binary_to_float(Rep);
handle(?QUOTE, null) -> undefined;
handle(?QUOTE, Rep) -> Rep;
handle(?SET, Rep) -> sets:from_list(Rep);
handle(?LIST, Rep) -> {list, Rep};
handle(?KEYWORD, Rep) -> {kw, Rep};
handle(?SYMBOL, Rep) -> {sym, Rep};
handle(?DATE, Rep) when is_integer(Rep) -> {timepoint, Rep};
handle(?DATE, Rep) -> {timepoint, binary_to_integer(Rep)};
handle(?SPECIAL_NUMBER, <<"NaN">>) -> nan;
handle(?SPECIAL_NUMBER, <<"INF">>) -> infinity;
handle(?SPECIAL_NUMBER, <<"-INF">>) -> neg_infinity;
handle(?BINARY, Rep) -> {binary, base64:decode(Rep)};
handle(?VERBOSEDATE, Rep) -> {timepoint, Rep};
handle(?UUID, [_, _] = U) -> transit_types:uuid(list_to_binary(transit_utils:uuid_to_string(U)));
handle(?UUID, Rep) -> {uuid, Rep};
handle(?URI, Rep) -> {uri, Rep};
handle(Extension, Rep) ->
  transit_types:tv(Extension, Rep).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
start_server() ->
  transit_rolling_cache:empty(json).

stop_server(_C) ->
  ok.

unmarshal_test_() ->
  {foreach,
   fun start_server/0,
   fun stop_server/1,
   [fun unmarshal_quoted/1,
    fun unmarshal_extend/1]}.

unmarshal_quoted(C) ->
  Tests = [{1, <<"[\"~#'\", 1]">>},
           {<<"foo">>, <<"[\"~#'\", \"foo\"]">>},
           {undefined, <<"[\"~#'\", null]">>},
           {true, <<"[\"~#'\", true]">>},
           {false, <<"[\"~#'\", false]">>},
           {{kw, <<"~">>}, <<"[\"~#'\",\"~:~\"]">>},
           {{kw, <<"^">>}, <<"[\"~#'\",\"~:^\"]">>},
           {<<"~hello">>, <<"[\"~#'\",\"~~hello\"]">>},
           {transit_types:symbol(<<"hello">>), <<"[\"~#'\",\"~$hello\"]">>},
           {transit_types:datetime({0,0,0}), <<"[\"~#'\",\"~m0\"]">>}
           %{transit_types:datetime({0,0,0}), <<"[\"~#'\",\"~t1970-01-01T00:00:01.000Z\"]">>},
          ],
  [fun() -> {Val, _} = decode(C, jsx:decode(Str), value, #{}) end || {Val, Str} <- Tests].

unmarshal_extend(C) ->
  Tests = [{[[{kw, <<"c">>}, undefined]], <<"[[\"~:c\",null]]">>},
           {[], <<"[]">>},
           {#{}, <<"{}">>},
           {maps:from_list([{<<"foo">>, <<"bar">>}]), <<"{\"foo\":\"bar\"}">>},
           {maps:from_list([{<<"a">>, <<"b">>}, {3, 4}]), <<"[\"^ \",\"a\",\"b\",3,4]">>},
           {maps:from_list([{{kw, <<"a">>},
                             {kw, <<"b">>}}, {3, 4}]), <<"[\"^ \",\"~:a\",\"~:b\",3,4]">>},
           {sets:from_list([<<"foo">>, <<"bar">>, <<"baz">>]), <<"[\"~#set\", [\"foo\",\"bar\",\"baz\"]]">>},
           {maps:from_list([{{kw, <<"foo">>}, <<"bar">>}]), <<"{\"~:foo\":\"bar\"}">>}],
  [fun() -> {Val, _} = decode(C, jsx:decode(Str), value, #{}) end || {Val, Str} <- Tests].

parse_string_test_() ->
  ?_assertEqual(foo, parse_string(<<"~:foo">>, #{})),
  ?_assertEqual(<<"~foo">>, parse_string(<<"~~foo">>, #{})),
  ?_assertEqual({tag, <<"'">>}, parse_string(<<"~#'">>, #{})).
-endif.
