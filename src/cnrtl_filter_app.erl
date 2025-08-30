-module(cnrtl_filter_app).
-behaviour(application).

%% API Exports
-export([start/2, stop/1]).
-export([init/2, terminate/3]).

%% Constants
-define(BASE_URL, "https://www.cnrtl.fr/definition/").
-define(MIN_DEF_LENGTH, 10).       %% Minimum length for a valid definition
-define(MAX_DEF_LENGTH, 1000).     %% Maximum length for a valid definition
-define(MIN_WORD_COUNT, 3).         %% Minimum number of words in a definition
-define(MAX_WORD_COUNT, 50).        %% Maximum number of words in a definition

%%------------------------------------------------------------------
%% Application Lifecycle
%%------------------------------------------------------------------

start(_Type, _Args) ->
    {ok, Port} = em_filter:find_port(),
    em_filter_sup:start_link(cnrtl_filter, ?MODULE, Port).

stop(_State) ->
    ok.

%%------------------------------------------------------------------
%% HTTP Handler
%%------------------------------------------------------------------

init(Req0, State) ->
    {ok, Body, Req} = cowboy_req:read_body(Req0),
    io:format("[INFO] Received body: ~p~n", [Body]),

    EmbryoList = generate_embryo_list(Body),
    Response = #{embryo_list => EmbryoList},
    EncodedResponse = jsone:encode(Response),

    Req2 = cowboy_req:reply(
        200,
        #{<<"content-type">> => <<"application/json">>},
        EncodedResponse,
        Req
    ),
    {ok, Req2, State}.

terminate(_Reason, _Req, _State) ->
    ok.

%%------------------------------------------------------------------
%% Main Definition Extraction
%%------------------------------------------------------------------

generate_embryo_list(JsonBinary) ->
    Search = case jsone:decode(JsonBinary, [{keys, atom}]) of
        SearchMap when is_map(SearchMap) ->
            Value = binary_to_list(maps:get(value, SearchMap, <<"">>)),
            Timeout = list_to_integer(binary_to_list(maps:get(timeout, SearchMap, <<"10">>))),
            {Value, Timeout};
        _ ->
            {"", 10}
    end,

    {SearchValue, _Timeout} = Search,
    io:format("[INFO] Search word: ~p~n", [SearchValue]),

    if
        SearchValue =/= "" ->
            Url = ?BASE_URL ++ SearchValue,
            io:format("[INFO] CNRTL URL: ~s~n", [Url]),

            case httpc:request(get, {Url, []}, [], [{body_format, binary}]) of
                {ok, {{_, 200, _}, _, Body}} ->
                    extract_all_definitions(Body, SearchValue);
                {error, Reason} ->
                    io:format("[ERROR] HTTP Error: ~p~n", [Reason]),
                    []
            end;
        true ->
            io:format("[ERROR] Empty 'value' field~n"),
            []
    end.

%%------------------------------------------------------------------
%% Definition Extraction with Safe Filtering
%%------------------------------------------------------------------

extract_all_definitions(HtmlBin, Word) ->
    Html = binary_to_list(HtmlBin),
    io:format("[DEBUG] Parsing HTML (~p characters)...~n", [length(Html)]),

    %% Extract definition blocks
    DefBlocks = extract_definition_blocks(Html),

    %% Clean and validate each block
    CleanedDefs = [clean_definition_block(Block) || Block <- DefBlocks, Block =/= ""],
    io:format("[DEBUG] Found ~p raw definitions~n", [length(CleanedDefs)]),

    %% Filter valid definitions
    ValidDefs = [Def || Def <- CleanedDefs, is_valid_definition(Def)],
    io:format("[DEBUG] ~p definitions passed basic validation~n", [length(ValidDefs)]),

    %% Apply edge case filtering
    try
        FinalDefs = filter_edge_cases(ValidDefs),
        build_embryos(Word, FinalDefs, 1, [])
    catch
        error:Reason ->
            io:format("[ERROR] Error in edge case filtering: ~p~n", [Reason]),
            build_embryos(Word, ValidDefs, 1, [])
    end.

%%------------------------------------------------------------------
%% Definition Block Extraction
%%------------------------------------------------------------------

extract_definition_blocks(Html) ->
    Patterns = [
        %% Primary patterns for definition blocks
        "<div[^>]*class=\"tlf_cdefinition\"[^>]*>(.*?)</div>",
        "<span[^>]*class=\"tlf_cdefinition\"[^>]*>(.*?)</span>",
        "<p[^>]*class=\"tlf_cdefinition\"[^>]*>(.*?)</p>",
        "<div[^>]*id=\"def\\d+\"[^>]*>(.*?)</div>",
        "<[^>]*class=\"[^\"]*definition[^\"]*\"[^>]*>(.*?)</[^>]+>"
    ],

    try_extract_blocks(Html, Patterns, 1).

try_extract_blocks(_Html, [], _Index) ->
    io:format("[DEBUG] No definition blocks found with standard patterns~n"),
    [];

try_extract_blocks(Html, [Pattern|Rest], Index) ->
    io:format("[DEBUG] Trying pattern ~p: ~s~n", [Index, Pattern]),
    case re:run(Html, Pattern, [global, {capture, [1], list}]) of
        {match, Matches} ->
            Filtered = [M || [M] <- Matches, M =/= ""],
            io:format("[DEBUG] Pattern ~p succeeded (~p blocks found)~n", [Index, length(Filtered)]),
            Filtered;
        nomatch ->
            try_extract_blocks(Html, Rest, Index + 1)
    end.

%%------------------------------------------------------------------
%% Definition Cleaning and Validation
%%------------------------------------------------------------------

clean_definition_block(Block) ->
    %% Remove HTML tags
    NoTags = re:replace(Block, "<[^>]+>", " ", [global, {return, list}]),
    %% Decode HTML entities
    Decoded = embryo:decode_html_entities(NoTags),
    %% Clean multiple spaces
    CleanSpaces = re:replace(Decoded, "\\s+", " ", [global, {return, list}]),
    %% Trim whitespace
    string:trim(CleanSpaces).

is_valid_definition(Def) ->
    %% Check length constraints
    LengthOk = length(Def) >= ?MIN_DEF_LENGTH andalso length(Def) =< ?MAX_DEF_LENGTH,

    %% Check it starts with uppercase
    StartsWithUpper = case Def of
        [] -> false;
        [First|_] -> First =:= string:to_upper(First)
    end,

    %% Check it ends with punctuation
    EndsWithPunct = lists:member(string:right(Def, 1), [".", ";", "!", "?"]),

    %% Check word count
    Words = string:tokens(Def, " "),
    WordCountOk = length(Words) >= ?MIN_WORD_COUNT andalso length(Words) =< ?MAX_WORD_COUNT,

    %% All conditions must be met
    LengthOk andalso StartsWithUpper andalso EndsWithPunct andalso WordCountOk.

%% @doc Filter out edge cases and invalid definitions (corrected version)
filter_edge_cases(Defs) ->
    [Def || Def <- Defs,
     %% Remove single-word definitions (like "Raton laveur")
     length(string:tokens(Def, " ")) > 1,
     %% Remove definitions that look like they contain HTML fragments
     not string:str(Def, "<"),
     %% Remove definitions that are just numbers or symbols
     not is_numeric_or_symbol(Def),
     %% Remove definitions that are too similar to others
     not lists:any(fun(Other) -> string:str(Def, Other) andalso Def =/= Other end, lists:delete(Def, Defs))
    ].

%% @doc Check if a string is numeric or just symbols
is_numeric_or_symbol(Str) ->
    %% Check if string contains only numbers, spaces, or punctuation
    lists:all(fun(C) ->
        (C >= $0 andalso C =< $9) orelse
        C =:= $. orelse C =:= $, orelse C =:= $; orelse
        C =:= $! orelse C =:= $? orelse C =:= $: orelse
        C =:= $/ orelse C =:= $' orelse C =:= $- orelse
        C =:= $  %% space
    end, Str).

%%------------------------------------------------------------------
%% Embryo Construction
%%------------------------------------------------------------------

build_embryos(_Word, [], _Index, Acc) ->
    lists:reverse(Acc);

build_embryos(Word, [Def|Rest], Index, Acc) ->
    Url = lists:flatten(io_lib:format("https://www.cnrtl.fr/definition/~s#def~p", [Word, Index])),
    Embryo = #{
        properties => #{
            <<"resume">> => list_to_binary(Def),
            <<"url">>    => list_to_binary(Url),
            <<"word">>   => list_to_binary(Word),
            <<"source">> => <<"www.cnrtl.fr">>
        }
    },
    build_embryos(Word, Rest, Index + 1, [Embryo|Acc]).

