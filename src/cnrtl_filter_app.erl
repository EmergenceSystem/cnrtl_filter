%%%-------------------------------------------------------------------
%%% @doc CNRTL French dictionary agent.
%%%
%%% Deduplication by URL is handled upstream by the Emquest pipeline.
%%%
%%% === Capability cascade ===
%%%
%%%   base_capabilities/0 extends em_filter:base_capabilities().
%%%
%%% Handler contract: handle/2 (Body, Memory) -> {RawList, Memory}.
%%% @end
%%%-------------------------------------------------------------------
-module(cnrtl_filter_app).
-behaviour(application).

-export([start/2, stop/1]).
-export([handle/2, base_capabilities/0]).

-define(BASE_URL,       "https://www.cnrtl.fr/definition/").
-define(MIN_DEF_LENGTH, 10).
-define(MAX_DEF_LENGTH, 1000).
-define(MIN_WORD_COUNT, 3).
-define(MAX_WORD_COUNT, 50).

%%====================================================================
%% Capability cascade
%%====================================================================

-spec base_capabilities() -> [binary()].
base_capabilities() ->
    em_filter:base_capabilities() ++ [<<"cnrtl">>, <<"french">>,
                                      <<"dictionary">>, <<"definition">>,
                                      <<"lexicon">>].

%%====================================================================
%% Application lifecycle
%%====================================================================

start(_Type, _Args) ->
    case cnrtl_filter_sup:start_link() of
        {ok, Pid} ->
            ok = start_pop_and_http(),
            {ok, Pid};
        Error ->
            Error
    end.

stop(_State) ->
    catch cowboy:stop_listener(cnrtl_filter_query_listener),
    catch em_pop_sup:stop_node(cnrtl_filter),
    ok.

%%====================================================================
%% Internal
%%====================================================================

start_pop_and_http() ->
    PopPort   = application:get_env(cnrtl_filter, pop_port,   9412),
    QueryPort = application:get_env(cnrtl_filter, query_port, 9413),
    Seeds     = application:get_env(cnrtl_filter, pop_seeds,  []),
    Vec = em_filter_vec:from_capabilities(base_capabilities()),
    catch em_pop_sup:stop_node(cnrtl_filter),
    catch cowboy:stop_listener(cnrtl_filter_query_listener),
    {ok, PopPid} = em_pop_sup:start_node(cnrtl_filter, #{
        port            => PopPort,
        query_port      => QueryPort,
        vector          => Vec,
        max_peers       => 100,
        gossip_interval => 5_000
    }),
    lists:foreach(
        fun({H, P}) -> catch em_pop_node:add_peer(PopPid, H, P) end,
        Seeds),
    Dispatch = cowboy_router:compile([
        {'_', [{"/agent/query", em_filter_http,
                #{server => cnrtl_filter_server}}]}
    ]),
    {ok, _} = cowboy:start_clear(cnrtl_filter_query_listener,
                                  [{port, QueryPort}],
                                  #{env => #{dispatch => Dispatch}}),
    logger:notice("[cnrtl_filter] gossip port ~w  query port ~w",
                  [PopPort, QueryPort]),
    ok.

handle(Body, Memory) when is_binary(Body) ->
    {generate_embryo_list(Body), Memory};
handle(_Body, Memory) ->
    {[], Memory}.

%%====================================================================
%% Search and processing
%%====================================================================

generate_embryo_list(JsonBinary) ->
    {Value, _Timeout} = extract_params(JsonBinary),
    case Value of
        "" -> [];
        _  ->
            Url = ?BASE_URL ++ Value,
            case httpc:request(get, {Url, []}, [], [{body_format, binary}]) of
                {ok, {{_, 200, _}, _, Html}} ->
                    extract_all_definitions(Html, Value);
                _ ->
                    []
            end
    end.

extract_params(JsonBinary) ->
    try json:decode(JsonBinary) of
        Map when is_map(Map) ->
            Value   = binary_to_list(maps:get(<<"value">>, Map,
                          maps:get(<<"query">>, Map, <<"">>))),
            Timeout = case maps:get(<<"timeout">>, Map, undefined) of
                undefined            -> 10;
                T when is_integer(T) -> T;
                T when is_binary(T)  -> binary_to_integer(T)
            end,
            {Value, Timeout};
        _ ->
            {binary_to_list(JsonBinary), 10}
    catch
        _:_ -> {binary_to_list(JsonBinary), 10}
    end.

extract_all_definitions(HtmlBin, Word) ->
    Html    = binary_to_list(HtmlBin),
    Blocks  = extract_definition_blocks(Html),
    Cleaned = [clean_definition_block(B) || B <- Blocks, B =/= ""],
    Valid   = [D || D <- Cleaned, is_valid_definition(D)],
    Final   = filter_edge_cases(Valid),
    build_embryos(Word, Final, 1, []).

extract_definition_blocks(Html) ->
    Patterns = [
        "<div[^>]*class=\"tlf_cdefinition\"[^>]*>(.*?)</div>",
        "<span[^>]*class=\"tlf_cdefinition\"[^>]*>(.*?)</span>",
        "<p[^>]*class=\"tlf_cdefinition\"[^>]*>(.*?)</p>",
        "<div[^>]*id=\"def\\d+\"[^>]*>(.*?)</div>",
        "<[^>]*class=\"[^\"]*definition[^\"]*\"[^>]*>(.*?)</[^>]+>"
    ],
    try_patterns(Html, Patterns).

try_patterns(_Html, []) -> [];
try_patterns(Html, [Pat | Rest]) ->
    case re:run(Html, Pat, [global, dotall, {capture, [1], list}]) of
        {match, Matches} ->
            [M || [M] <- Matches, M =/= ""];
        nomatch ->
            try_patterns(Html, Rest)
    end.

clean_definition_block(Block) ->
    NoTags  = re:replace(Block, "<[^>]+>", " ", [global, {return, list}]),
    Decoded = decode_html_entities(NoTags),
    Clean   = re:replace(Decoded, "\\s+", " ", [global, {return, list}]),
    string:trim(Clean).

is_valid_definition(Def) ->
    Len     = length(Def),
    Words   = string:tokens(Def, " "),
    WCount  = length(Words),
    LenOk   = Len >= ?MIN_DEF_LENGTH andalso Len =< ?MAX_DEF_LENGTH,
    UpperOk = case Def of
        []      -> false;
        [H | _] -> H =:= string:to_upper(H)
    end,
    PunctOk  = lists:member(string:right(Def, 1), [".", ";", "!", "?"]),
    WCountOk = WCount >= ?MIN_WORD_COUNT andalso WCount =< ?MAX_WORD_COUNT,
    LenOk andalso UpperOk andalso PunctOk andalso WCountOk.

filter_edge_cases(Defs) ->
    [D || D <- Defs,
          length(string:tokens(D, " ")) > 1,
          string:str(D, "<") =:= 0,
          not is_numeric_or_symbol(D),
          not lists:any(fun(O) -> string:str(D, O) > 0 andalso D =/= O end,
                        lists:delete(D, Defs))].

is_numeric_or_symbol(Str) ->
    lists:all(fun(C) ->
        (C >= $0 andalso C =< $9) orelse
        lists:member(C, ".,;!?:/'- ")
    end, Str).

build_embryos(_Word, [], _Idx, Acc) ->
    lists:reverse(Acc);
build_embryos(Word, [Def | Rest], Idx, Acc) ->
    Url = lists:flatten(
        io_lib:format("https://www.cnrtl.fr/definition/~s#def~p", [Word, Idx])),
    Embryo = #{
        <<"properties">> => #{
            <<"url">>    => list_to_binary(Url),
            <<"resume">> => list_to_binary(Def),
            <<"word">>   => list_to_binary(Word),
            <<"source">> => <<"www.cnrtl.fr">>
        }
    },
    build_embryos(Word, Rest, Idx + 1, [Embryo | Acc]).

decode_html_entities(Text) ->
    Entities = [
        {"&amp;",    "&"},  {"&lt;",  "<"},  {"&gt;",   ">"},
        {"&quot;",   "\""}, {"&#39;", "'"},
        {"&agrave;", "à"},  {"&aacute;", "á"},
        {"&eacute;", "é"},  {"&egrave;", "è"}, {"&ecirc;", "ê"},
        {"&icirc;",  "î"},  {"&ocirc;",  "ô"}, {"&ugrave;", "ù"},
        {"&ccedil;", "ç"},  {"&nbsp;",   " "}
    ],
    lists:foldl(fun({Entity, Char}, Acc) ->
        re:replace(Acc, Entity, Char, [global, {return, list}])
    end, Text, Entities).
