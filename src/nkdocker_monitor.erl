%% -------------------------------------------------------------------
%%
%% Copyright (c) 2016 Carlos Gonzalez Florido.  All Rights Reserved.
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

-module(nkdocker_monitor).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([register/1, register/2, unregister/1, unregister/2, get_docker/1]).
-export([get_all_data/1, get_data/2, start_stats/2, get_all/0]).
-export([start_link/3]).
-export([init/1, terminate/2, code_change/3, handle_call/3,
         handle_cast/2, handle_info/2]).
-export_type([monitor_id/0, notify/0, data/0]).

-define(LLOG(Type, Txt, Args), lager:Type("NkDOCKER Monitor "++Txt, Args)).

-define(UPDATE_TIME, 10000).

-callback nkdocker_notify(monitor_id(), notify()) ->
    ok.

%% ===================================================================
%% Types
%% ===================================================================

-type monitor_id() :: {inet:ip_address(), inet:port()}.

-type notify() ::
    {docker, {Id::binary(), Status::atom(), From::binary(), Time::integer()}} |
    {stats, {Id::binary(), Data::binary()}}  |
    {start, {Name::binary(), Image::binary(), Data::data()}} |
    {stop, {Name::binary(), Image::binary(), Data::data()}}.

-type data() ::
    #{
        name => binary(),
        id => binary(),
        image => binary(),
        env => map(),
        labels => map(),
        inspect => map(),          % inspect result
        stats => map()
    }.




%% ===================================================================
%% Public
%% ===================================================================


%% @doc Equivalent to register(CallBack, #{})
-spec register(module()) ->
    {ok, monitor_id()} | {error, term()}.

register(CallBack) ->
    nkdocker_monitor:register(CallBack, #{}).


%% @doc Registers a server to listen to docker events
%% For each new event, Callback:nkdocker_notify(id(), event()) will be called
%% The first caller for a specific ip and port daemon will start the server
-spec register(module(), nkdocker:conn_opts()) ->
    {ok, monitor_id()} | {error, term()}.

register(CallBack, Opts) ->
    case find_monitor(Opts) of
        {ok, MonId, none} ->
            case nkdocker_sup:start_monitor(MonId, CallBack, Opts) of
                {ok, _Pid} ->
                    {ok, MonId};
                {error, Error} ->
                    {error, Error}
            end;
        {ok, _MonId, Pid} ->
            gen_server:call(Pid, {register, CallBack});
        {error, Error} ->
            {error, Error}
    end.


%% @doc Equivalent to runegister(CallBack, #{})
-spec unregister(module()) ->
    ok | {error, term()}.

unregister(CallBack) ->
    unregister(CallBack, #{}).


%% @doc Unregisters a callback
%% After the last callback is unregistered, the server stops
unregister(Callback, Opts) ->
    case find_monitor(Opts) of
        {ok, _MonId, none} ->
            ok;
        {ok, _MonId, Pid} ->
            gen_server:cast(Pid, {unregister, Callback});
        {error, Error} ->
            {error, Error}
    end.


%% @doc Get the docker server pid
-spec get_docker(monitor_id()) ->
    {ok, pid()} | {error, term()}.

get_docker(MonId) ->
    case nklib_proc:values({?MODULE, MonId}) of
        [] ->
            {error, unknown_monitor};
        [{DockerPid, _Pid}] ->
            {ok, DockerPid}
    end.


%% @doc Gets all containers info
-spec get_all_data(monitor_id()) ->
    {ok, #{binary() => data()}} | {error, term()}.

get_all_data(MonId) ->
    do_call(MonId, get_all_data).


%% @doc Get specific container info
-spec get_data(monitor_id(), binary()) ->
    {ok, data()} | {error, term()}.

get_data(MonId, Id) ->
    do_call(MonId, {get_data, nklib_util:to_binary(Id)}).


%% @doc Start stats for a containers
-spec start_stats(monitor_id(), binary()) ->
    ok | {error, term()}.

start_stats(MonId, Id) ->
    do_call(MonId, {start_stats, nklib_util:to_binary(Id)}).


%% @doc Gets all started monitors
-spec get_all() ->
    [{monitor_id(), pid()}].

get_all() ->
    nklib_proc:values(?MODULE).


% ===================================================================
%% gen_server behaviour
%% ===================================================================

%% @private
start_link(MonId, CallBack, Opts) ->
    gen_server:start_link(?MODULE, [MonId, CallBack, Opts], []).


-record(state, {
    id :: monitor_id(),
    server :: pid(),
    event_ref :: reference(),
    regs = [] :: [module()],
    time = 0 :: integer(),
    cont_datas = #{} :: #{Name::binary() => map()},
    cont_ids = #{} :: #{Id::binary() => Name::binary()},
    stats_refs = #{} :: #{reference() => Name::binary()}
}).


%% @private
-spec init(term()) ->
    {ok, tuple()} | {ok, tuple(), timeout()|hibernate} |
    {stop, term()} | ignore.

init([MonId, CallBack, Opts]) ->
    case nkdocker_server:start_link(Opts) of
        {ok, Pid} ->
            monitor(process, Pid),
            true = nklib_proc:reg({?MODULE, MonId}, Pid),
            nklib_proc:put(?MODULE, MonId),
            EvOpts = case nkdocker_app:get(event_last_time, 0) of
                0 -> #{};
                Time -> #{since=>Time-1}
            end,
            case nkdocker:events(Pid, EvOpts) of
                {async, Ref} ->
                    Regs = nkdocker_app:get(monitor_callbacks, []),
                    case Regs of
                        [] -> ok;
                        _ -> ?LLOG(warning, "recovered callbacks: ~p", [Regs])
                    end,
                    Regs2 = nklib_util:store_value(CallBack, Regs),
                    ?LLOG(info, "server start (~p)", [MonId]),
                    self() ! update_all,
                    {ok, #state{id=MonId, server=Pid, event_ref=Ref, regs=Regs2}};
                {error, Error} ->
                    {stop, Error}
            end;
        {error, Error} ->
            {stop, Error}
    end.


%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {noreply, #state{}} | {reply, term(), #state{}} |
    {stop, Reason::term(), #state{}} | {stop, Reason::term(), Reply::term(), #state{}}.

handle_call({register, Module}, _From, #state{id=Id, regs=Regs}=State) ->
    Regs2 = nklib_util:store_value(Module, Regs),
    nkdocker_app:put(monitor_callbacks, Regs2),
    {reply, {ok, Id}, State#state{regs=Regs2}};

handle_call(get_all_data, _From, #state{cont_datas=Datas}=State) ->
    {reply, {ok, Datas}, State};

handle_call({get_data, Id}, _From, State) ->
    Reply = case find_data(Id, State) of
        {ok, _Name, Data} -> {ok, Data};
        not_found -> {error, container_not_found}
    end,
    {reply, Reply, State};

handle_call({start_stats, Id}, _From, State) ->
    #state{server=Server, cont_datas=Datas, stats_refs=Refs} = State,
    case find_data(Id, State) of
        {ok, _Name, #{stats_ref:=_}} -> 
            {reply, ok, State};
        {ok, Name, Data} ->
            {async, Ref} = nkdocker:stats(Server, Name),
            Data2 = Data#{stats_ref=>Ref},
            Datas2 = maps:put(Name, Data2, Datas),
            Refs2 = maps:put(Ref, Name, Refs),
            {reply, ok, State#state{cont_datas=Datas2, stats_refs=Refs2}};
        not_found ->
            {reply, {error, container_not_found}, State}
    end;

handle_call(state, _From, State) ->
    {reply, State, State};

handle_call(Msg, _From, State) ->
    lager:error("Module ~p received unexpected call ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_cast({unregister, Module}, #state{regs=Regs}=State) ->
    case Regs -- [Module] of
        [] ->
            {stop, normal, State};
        Regs2 ->
            nkdocker_app:put(monitor_callbacks, Regs2),
            {noreply, State#state{regs=Regs2}}
    end;

handle_cast(Msg, State) -> 
    lager:error("Module ~p received unexpected cast ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_info(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_info({nkdocker, Ref, EvData}, #state{event_ref=Ref}=State) ->
    {noreply, event(EvData, State)};

handle_info({nkdocker, Ref, EvData}, #state{stats_refs=Refs}=State) ->
    case maps:find(Ref, Refs) of
        {ok, Name} ->
            case EvData of
                {data, Stats} ->
                    Event = {stats, {Name, Stats}},
                    notify(Event, State);
                Other ->
                    ?LLOG(warning, "STats: ~p", [Other])
            end;
        error ->
            case EvData of
                {ok, <<>>} ->
                    ok;
                _ ->
                    ?LLOG(notice, "stats received for unknown container: ~p", [EvData])
            end
    end,
    {noreply, State};

handle_info(update_all, State) ->
    State2 = update_all(State),
    erlang:send_after(?UPDATE_TIME, self(), update_all),
    {noreply, State2};

handle_info({'DOWN', _Ref, process, Pid, Reason}, #state{server=Pid}=State) ->
    ?LLOG(warning, "docker sever stopped: ~p", [Reason]),
    {stop, docker_server_stop, State};

handle_info(Info, State) -> 
    lager:warning("Module ~p received unexpected info: ~p (~p)", [?MODULE, Info, State]),
    {noreply, State}.


%% @private
-spec code_change(term(), #state{}, term()) ->
    {ok, #state{}}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% @private
-spec terminate(term(), #state{}) ->
    ok.

terminate(Reason, State) ->
    #state{server=Server, event_ref=Ref, stats_refs=Refs} = State,
    lists:foreach(
        fun(StatRef) -> nkdocker:finish_async(Server, StatRef) end, 
        maps:keys(Refs)),
    nkdocker:finish_async(Server, Ref), 
    case Reason of
        normal ->
            ?LLOG(info, "server stop normal", []),
            nkdocker_app:put(monitor_callbacks, []);
        _ ->
            ?LLOG(warning, "server stop anormal: ~p", [Reason]),
            ok
    end,
    ok.
    


% ===================================================================
%% Internal
%% ===================================================================

%% @private
find_monitor(Opts) ->
    case nkdocker_server:get_conn(Opts) of
        {ok, {Ip, #{port:=Port}}} ->
            MonId = {Ip, Port},
            case nklib_proc:values({?MODULE, MonId}) of
                [] ->
                    {ok, MonId, none};
                [{_, Pid}] ->
                    {ok, MonId, Pid}
            end;
        {error, Error} ->
            {error, Error}
    end.


%% @private
do_call(Id, Msg) ->
    do_call(Id, Msg, 5000).


%% @private
do_call(Pid, Msg, Timeout) when is_pid(Pid) ->
    nklib_util:call(Pid, Msg, Timeout);

do_call(Id, Msg, Timeout) ->
    case nklib_proc:values({?MODULE, Id}) of
        [] ->
            {error, unknown_monitor};
        [{_DockerPid, Pid}] ->
            nklib_util:call(Pid, Msg, Timeout)
    end.


%% @private
-spec find_data(binary(), #state{}) ->
    {ok, binary(), data()} | not_found.

find_data(Term, #state{cont_datas=Datas, cont_ids=Ids}) ->
    case maps:find(Term, Datas) of
        {ok, Data} -> 
            {ok, Term, Data};
        error ->
            case maps:find(Term, Ids) of
                {ok, Name} ->
                    {ok, Data} = maps:find(Name, Datas),
                    {ok, Name, Data};
                error ->
                    not_found
            end
    end.


%% @private
event({data, Event}, State) ->
    case Event of
        #{<<"status">>:=Status, <<"id">>:=Id, <<"time">>:=Time} ->
            From = maps:get(<<"from">>, Event, <<>>),
            Status2 = binary_to_atom(Status, latin1),
            notify({docker, {Id, Status2, From, Time}}, State),
            #state{time=Last} = State,
            State2 = case Time > Last of
                true ->
                    nkdocker_app:put(event_last_time, Time),
                    State#state{time=Time};
                false ->
                    State
            end,
            update(Status2, Id, State2);
        _ ->
            ?LLOG(warning, "unrecognized event: ~p", [Event]),
            State
    end;

event({error, Error}, _State) ->
    ?LLOG(warning, "events returned error: ~p", [Error]),
    error({events_error, Error});

event(Other, State) ->
    ?LLOG(warning, "unrecognized events: ~p", [Other]),
    State.


%% @private
notify(Data, #state{id=ServerId, regs=Regs}) ->
    lists:foreach(
        fun(Module) ->
            case catch Module:nkdocker_notify(ServerId, Data) of
                ok ->
                    ok;
                Error ->
                    ?LLOG(warning, "error calling ~p: ~p", [Module, Error])
            end
        end,
        Regs).


%% @private
-spec update(atom(), binary(), #state{}) ->
    #state{}.

update(start, Id, State) ->
    #state{server=Server, cont_ids=Ids, cont_datas=Datas} = State,
    case maps:is_key(Id, Ids) of
        true ->
            State;
        false ->
            {ok, Inspect} = nkdocker:inspect(Server, Id),
            #{<<"Name">>:=Name0, <<"Config">>:=Config} = Inspect,
            #{<<"Labels">>:=Labels, <<"Env">>:=Env, <<"Image">>:=Image} = Config,
            Name = case Name0 of
                <<"/", SubName/binary>> -> SubName;
                _ -> Name0
            end,
            ?LLOG(info, "monitoring container ~s (~s)", [Name, Image]),
            % ?LLOG(info, "Inspect: ~s", [nklib_json:encode_pretty(Inspect)]),
            Data = #{
                name => Name,
                id => Id,
                labels => Labels,
                env => Env,
                image => Image
            },
            notify({start, {Name, Image, Data}}, State),
            Datas2 = maps:put(Name, Data, Datas),
            Ids2 = maps:put(Id, Name, Ids),
            State#state{cont_ids=Ids2, cont_datas=Datas2}
    end;

update(die, Id, State) ->
    #state{cont_datas=Datas, cont_ids=Ids, stats_refs=Refs} = State,
    case maps:find(Id, Ids) of
        {ok, Name} ->
            {ok, #{name:=Name, image:=Image}=Data} = maps:find(Name, Datas),
            ?LLOG(info, "stopping monitoring container ~s (~s)", [Name, Image]),
            notify({stop, {Name, Image, Data}}, State),
            Datas2 = maps:remove(Name, Datas),
            Ids2 = maps:remove(Id, Ids),
            Refs2 = case Data of
                #{stats_ref:=Ref} ->
                    maps:remove(Ref, Refs);
                _ ->
                    Refs
            end,
            State#state{cont_datas=Datas2, cont_ids=Ids2, stats_refs=Refs2};
        error ->
            State
    end;

update(_Status, _Id, State) ->
    State.


%% @private
update_all(#state{server=Server, cont_ids=Ids}=State) ->
    {ok, List} = nkdocker:ps(Server),
    OldIds = maps:keys(Ids),
    NewIds = [Id || #{<<"Id">>:=Id} <- List],
    State2 = remove_old(OldIds--NewIds, State),
    start_new(NewIds--OldIds, State2).


%% @private
remove_old([], State) ->
    State;
remove_old([Id|Rest], State) ->
    ?LLOG(notice, "detected unexpected removal of container ~s", [Id]),
    remove_old(Rest, update(die, Id, State)).


%% @private
start_new([], State) ->
    State;
start_new([Id|Rest], State) ->
    ?LLOG(notice, "detected unexpected start of container ~s", [Id]),
    start_new(Rest, update(start, Id, State)).






