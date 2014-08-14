-module(exemplar_SUITE).
-include_lib("common_test/include/ct.hrl").
-export([all/0]).
-export([exemplar_tests/1, init_per_suite/1, end_per_suite/1]).

-define(datadir, "../../transit-format/examples/0.8/simple/").
-define(ArraySimple, [1,2,3]).
-define(ArrayMixed, [0, 1, 2.0, true, false, <<"five">>, six, transit_types:symbol("seven"), <<"~eight">>, undefined]).

all() -> [exemplar_tests].

init_per_suite(Config) ->
  transit:start(),
  Config.

end_per_suite(Config) ->
  transit:stop(),
  Config.

exemplar_tests(Config) ->
  Dir = ?config(data_dir, Config),
  exemplar("nil", undefined, Dir),
  exemplar("false", false, Dir),
  exemplar("true", true, Dir),
  exemplar("zero", 0, Dir),
  exemplar("one", 1, Dir),
  exemplar("one_string", <<"hello">>, Dir),
  exemplar("one_keyword", hello, Dir),
  exemplar("one_symbol", transit_types:symbol("hello"), Dir),
  exemplar("vector_simple", ?ArraySimple, Dir),
  exemplar("vector_empty", [], Dir),
  exemplar("vector_mixed", ?ArrayMixed, Dir),
  ok.

exemplar(Name, Val, Dir) ->
  lists:map(fun(Ext) ->
                File = filename:join(Dir, Name ++ "." ++ Ext),
                {ok, Data} = file:read_file(File),
                L = bit_size(Data) - 8,
                <<D:L/binary-unit:1, _/binary>> = Data,
                D = transit:write(Val),
                Val = transit:read(D)
            end, ["json"]).