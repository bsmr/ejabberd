%%%----------------------------------------------------------------------
%%% File    : rest.erl
%%% Author  : Christophe Romain <christophe.romain@process-one.net>
%%% Purpose : Generic REST client
%%% Created : 16 Oct 2014 by Christophe Romain <christophe.romain@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2019   ProcessOne
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License along
%%% with this program; if not, write to the Free Software Foundation, Inc.,
%%% 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
%%%
%%%----------------------------------------------------------------------

-module(rest).

-behaviour(ejabberd_config).

-export([start/1, stop/1, get/2, get/3, post/4, delete/2,
         put/4, patch/4, request/6, with_retry/4,
         encode_json/1, opt_type/1]).

-include("logger.hrl").

-define(HTTP_TIMEOUT, 10000).
-define(CONNECT_TIMEOUT, 8000).
-define(CONTENT_TYPE, "application/json").

start(Host) ->
    application:start(inets),
    Size = ejabberd_config:get_option({ext_api_http_pool_size, Host}, 100),
    httpc:set_options([{max_sessions, Size}]).

stop(_Host) ->
    ok.

with_retry(Method, Args, MaxRetries, Backoff) ->
    with_retry(Method, Args, 0, MaxRetries, Backoff).
with_retry(Method, Args, Retries, MaxRetries, Backoff) ->
    case apply(?MODULE, Method, Args) of
        %% Only retry on timeout errors
        {error, {http_error,{error,Error}}}
           when Retries < MaxRetries
           andalso (Error == 'timeout' orelse Error == 'connect_timeout') ->
            timer:sleep(round(math:pow(2, Retries)) * Backoff),
            with_retry(Method, Args, Retries+1, MaxRetries, Backoff);
        Result ->
            Result
    end.

get(Server, Path) ->
    request(Server, get, Path, [], ?CONTENT_TYPE, <<>>).
get(Server, Path, Params) ->
    request(Server, get, Path, Params, ?CONTENT_TYPE, <<>>).

delete(Server, Path) ->
    request(Server, delete, Path, [], ?CONTENT_TYPE, <<>>).

post(Server, Path, Params, Content) ->
    Data = encode_json(Content),
    request(Server, post, Path, Params, ?CONTENT_TYPE, Data).

put(Server, Path, Params, Content) ->
    Data = encode_json(Content),
    request(Server, put, Path, Params, ?CONTENT_TYPE, Data).

patch(Server, Path, Params, Content) ->
    Data = encode_json(Content),
    request(Server, patch, Path, Params, ?CONTENT_TYPE, Data).

request(Server, Method, Path, Params, Mime, Data) ->
    {Query, Opts} = case Params of
			{_, _} -> Params;
			_ -> {Params, []}
		   end,
    URI = to_list(url(Server, Path, Query)),
    HttpOpts = [{connect_timeout, ?CONNECT_TIMEOUT},
		{timeout, ?HTTP_TIMEOUT}],
    Hdrs = [{"connection", "keep-alive"},
            {"Accept", "application/json"},
	    {"User-Agent", "ejabberd"}]
	   ++ custom_headers(Server),
    Req = if
              (Method =:= post) orelse (Method =:= patch) orelse (Method =:= put) orelse (Method =:= delete) ->
                  {URI, Hdrs, to_list(Mime), Data};
              true ->
                  {URI, Hdrs}
          end,
    Begin = os:timestamp(),
    Result = try httpc:request(Method, Req, HttpOpts, [{body_format, binary}]) of
        {ok, {{_, Code, _}, RetHdrs, Body}} ->
            try decode_json(Body) of
                JSon ->
		    case proplists:get_bool(return_headers, Opts) of
			true -> {ok, Code, RetHdrs, JSon};
			false -> {ok, Code, JSon}
		    end
            catch
                _:Error ->
                    ?ERROR_MSG("HTTP response decode failed:~n"
                               "** URI = ~s~n"
                               "** Body = ~p~n"
                               "** Err = ~p",
                               [URI, Body, Error]),
                    {error, {invalid_json, Body}}
            end;
        {error, Reason} ->
            ?ERROR_MSG("HTTP request failed:~n"
                       "** URI = ~s~n"
                       "** Err = ~p",
                       [URI, Reason]),
            {error, {http_error, {error, Reason}}}
        catch
        exit:Reason ->
            ?ERROR_MSG("HTTP request failed:~n"
                       "** URI = ~s~n"
                       "** Err = ~p",
                       [URI, Reason]),
            {error, {http_error, {error, Reason}}}
    end,
    ejabberd_hooks:run(backend_api_call, Server, [Server, Method, Path]),
    case Result of
        {error, {http_error,{error,timeout}}} ->
            ejabberd_hooks:run(backend_api_timeout, Server,
                               [Server, Method, Path]);
        {error, {http_error,{error,connect_timeout}}} ->
            ejabberd_hooks:run(backend_api_timeout, Server,
                               [Server, Method, Path]);
        {error, _} ->
            ejabberd_hooks:run(backend_api_error, Server,
                               [Server, Method, Path]);
	_ ->
	    End = os:timestamp(),
            Elapsed = timer:now_diff(End, Begin) div 1000, %% time in ms
            ejabberd_hooks:run(backend_api_response_time, Server,
                               [Server, Method, Path, Elapsed])
    end,
    Result.

%%%----------------------------------------------------------------------
%%% HTTP helpers
%%%----------------------------------------------------------------------

to_list(V) when is_binary(V) ->
    binary_to_list(V);
to_list(V) when is_list(V) ->
    V.

encode_json(Content) ->
    case catch jiffy:encode(Content) of
        {'EXIT', Reason} ->
            ?ERROR_MSG("HTTP content encodage failed:~n"
                       "** Content = ~p~n"
                       "** Err = ~p",
                       [Content, Reason]),
            <<>>;
        Encoded ->
            Encoded
    end.

decode_json(<<>>) -> [];
decode_json(<<" ">>) -> [];
decode_json(<<"\r\n">>) -> [];
decode_json(Data) -> jiffy:decode(Data).

custom_headers(Server) ->
  case ejabberd_config:get_option({ext_api_headers, Server},
                                  <<>>) of
        <<>> ->
            [];
        Hdrs ->
            lists:foldr(fun(Hdr, Acc) ->
                case binary:split(Hdr, <<":">>) of
                    [K, V] -> [{binary_to_list(K), binary_to_list(V)}|Acc];
                    _ -> Acc
                end
            end, [], binary:split(Hdrs, <<",">>))
    end.

base_url(Server, Path) ->
    BPath = case iolist_to_binary(Path) of
        <<$/, Ok/binary>> -> Ok;
        Ok -> Ok
    end,
    Url = case BPath of
        <<"http", _/binary>> -> BPath;
        _ ->
            Base = ejabberd_config:get_option({ext_api_url, Server},
                                              <<"http://localhost/api">>),
            case binary:last(Base) of
                $/ -> <<Base/binary, BPath/binary>>;
                _ -> <<Base/binary, "/", BPath/binary>>
            end
    end,
    case binary:last(Url) of
        47 -> binary_part(Url, 0, size(Url)-1);
        _ -> Url
    end.

url(Url, []) ->
    Url;
url(Url, Params) ->
    L = [<<"&", (iolist_to_binary(Key))/binary, "=",
          (misc:url_encode(Value))/binary>>
            || {Key, Value} <- Params],
    <<$&, Encoded/binary>> = iolist_to_binary(L),
    <<Url/binary, $?, Encoded/binary>>.
url(Server, Path, Params) ->
    case binary:split(base_url(Server, Path), <<"?">>) of
        [Url] ->
            url(Url, Params);
        [Url, Extra] ->
            Custom = [list_to_tuple(binary:split(P, <<"=">>))
                      || P <- binary:split(Extra, <<"&">>, [global])],
            url(Url, Custom++Params)
    end.

-spec opt_type(atom()) -> fun((any()) -> any()) | [atom()].
opt_type(ext_api_http_pool_size) ->
    fun (X) when is_integer(X), X > 0 -> X end;
opt_type(ext_api_url) ->
    fun (X) -> iolist_to_binary(X) end;
opt_type(ext_api_headers) ->
    fun (X) -> iolist_to_binary(X) end;
opt_type(_) -> [ext_api_http_pool_size, ext_api_url, ext_api_headers].
