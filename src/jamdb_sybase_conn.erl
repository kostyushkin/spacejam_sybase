-module(jamdb_sybase_conn).

%% API
-export([connect/1, connect/2]).
-export([reconnect/1]).
-export([disconnect/1, disconnect/2]).
-export([sql_query/2, sql_query/3]).
-export([prepare/3]).
-export([execute/3, execute/4]).

-include("TDS_5_0.hrl").
-include("jamdb_sybase.hrl").
-include("jamdb_sybase_defaults.hrl").

-define(ENCODER, jamdb_sybase_tds_encoder).
-define(DECODER, jamdb_sybase_tds_decoder).

-record(conn, {
    socket = undefined,
    state = disconnected :: disconnected | connected | auth_negotiate,
    packet_size :: non_neg_integer(),
    tds_ver,
    server = {<<"Unknown">>, <<0,0,0,0>>},
    req_capabilities = [],
    resp_capabilities = [],
    env = [],
    prepared = []
}).

-opaque state() :: #conn{}.
-type error_type() :: socket | remote | local.
-type empty_result() :: {ok, state()} | {error, error_type(), binary(), state()}.
-type affected_rows() :: {affected_rows, non_neg_integer()}.
-type columns() :: list().  %% TODO
-type metainfo() :: list(). %%TODO
-type rows() :: list().  %% TODO
-type result_set() :: {result_set, columns(), metainfo(), rows()}.
-type return_status() :: non_neg_integer().
-type out_params() :: list().  %% TODO
-type procedure_result() :: 
        {proc_result, return_status(), out_params()}.
-type result() :: 
        affected_rows() | 
        result_set() | 
        procedure_result().
-type query_reult() :: {ok, [result()], state()}.
-type env() :: 
        {host, string()} |
        {port, string()} |
        {user, string()} |
        {password, string()} |
        {database, string()} |
        {app_name, string()} |
        {lib_name, string()} |
        {language, string()} |
        {packet_size, non_neg_integer()}.
-type options() :: [env()].

-export_type([state/0]).
-export_type([options/0]).

%% API
-spec connect([env()], timeout()) -> empty_result().
connect(Opts) ->
    connect(Opts, ?DEF_TIMEOUT).

-spec connect([env()]) -> empty_result().
connect(Opts, Timeout) ->
    Host     = proplists:get_value(host, Opts, ?DEF_HOST),
    Port     = proplists:get_value(port, Opts, ?DEF_PORT),
    Database = proplists:get_value(database, Opts, ?DEF_DATABASE),
    PktSize  = proplists:get_value(packet_size, Opts, ?DEF_PACKET_SIZE),
    SockOpts = [binary, {active, false}, {packet, raw}, 
            {nodelay, true}, {keepalive, true}],
    case gen_tcp:connect(Host, Port, SockOpts, Timeout) of
        {ok, Socket} ->
            Conn = #conn{
                socket        = Socket, 
                packet_size   = PktSize,
                env           = Opts
            },
            case login(Conn, Timeout) of
                {ok, Conn3 = #conn{state = connected}} ->
                    system_query(Conn3, ["use ", Database], Timeout);
                Error ->
                    Error
            end;
        {error, Reason} ->
            {error, socket, Reason}
    end.

-spec disconnect(state()) -> {ok, [env()]}.
disconnect(Conn) ->
    disconnect(Conn, ?DEF_TIMEOUT).

-spec disconnect(state(), timeout()) -> {ok, [env()]}.
disconnect(#conn{state=connected, socket=Socket, env=Env}, 0) ->
    ok = gen_tcp:close(Socket),
    {ok, Env};
disconnect(Conn = #conn{state=connected, socket=Socket, env=Env,
        packet_size=PktSize}, Timeout) ->
    TokenStream = ?ENCODER:encode_tokens([{logout, []}]),
    DataStream = ?ENCODER:encode_packets(TokenStream, 'query', PktSize),
    try send(Socket, DataStream) of
        ok -> handle_empty_resp(Conn, Timeout);
        {error, _Reason} -> ok
    after
        ok = gen_tcp:close(Socket)
    end,
    {ok, Env};
disconnect(#conn{env = Env}, _Timeout) ->
    {ok, Env}.

-spec reconnect(state()) -> {ok, state()}.
reconnect(Conn) ->
    {ok, InitOpts} = disconnect(Conn, 0),
    connect(InitOpts).

-spec sql_query(state(), string()) -> query_reult().
sql_query(Conn, Query) ->
    sql_query(Conn, Query, ?DEF_TIMEOUT).

-spec sql_query(state(), string(), timeout()) -> query_reult().
sql_query(Conn = #conn{state=connected, socket=Socket,
        packet_size=PktSize}, Query, Timeout) ->
    BQuery = unicode:characters_to_binary(Query),
    TokenStream = ?ENCODER:encode_tokens([{language, BQuery}]),
    DataStream = ?ENCODER:encode_packets(TokenStream, 'query', PktSize),
    case send(Socket, DataStream) of
        ok              -> handle_query_resp(Conn, Timeout);
        {error, Reason} -> handle_error(socket, Reason, Conn)
    end;
sql_query(Conn, Query, Timeout) ->
    case reconnect(Conn) of
        {ok, Conn2} -> sql_query(Conn2, Query, Timeout);
        Error       -> Error
    end.

prepare(Conn = #conn{state=connected, socket=Socket,
        packet_size=PktSize}, StmtId, Query) ->
    BStmtId = unicode:characters_to_binary(StmtId),
    BQuery = unicode:characters_to_binary(Query),
    BQuery2 = <<"create proc ", BStmtId/binary, " as ", BQuery/binary>>,
    TokenList = [{dynamic, prepare, [], BStmtId, BQuery2}],
    TokenStream = ?ENCODER:encode_tokens(TokenList),
    DataStream = ?ENCODER:encode_packets(TokenStream, 'query', PktSize),
    case send(Socket, DataStream) of
        ok              -> handle_prepare_resp(Conn, ?DEF_TIMEOUT);
        {error, Reason} -> handle_error(socket, Reason, Conn)
    end;
prepare(Conn, Stmt, Query) ->
    case reconnect(Conn) of
        {ok, Conn2} -> prepare(Conn2, Stmt, Query);
        Error       -> Error
    end.

execute(Conn, Stmt, Args) ->
    execute(Conn, Stmt, Args, ?DEF_TIMEOUT).

execute(Conn = #conn{state=connected, socket=Socket,
        packet_size=PktSize}, StmtId, Args, Timeout) ->
    BStmtId = unicode:characters_to_binary(StmtId),
    TokenParamsFmt = proplists:get_value(BStmtId, Conn#conn.prepared),
    TokenList = case Args of
        [] ->
            [{dynamic, execute, [], BStmtId, <<>>}];
        _ ->
            [
                {dynamic, execute, [?TDS_DYNAMIC_HASARGS], BStmtId, <<>>},
                TokenParamsFmt,
                {params, Args}
            ]
    end,
    TokenStream = ?ENCODER:encode_tokens(TokenList),
    DataStream = ?ENCODER:encode_packets(TokenStream, 'query', PktSize),
    case send(Socket, DataStream) of
        ok              -> handle_query_resp(Conn, Timeout);
        {error, Reason} -> handle_error(socket, Reason, Conn)
    end;
execute(Conn, Stmt, Args, Timeout) ->
    case reconnect(Conn) of
        {ok, Conn2} -> execute(Conn2, Stmt, Args, Timeout);
        Error       -> Error
    end.


%% internal
login(Conn = #conn{env=Env, socket=Socket, packet_size=PktSize}, Timeout) ->
    TokenStream = ?ENCODER:encode_tokens([{login, Env}]),
    DataStream = ?ENCODER:encode_packets(TokenStream, login, PktSize),
    case send(Socket, DataStream) of
        ok ->
            case handle_empty_resp(Conn, Timeout) of
                {ok, Conn2 = #conn{state = auth_negotiate}} ->
                    %%TODO Negotiate
                    Reason = <<"Auth Negotiate not implemented">>,
                    handle_error(local, Reason, Conn2);
                Other ->
                    Other
            end;
        {error, Reason} ->
            handle_error(socket, Reason, Conn)
    end.

system_query(Conn = #conn{state=connected, socket=Socket, 
        packet_size=PktSize}, Query, Timeout) ->
    BQuery = unicode:characters_to_binary(Query),
    TokenStream = ?ENCODER:encode_tokens([{language, BQuery}]),
    DataStream = ?ENCODER:encode_packets(TokenStream, 'query', PktSize),
    case send(Socket, DataStream) of
        ok              -> handle_empty_resp(Conn, Timeout);
        {error, Reason} -> handle_error(socket, Reason, Conn)
    end.

handle_error(socket, Reason, Conn) ->
    _ = disconnect(Conn, 0),
    {error, socket, Reason, Conn#conn{state = disconnected}};
handle_error(Type, Reason, Conn) ->
    {error, Type, Reason, Conn}.

handle_empty_resp(Conn, Timeout) ->
    case handle_resp(Conn, Timeout) of
        {ok, _, _, Conn2} ->
            {ok, Conn2};
        Other ->
            Other
    end.

handle_prepare_resp(Conn = #conn{prepared = Prepared}, Timeout) ->
    case handle_resp(Conn, Timeout) of
        {ok, TokensBufer, _, Conn2} ->
            {TokenDynamic, TokensBufer2} = take_token(dynamic, TokensBufer),
            {ParamsFormat, _TokensBufer3} = take_token(paramsformat, TokensBufer2),
            {dynamic, ack, _Status, Id} = TokenDynamic,
            Conn3 = Conn2#conn{
                prepared = [{Id, ParamsFormat}|Prepared]
            },
            {ok, Conn3};
        Other ->
            Other
    end.

handle_query_resp(Conn, Timeout) ->
    case handle_resp(Conn, Timeout) of
        {ok, _TokensBufer, Result, Conn2} ->
            {ok, Result, Conn2};
        Error -> Error
    end.

handle_resp(Conn = #conn{socket=Socket}, Timeout) ->
    case recv(Socket, Timeout) of
        {ok, BinaryData} ->
            decode_token_stream(BinaryData, [], [], Conn);
        {error, Reason} ->
            handle_error(socket, Reason, Conn)
    end.

decode_token_stream(Stream, TokensBufer, Results, Conn) ->
    case ?DECODER:decode_token(Stream, TokensBufer) of
        {ok, Token, Stream2} when element(1, Token) =:= done ->
            case handle_done_token(Token, TokensBufer, Results) of
                {next_token, TokensBufer2, Results2} ->
                    decode_token_stream(Stream2, TokensBufer2, Results2, Conn);
                Result ->
                    erlang:append_element(Result, Conn)
            end;
        {ok, Token, Stream2} when element(1, Token) =:= loginack ->
            Conn2 = handle_loginack_token(Token, Conn),
            decode_token_stream(Stream2, TokensBufer, Results, Conn2);
        {ok, Token, Stream2} when element(1, Token) =:= capability ->
            Conn2 = handle_capability_token(Token, Conn),
            decode_token_stream(Stream2, TokensBufer, Results, Conn2);
        {ok, Token, Stream2} when element(1, Token) =:= envchange ->
            Conn2 = handle_envchange_token(Token, Conn),
            decode_token_stream(Stream2, TokensBufer, Results, Conn2);
        {ok, Token, Stream2} ->
            decode_token_stream(Stream2, [Token|TokensBufer], Results, Conn);
        {error, Reason} ->
            handle_error(local, Reason, Conn)
    end.

handle_loginack_token({loginack, ConnConn, TdsVer, Server}, Conn) ->
    Conn#conn{state = ConnConn, tds_ver = TdsVer, server = Server}.

handle_capability_token({capability, ReqCap, RespCap}, Conn) ->
    Conn#conn{req_capabilities = ReqCap, resp_capabilities = RespCap}.

handle_done_token({done, Status, _TrnsctConn, Count}, TokensBufer, Results) ->
    TokensBuferR = lists:reverse(TokensBufer),
    handle_done_status(Status, Count, TokensBuferR, Results).

handle_done_status([more|_], _Count, TokensBufer, Results) ->
    {next_token, lists:reverse(TokensBufer), Results};
handle_done_status([count|Status], Count, TokensBufer, Results) ->
    {Result, TokensBufer2} = take_result(TokensBufer, Count),
    handle_done_status(Status, Count, TokensBufer2, [Result|Results]);
handle_done_status([proc|Status], Count, TokensBufer, Results) ->
    Results2 = drop_inproc_updates(Results),
    {ProcResult, TokensBufer2} = take_procedure_result(TokensBufer),
    handle_done_status(Status, Count, TokensBufer2, [ProcResult|Results2]);
handle_done_status([Flag|Status], Count, TokensBufer, Results) 
        when Flag =:= event; Flag =:= attn; Flag =:= trans ->
    handle_done_status(Status, Count, TokensBufer, Results);
handle_done_status([error|_Status], _Count, TokensBufer, _Results) ->
    {Message, _} = take_token(message, TokensBufer), 
        %% TODO check that the class > 10
    {error, remote, Message};
handle_done_status([], Count, TokensBufer, Results) ->
    case Results of
        [] ->
            {ok, TokensBufer, [{affected_rows, Count}]};
        _ ->
            {ok, TokensBufer, lists:reverse(Results)}
    end.

take_result(TokensBufer, Count) ->
    case take_token(rowformat, TokensBufer) of
        {undefined, _} ->  %% on updates
            {{affected_rows, Count}, TokensBufer};
        {{rowformat, _Amount, RowFormat}, TokensBufer2} ->
            FieldNames = [get_field_name(Fmt) || Fmt <- RowFormat],
            {MetaInfo, TokensBufer3} = take_metainfo(TokensBufer2),
            {TokensList, TokensBufer4} = take_tokens(row, TokensBufer3, Count),
            Rows = [Row || {row, Row} <- TokensList],
            {{result_set, FieldNames, MetaInfo, Rows}, TokensBufer4}
    end.

take_procedure_result(TokensBufer) ->
    {Status, TokensBufer2} = take_token_value(returnstatus, TokensBufer),
    %% Get OutParams from returnvalue token if simple table
    %{Result, TokensBufer2} = take_tokens(returnvalue, TokensBufer, all),
    %{[Value || {returnvalue, Value} <- Result], TokensBufer2}.
    %% Get OutParams from params token if widetable
    {OutParams, TokensBufer3} = take_token_value(params, TokensBufer2, []),
    {{procedure_result, Status, OutParams}, TokensBufer3}.

drop_inproc_updates(Results) ->
    lists:filter(fun ({affected_rows, _}) -> false; (_) -> true end, Results).

get_field_name(#format{label_name = <<>>, column_name = ColumnName}) ->
    ColumnName;
get_field_name(#format{label_name = LabelName}) ->
    LabelName.

take_metainfo(TokensBufer) ->
    case take_token(orderby, TokensBufer) of
        {undefined, _} ->
            {[], TokensBufer};
        {Token, TokensBufer2} ->
            {[Token], TokensBufer2}
    end.

handle_envchange_token({envchange, EnvChange}, Conn) ->
    lists:foldl(fun set_env/2, Conn, EnvChange).

set_env({packet_size = Key, NewValue, _OldValue}, Conn) ->
    Value = list_to_integer(binary_to_list(NewValue)), %%TODO
    _ = inet:setopts(Conn#conn.socket, [{buffer, Value}]),
    Env = lists:keystore(Key, 1, Conn#conn.env, {Key, Value}), 
    Conn#conn{env = Env, packet_size = Value};
set_env({Key, NewValue, _OldValue}, Conn) ->
    Env = lists:keystore(Key, 1, Conn#conn.env, {Key, NewValue}),
    Conn#conn{env = Env}.

take_tokens(TokenName, TokensBufer, Count) ->
    take_tokens(TokenName, TokensBufer, Count, []).

take_tokens(TokenName, TokensBufer, Count, Result) when Count > 0 ->
    case take_token(TokenName, TokensBufer) of
        {undefined, _} ->
            {lists:reverse(Result), TokensBufer};
        {TokenTuple, TokensBufer2} ->
            take_tokens(TokenName, TokensBufer2, Count-1, [TokenTuple|Result])
    end;
take_tokens(_TokenName, TokensBufer, _Count, Result) ->
    {lists:reverse(Result), TokensBufer}.

take_token(TokenName, TokensBufer) ->
    case lists:keytake(TokenName, 1, TokensBufer) of
        {value, TokenTuple, TokensBufer2} ->
            {TokenTuple, TokensBufer2};
        false ->
            {undefined, TokensBufer}
    end.

take_token_value(Name, TokensBufer) ->
    take_token_value(Name, TokensBufer, undefined).

take_token_value(Name, TokensBufer, Default) ->
    case take_token(Name, TokensBufer) of
        {undefined, _} ->
            {Default, TokensBufer};
        {{Name, Value}, TokensBufer2} ->
            {Value, TokensBufer2}
    end.

send(Socket, Data) ->
    gen_tcp:send(Socket, Data).

recv(Socket, Timeout) ->
    recv(Socket, Timeout, <<>>, <<>>).

recv(Socket, Timeout, Buffer, ResultData) ->
    case ?DECODER:decode_packet(Buffer) of
        {ok, 0, PacketBody, Buffer2} ->
            ResultData2 = <<ResultData/binary, PacketBody/binary>>,
            recv(Socket, Timeout, Buffer2, ResultData2);
        {ok, 1, PacketBody, _} ->
            {ok, <<ResultData/binary, PacketBody/binary>>};
        {error, incomplete_packet} ->
            case gen_tcp:recv(Socket, 0, Timeout) of
                {ok, NetworkData} ->
                    NewBuffer = <<Buffer/bits, NetworkData/bits>>,
                    recv(Socket, Timeout, NewBuffer, ResultData);
                Error ->
                    Error
            end
    end.
