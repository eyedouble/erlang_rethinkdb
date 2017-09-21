
% _build/default/lib/erlang_rethinkdb/src/erlang_rethinkdb.erl:7: Warning: export_all flag enabled - all functions will be exported
% _build/default/lib/erlang_rethinkdb/src/erlang_rethinkdb.erl:37: Warning: variable 'KeyLength' is unused
% _build/default/lib/erlang_rethinkdb/src/erlang_rethinkdb.erl:104: Warning: erlang:now/0: Deprecated BIF. See the "Time and Time Correction in Erlang" chapter of the ERTS User's Guide for more information.
% _build/default/lib/erlang_rethinkdb/src/erlang_rethinkdb.erl:105: Warning: random:seed/3: the 'random' module is deprecated; use the 'rand' module instead
% _build/default/lib/erlang_rethinkdb/src/erlang_rethinkdb.erl:106: Warning: random:uniform/1: the 'random' module is deprecated; use the 'rand' module instead
% _build/default/lib/erlang_rethinkdb/src/erlang_rethinkdb.erl:121: Warning: a term is constructed, but never used
% _build/default/lib/erlang_rethinkdb/src/erlang_rethinkdb.erl:195: Warning: variable 'Reason' is unused
% _build/default/lib/erlang_rethinkdb/src/erlang_rethinkdb.erl:199: Warning: variable 'RecvResultCode' is unused


-module(erlang_rethinkdb).

%%-export([connect/1]).
-compile(export_all). %% replace with -export()

%% From ql2.proto
-define(RETHINKDB_VERSION, 32#723081e1).

-include("ql2_pb.hrl").
-include("term.hrl").

-ifndef(PRINT).
-define(PRINT(Var), io:format("DEBUG: ~p:~p - ~p~n~n ~p~n~n", [?MODULE, ?LINE, ??Var, Var])).
-endif.


start() ->
  application:start(erlang_rethinkdb),
  ok.

stop() ->
  application:stop(erlang_rethinkdb),
  ok.

%% http://erlang.org/pipermail/erlang-questions/2004-December/013734.html
connect() ->
  connect("127.0.0.1").

connect(RethinkDBHost) ->
  {ok, Sock} = gen_tcp:connect(RethinkDBHost, 28015,
                               [binary, {packet, 0}, {active, false}]),
  handshake(Sock, <<"">>),
  Sock.

close(Sock) ->
  gen_tcp:close(Sock).

% handshake(Sock, AuthKey) ->
handshake(Sock, _) ->
  % KeyLength = iolist_size(AuthKey),
  ok = gen_tcp:send(Sock, binary:encode_unsigned(16#400c2d20, little)),
  ok = gen_tcp:send(Sock, [<<0:32/little-unsigned>>]),
  % Using JSON Protocol
  ok = gen_tcp:send(Sock, [<<16#7e6970c7:32/little-unsigned>>]),

  {ok, Response} = read_until_null(Sock),
  case Response == <<"SUCCESS",0>> of
    true -> ok;
    false ->
      io:fwrite("Error: ~s~n", [Response]),
      {error, Response}
  end.


%%% RethinkDB API
r(Q) -> query(Q).
r(Socket, RawQuery) ->
  query(Socket, RawQuery).

%%% Fetch next batch
%%% When the response_type is SUCCESS_PARTIAL=3, we can call next to send more data
next({Socket, Token, R}, F) ->
  lists:map(F, R),

  Iolist = ["[2]"],
  Length = iolist_size(Iolist),
  ok = gen_tcp:send(Socket, [<<Token:64/little-unsigned>>, <<Length:32/little-unsigned>>, Iolist]),
  case recv(Socket) of
    {ok, Data} ->
      io:format(Data),
      Dterm = jsx:decode(Data),
      ?PRINT( Dterm),
      next({Socket, Token, proplists:get_value(<<"r">>, Dterm)}, F);
    {ok, R} ->
      io:format("Ok "),
      io:format(R),
      Rterm = jsx:decode(R),
      io:format(proplists:get_value(<<"r">>, Rterm)),
      case proplists:get_value(<<"t">>, Rterm) of       
        ?RUNTIME_ERROR ->
          io:format("Error"),
          {error, proplists:get_value(<<"r">>, Rterm)};       
        ?SUCCESS_ATOM ->
          io:format("response: a single atom"),
          {ok, proplists:get_value(<<"r">>, Rterm)};
        ?SUCCESS_SEQUENCE ->
          io:format("response: a sequence"),
          {ok, proplists:get_value(<<"r">>, Rterm)};
        ?SUCCESS_PARTIAL ->
          % So we get back a stream, let continous pull query
          io:format("response: partial. Can use next here"),
          next({Socket, Token, proplists:get_value(<<"r">>, Rterm)}, F)
          % {ok, proplists:get_value(<<"r">>, Rterm)}
          %Recv = spawn(?MODULE, stream_recv, [Socket, Token]),
          %Pid = spawn(?MODULE, stream_poll, [{Socket, Token}, Recv]),
          %{ok, {pid, Pid}, proplists:get_value(<<"r">>, Rterm)}
      end;
    {error, ErrReason} ->
      io:fwrite("Got Error when receving: ~s ~n", [ErrReason]),
      {error, ErrReason}
  end.

%%% Build AST from raw query
query(RawQuery) ->
  erlang_rethinkdb_ast:make(RawQuery).

%%% Build and Run query when passing Socket
query(Socket, RawQuery) ->
  query(Socket, RawQuery, [{}]).

query(Socket, RawQuery, Option) ->
  {A1, A2, A3} = now(),
  rand:seed(A1, A2, A3),
  Token = rand:uniform(3709551616),
  %io:format("QueryToken = ~p~n", [Token]),

  Query = erlang_rethinkdb_ast:make(RawQuery),

  io:format("Query = ~p ~n", [Query]),
  Iolist  = jsx:encode([?QUERYTYPE_START, Query, Option]), % ["[1,"] ++ [Query] ++ [",{}]"], % list db 
  Length = iolist_size(Iolist),
  %io:format("Query= ~p~n", [Iolist]),
  %io:format("Length: ~p ~n", [Length]),

  case gen_tcp:send(Socket, [<<Token:64/little-unsigned>>, <<Length:32/little-unsigned>>, Iolist]) of
    ok -> ok;
    {error, Reason} ->
      io:fwrite("Got Error when sending query: ~s ~n", [Reason])
      % ,{error, Reason}
  end,

  case recv(Socket) of
    {ok, R} ->
      io:format("Ok "),
      io:format(R),
      Rterm = jsx:decode(R),
      %proplists:get_value(<<"r">>, Rterm),
      case proplists:get_value(<<"t">>, Rterm) of
        ?RUNTIME_ERROR ->
          io:format("Error"),
          {error, proplists:get_value(<<"r">>, Rterm)};
        ?SUCCESS_ATOM ->
          io:format("response: a single atom"),
          {ok, proplists:get_value(<<"r">>, Rterm)};
        ?SUCCESS_SEQUENCE ->
          io:format("response: a sequence"),
          {ok, proplists:get_value(<<"r">>, Rterm)};
        ?SUCCESS_PARTIAL ->
          % So we get back a stream, let continous pull query
          io:format("response: partial. Can use next here"),
          {cursor, {Socket, Token, proplists:get_value(<<"r">>, Rterm)}}
          %Recv = spawn(?MODULE, stream_recv, [Socket, Token]),
          %Pid = spawn(?MODULE, stream_poll, [{Socket, Token}, Recv]),
          %{ok, {pid, Pid}, proplists:get_value(<<"r">>, Rterm)}
      end
      ;
    {error, ErrReason} ->
      io:fwrite("Got Error when receving: ~s ~n", [ErrReason]),
      {error, ErrReason}
  end
  .
%%%

stream_stop(Socket, Token) ->
  Iolist = ["[3]"],
  Length = iolist_size(Iolist),
  ok = gen_tcp:send(Socket, [<<Token:64/little-unsigned>>, <<Length:32/little-unsigned>>, Iolist])
  .

%% receive data from stream, then pass to other process
stream_recv(Socket, Token) ->
  receive
    R ->
      io:fwrite("Changefeed receive item: ~p ~n",[R])
  end,
  stream_recv(Socket, Token)
  .

%Continues getting data from stream
stream_poll({Socket, Token}, PidCallback) ->
  Iolist = ["[2]"],
  Length = iolist_size(Iolist),
  io:format("Block socket <<< waiting for more data from stream~n"),

  ok = gen_tcp:send(Socket, [<<Token:64/little-unsigned>>, <<Length:32/little-unsigned>>, Iolist]),
  {ok, R} = recv(Socket),
  Rterm = jsx:decode(R),
  spawn(fun() -> PidCallback ! proplists:get_value(<<"r">>, Rterm) end),
  stream_poll({Socket, Token}, PidCallback)
  .
%% Receive data from Socket
%%Once the query is sent, you can read the response object back from the server. The response object takes the following form:
%%
%% * The 8-byte unique query token
%% * The length of the response, as a 4-byte little-endian integer
%% * The JSON-encoded response
recv(Socket) ->
  case gen_tcp:recv(Socket, 8) of
    {ok, Token} ->
      <<K:64/little-unsigned>> = Token,
      io:format("Get back token ~p ~n", [K]),
      io:format("Get back token ~p ~n", [Token]);
    % {error, Reason} ->
    {error, _} ->
      io:format("Fail to parse token")
  end,

  % {RecvResultCode, ResponseLength} = gen_tcp:recv(Socket, 4),
  {_, ResponseLength} = gen_tcp:recv(Socket, 4),
  <<Rs:32/little-unsigned>> = ResponseLength,
  io:format("ResponseLengh ~p ~n", [Rs]),
  io:format("ResponseLengh ~p ~n", [ResponseLength]),

  {ResultCode, Response} = gen_tcp:recv(Socket, binary:decode_unsigned(ResponseLength, little)),
  case ResultCode of
    ok ->
      {ok, Response};
    error ->
      io:fwrite("Got Error ~s ~n", [Response]),
      {error, Response}
  end.

read_until_null(Socket) ->
  read_until_null(Socket, []).

read_until_null(Socket, Acc) ->
  %%{ok, Response} = gen_tcp:recv(Socket, 0),
  case gen_tcp:recv(Socket, 0) of
    {error, OtherSendError} ->
      io:format("Some other error on socket (~p), closing", [OtherSendError]),
      %%Client ! {self(),{error_sending, OtherSendError}},
      gen_tcp:close(Socket);
    {ok, Response} ->
      Result = [Acc, Response],
      case is_null_terminated(Response) of
        true -> {ok, iolist_to_binary(Result)};
        false -> read_until_null(Socket, Result)
      end
  end.

is_null_terminated(B) ->
  binary:at(B, iolist_size(B) - 1) == 0.
