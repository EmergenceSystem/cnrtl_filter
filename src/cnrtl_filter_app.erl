%%%-------------------------------------------------------------------
%%% @doc CNRTL French dictionary agent.
%%%
%%% Announces capabilities to em_disco on startup and maintains a
%%% memory of definition URLs already returned so duplicates across
%%% successive queries are filtered out.
%%%
%%% Handler contract: `handle/2' (Body, Memory) -> {RawList, NewMemory}.
%%% Memory schema: `#{seen => #{binary_url => true}}'.
%%% @end
%%%-------------------------------------------------------------------
-module(cnrtl_filter_app).
-behaviour(application).

-export([start/2, stop/1]).
-export([handle/2]).

-define(BASE_URL,       "https://www.cnrtl.fr/definition/").
-define(MIN_DEF_LENGTH, 10).
-define(MAX_DEF_LENGTH, 1000).
-define(MIN_WORD_COUNT, 3).
-define(MAX_WORD_COUNT, 50).

-define(CAPABILITIES, [
    <<"cnrtl">>,
    <<"french">>,
    <<"dictionary">>,
    <<"definition">>,
    <<"lexicon">>
]).

%%====================================================================
%% Application behaviour
%%====================================================================

start(_Type, _Args) ->
    em_filter:start_agent(cnrtl_filter, ?MODULE, #{
        capabilities => ?CAPABILITIES,
        memory       => ets
    }).

stop(_State) ->
    em_filter:stop_agent(cnrtl_filter).

%%====================================================================
%% Agent handler
%%====================================================================

handle(Body, Memory) when is_binary(Body) ->
    Seen    = maps:get(seen, Memory, #{}),
    Embryos = generate_embryo_list(Body),
    Fresh   = [E || E <- Embryos, not maps:is_key(url_of(E), Seen)],
    NewSeen = lists:foldl(fun(E, Acc) ->
        Acc#{url_of(E) => true}
    end, Seen, Fresh),
    {Fresh, Memory#{seen => NewSeen}};

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
            Value   = binary_to_list(maps:get(<<"value">>,   Map, <<"">>)),
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

-spec url_of(map()) -> binary().
url_of(#{<<"properties">> := #{<<"url">> := Url}}) -> Url;
url_of(_) -> <<>>.
