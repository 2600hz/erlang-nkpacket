%% -------------------------------------------------------------------
%%
%% Copyright (c) 2018 Carlos Gonzalez Florido.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @doc Default implementation for HTTP1 clients
%% Expects parameter notify_pid in user's state
%% Will send messages {nkpacket_httpc_protocol, Ref, Term},
%% Term :: {head, Status, Headers} | {body, Body} | {chunk, Chunk}

-module(nkpacket_httpc).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([request/3, request/4, request/5, request/6, do_request/6]).
-export([test/0, s3_test_get/0, s3_test_put/0, s3_test_get_url/0, s3_test_put_url/0]).
-export_type([method/0, path/0, header/0, body/0]).

-include("nkpacket.hrl").
-include_lib("nklib/include/nklib.hrl").


%% ===================================================================
%% Types
%% ===================================================================

-type method() :: get | post | put | delete | head | patch.
-type path() :: binary().
-type header() :: {binary(), binary()}.
-type body() :: iolist().
-type status() :: 100..599.

-type opts() ::
    nkpacket:connect_opts() |
    #{
        headers => [header()]       % Headers to include in all requests
    }.



%% ===================================================================
%% Public
%% ===================================================================

%% @doc
-spec request(nkpacket:connect_spec(), method(), path()) ->
    {ok, status(), [header()], binary()} | {error, term()}.

request(Url, Method, Path) ->
    request(Url, Method, Path, []).


%% @doc
-spec request(nkpacket:connect_spec(), method(), path(), [header()]) ->
    {ok, status(), [header()], binary()} | {error, term()}.

request(Url, Method, Path, Hds) ->
    request(Url, Method, Path, Hds, <<>>).


%% @doc
-spec request(nkpacket:connect_spec(), method(), path(), [header()], body()) ->
    {ok, status(), [header()], binary()} | {error, term()}.

request(Url, Method, Path, Hds, Body) ->
    request(Url, Method, Path, Hds, Body, #{}).


%% @doc
-spec request(nkpacket:connect_spec(), method(), path(), [header()], body(), opts()) ->
    {ok, status(), [header()], binary()} | {error, term()}.

request(Url, Method, Path, Hds, Body, Opts) ->
    ConnOpts = #{
        monitor => self(),
        user_state => maps:with([headers], Opts),
        connect_timeout => maps:get(connect_timeout, Opts, 1000),
        idle_timeout => maps:get(idle_timeout, Opts, 60000),
        debug => maps:get(debug, Opts, false)
    },
    case nkpacket:connect(Url, ConnOpts) of
        {ok, ConnPid} ->
            do_request(ConnPid, Method, Path, Hds, Body, Opts);
        {error, Error} ->
            {error, Error}
    end.


%% @doc
-spec do_request(pid(), method(), path(), [header()], body(), opts()) ->
    {ok, status(), [header()], binary()} | {error, term()}.

do_request(ConnPid, Method, Path, Hds, Body, Opts) ->
    Ref = make_ref(),
    Req = #{
        ref => Ref,
        pid => self(),
        method => Method,
        path => Path,
        headers => Hds,
        body => Body
    },
    Timeout = maps:get(timeout, Opts, 5000),
    case nkpacket:send(ConnPid, {nkpacket_http, Req}) of
        {ok, ConnPid} ->
            receive
                {nkpacket_httpc_protocol, Ref, {head, Status, Headers}} ->
                    do_request_body(Ref, Opts, Timeout, Status, Headers, []);
                {nkpacket_httpc_protocol, Ref, {error, Error}} ->
                    {error, Error}
            after
                Timeout ->
                    {error, timeout}
            end;
        {error, Error} ->
            {error, Error}
    end.


%% @private
do_request_body(Ref, Opts, Timeout, Status, Headers, Chunks) ->
    receive
        {nkpacket_httpc_protocol, Ref, {chunk, Data}} ->
            do_request_body(Ref, Opts, Timeout, Status, Headers, [Data|Chunks]);
        {nkpacket_httpc_protocol, Ref, {body, Body}} ->
            case Chunks of
                [] ->
                    {ok, Status, Headers, Body};
                _ when Body == <<>> ->
                    {ok, Status, Headers, list_to_binary(lists:reverse(Chunks))};
                _ ->
                    {error, invalid_chunked}
            end;
        {nkpacket_httpc_protocol, Ref, {error, Error}} ->
            {error, Error}
    after Timeout ->
        {error, timeout2}
    end.


%% ===================================================================
%% S3 Test
%% ===================================================================

% Set your credentials here
% export MINIO_ACCESS_KEY=5UBED0Q9FB7MFZ5EWIOJ; export MINIO_SECRET_KEY=CaK4frX0uixBOh16puEsWEvdjQ3X3RTDvkvE+tUI; minio server .

-define(TEST_KEY, <<"5UBED0Q9FB7MFZ5EWIOJ">>).
-define(TEST_SECRET, <<"CaK4frX0uixBOh16puEsWEvdjQ3X3RTDvkvE+tUI">>).
-define(TEST_HOST, <<"http://127.0.0.1:9000">>).
-define(TEST_BUCKET, <<"bucket1">>).
-define(TEST_PATH, <<"/test1">>).


test() ->
    {ok, 200, _, <<>>} = s3_test_put(),
    {ok, 200, _, <<"124">>} = s3_test_get(),
    {ok, 200, _, <<>>} = s3_test_put_url(),
    {ok, 200, _, <<"125">>} = s3_test_get_url(),
    ok.


s3_test_config() ->
    #{
        key => ?TEST_KEY,
        secret => ?TEST_SECRET,
        host => ?TEST_HOST
    }.


s3_test_get() ->
    C = s3_test_config(),
    {Uri, Path, Headers} = nkpacket_httpc_s3:get_object(?TEST_BUCKET, ?TEST_PATH, C),
    Opts = #{tls_verify => host, no_host_header=>true},
    request(Uri, get, Path, Headers, <<>>, Opts).


s3_test_put() ->
    C1 = s3_test_config(),
    C2 = C1#{
        headers => [{<<"content-type">>, <<"application/json">>}],
        params => [{<<"a">>, <<"1">>}, {<<"b">>, <<"2">>}],
        meta => [{<<"b">>, <<"2">>}],
        acl => private
    },
    Body = <<"124">>,
    Hash = crypto:hash(sha256, Body),
    {Uri, Path, Headers} = nkpacket_httpc_s3:put_object(?TEST_BUCKET, ?TEST_PATH, Hash, C2),
    Opts = #{tls_verify => host, no_host_header=>true},
    request(Uri, put, Path, Headers, Body, Opts).


s3_test_put_url() ->
    CT = <<"application/json">>,
    {Uri, Path} = nkpacket_httpc_s3:make_put_url(?TEST_BUCKET, ?TEST_PATH, CT,
                                                 5000, s3_test_config()),
    Body = <<"125">>,
    Opts = #{tls_verify => host},
    request(Uri, put, Path, [{<<"content-type">>, CT}], Body, Opts).



s3_test_get_url() ->
    {Uri, Path} = nkpacket_httpc_s3:make_get_url(?TEST_BUCKET, ?TEST_PATH, 5000, s3_test_config()),
    Opts = #{tls_verify => host},
    request(Uri, get, Path, [], <<>>, Opts).


%%%% @private
%%to_bin(Term) when is_binary(Term) -> Term;
%%to_bin(Term) -> nklib_util:to_binary(Term).
