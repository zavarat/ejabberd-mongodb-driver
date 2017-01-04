%%%-------------------------------------------------------------------
%%% File    : ejabberd_mongodb_sup.erl
%%% @author Andrei Leontev <andrei.leontev@protonmail.ch>
%%% @doc
%%% Interface to MongoDB database
%%% @end
%%% Created : 12 Nov 2016 by Andrei Leontev <andrei.leontev@protonmail.ch>
%%%
%%% Copyright (C) 2016    Andrei Leontev
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
%%%-------------------------------------------------------------------
-module(ejabberd_mongodb).

-behaviour(gen_server).

%% API
-export([start_link/6, get_proc/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3, is_connected/0]).

-export([insert_one/2, find_one/2]).

-include("ejabberd.hrl").
-include("logger.hrl").

-record(state, {pid = self() :: pid()}).

-define(MONGO_ID, <<"_id">>).

%%%===================================================================
%%% API
%%%===================================================================
%% @private
start_link(Num, Server, Port, Database, _StartInterval, Options) ->
    gen_server:start_link({local, get_proc(Num)}, ?MODULE, [Server, Port, Database, Options], []).

%% @private
is_connected() ->
    lists:all(
      fun({_Id, Pid, _Type, _Modules}) when is_pid(Pid) ->
	      case catch is_process_alive(Pid) of
		  true -> true;
		  _ -> false
	      end;
  	 (_) ->
	      false
     end, supervisor:which_children(ejabberd_mongodb_sup)).

%% @private
get_proc(I) ->
    jlib:binary_to_atom(
      iolist_to_binary(
	[atom_to_list(?MODULE), $_, integer_to_list(I)])).

%% @private
make_binary(Val) ->
    erlang:atom_to_binary(Val, utf8).

insert_one(Col, Obj) ->
    C = make_binary(Col),
    case catch mc_worker_api:insert(get_random_pid(), C, Obj) of
      {'EXIT', Err} ->
          ?ERROR_MSG("Error is happen ~p~n", [Err]),
          error;
      {{true, _Count}, Status} ->
          case maps:get(?MONGO_ID, Status) of 
            {badmap, Map} ->
              ?ERROR_MSG("Insert operation is failed: bad map structure ~p~n", [Map]),
              error;
            {badkey, Key} ->
              ?ERROR_MSG("Insert operation is failed: Key ~p doesn\'t exist ~n", [Key]),
              error;
            {Val} ->
              {ok, Val}
          end;
      S ->
          ?ERROR_MSG("Unwaited response ~p~n", [S]),
          error
    end.

find_one(Col, Sel) ->
    C = make_binary(Col),
    case catch mc_worker_api:find_one(get_random_pid(), C, Sel) of
      {'EXIT', Err} ->
        ?ERROR_MSG("Error is happen ~p~n", [Err]),
        error;
      Status ->
        case maps:get(?MONGO_ID, Status) of 
          {badmap, Map} ->
            ?ERROR_MSG("Find operation is failed: bad map structure ~p~n", [Map]),
            error;
          {badkey, Key} ->
            ?ERROR_MSG("Find operation is failed: Key ~p doesn\'t exist ~n", [Key]),
            error;
          {Val} ->
            {ok, Status}
        end
    end.

%%%===================================================================
%%% gen_server API
%%%===================================================================
%% @private
init([Server, Port, Database, _Options]) ->
    case mc_worker_api:connect([{database, Database}, {host, Server}, {port, Port}]) of
        {ok, Pid} ->
            erlang:monitor(process, Pid),
            {ok, #state{pid = Pid}};
        Err ->
            {stop, Err}
    end.

%% @private
handle_call(get_pid, _From, #state{pid = Pid} = State) ->
    {reply, {ok, Pid}, State};
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%% @private
handle_cast(_Msg, State) ->
    {noreply, State}.

%% @private
handle_info({'DOWN', _MonitorRef, _Type, _Object, _Info}, State) ->
    {stop, normal, State};
handle_info(_Info, State) ->
    ?ERROR_MSG("unexpected info: ~p", [_Info]),
    {noreply, State}.

%% @private
terminate(_Reason, _State) ->
    ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

get_random_pid() ->
    PoolPid = ejabberd_mongodb_sup:get_random_pid(),
    get_mongodb_pid(PoolPid).

get_mongodb_pid(PoolPid) ->
    case catch gen_server:call(PoolPid, get_pid) of
	{ok, Pid} ->
	    Pid;
	{'EXIT', {timeout, _}} ->
	    throw({error, timeout});
	{'EXIT', Err} ->
	    throw({error, Err})
    end.

