%% -*- erlang-indent-level: 4;indent-tabs-mode: nil -*-
%% ex: ts=4 sw=4 et
%% -------------------------------------------------------------------
%%
%% rebar: Erlang Build Tools
%%
%% Copyright (c) 2009 Dave Smith (dizzyd@dizzyd.com)
%%
%% Permission is hereby granted, free of charge, to any person obtaining a copy
%% of this software and associated documentation files (the "Software"), to deal
%% in the Software without restriction, including without limitation the rights
%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%% copies of the Software, and to permit persons to whom the Software is
%% furnished to do so, subject to the following conditions:
%%
%% The above copyright notice and this permission notice shall be included in
%% all copies or substantial portions of the Software.
%%
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
%% THE SOFTWARE.
%% -------------------------------------------------------------------
-module(rebar_prv_install_deps).

-behaviour(provider).

-export([init/1,
         do/1,
         format_error/1]).

-include("rebar.hrl").
-include_lib("providers/include/providers.hrl").

-export([do_/1,
         handle_deps_as_profile/4,
         profile_dep_dir/2,
         find_cycles/1,
         cull_compile/2]).

-export_type([dep/0]).

-define(PROVIDER, install_deps).
-define(DEPS, [app_discovery]).

-type src_dep() :: {atom(), {atom(), string(), string()}}
             | {atom(), string(), {atom(), string(), string()}}.
-type pkg_dep() :: {atom(), binary()} | atom().

-type dep() :: src_dep() | pkg_dep().

%% ===================================================================
%% Public API
%% ===================================================================

-spec init(rebar_state:t()) -> {ok, rebar_state:t()}.
init(State) ->
	State1 = rebar_state:add_provider(State, providers:create([{name, ?PROVIDER},
															   {module, ?MODULE},
															   {bare, false},
															   {deps, ?DEPS},
															   {example, undefined},
															   {short_desc, ""},
															   {desc, ""},
															   {opts, []}])),
	{ok, State1}.

-spec do(rebar_state:t()) -> {ok, rebar_state:t()} | {error, string()}.
do(State) ->
	?INFO("Verifying dependencies...", []),
	do_(State).

do_(State) ->
	try
		Profiles = rebar_state:current_profiles(State),
		ProjectApps = rebar_state:project_apps(State),
		
		Upgrade = rebar_state:get(State, upgrade, false),
		%% 解析每个profile对应下的所有依赖项(如果依赖项不存在则根据源进行下载)
		{Apps, State1} = deps_per_profile(Profiles, Upgrade, State),
		
		%% 更新整个系统的所有依赖项
		State2 = rebar_state:update_all_deps(State1, Apps),
		CodePaths = [rebar_app_info:ebin_dir(A) || A <- Apps],
		%% 更新所有依赖项的代码查找路径
		State3 = rebar_state:update_code_paths(State2, all_deps, CodePaths),
		
		Source = ProjectApps ++ Apps,
		case find_cycles(Source) of
			{cycles, Cycles} ->
				?PRV_ERROR({cycles, Cycles});
			{error, Error} ->
				{error, Error};
			{no_cycle, Sorted} ->
				ToCompile = cull_compile(Sorted, ProjectApps),
				%% 更新将要建立的依赖项数组
				{ok, rebar_state:deps_to_build(State3, ToCompile)}
		end
	catch
		%% maybe_fetch will maybe_throw an exception to break out of some loops
		_:{error, Reason} ->
			{error, Reason}
	end.

-spec format_error(any()) -> iolist().
format_error({dep_app_not_found, AppDir, AppName}) ->
	io_lib:format("Dependency failure: Application ~s not found at the top level of directory ~s", [AppName, AppDir]);
format_error({load_registry_fail, Dep}) ->
	io_lib:format("Error loading registry to resolve version of ~s. Try fixing by running 'rebar3 update'", [Dep]);
format_error({bad_constraint, Name, Constraint}) ->
	io_lib:format("Unable to parse version for package ~s: ~s", [Name, Constraint]);
format_error({parse_dep, Dep}) ->
	io_lib:format("Failed parsing dep ~p", [Dep]);
format_error({not_rebar_package, Package, Version}) ->
	io_lib:format("Package not buildable with rebar3: ~s-~s", [Package, Version]);
format_error({missing_package, Package, Version}) ->
	io_lib:format("Package not found in registry: ~s-~s", [Package, Version]);
format_error({missing_package, Package}) ->
	io_lib:format("Package not found in registry: ~s", [Package]);
format_error({cycles, Cycles}) ->
	Prints = [["applications: ",
			   [io_lib:format("~s ", [Dep]) || Dep <- Cycle],
			   "depend on each other~n"]
			  || Cycle <- Cycles],
	["Dependency cycle(s) detected:~n", Prints];
format_error(Reason) ->
	io_lib:format("~p", [Reason]).

%% Allows other providers to install deps in a given profile
%% manually, outside of what is provided by rebar3's deps tuple.
%% 允许其他provider插件手动安装依赖项根据指定的profile
handle_deps_as_profile(Profile, State, Deps, Upgrade) ->
	Locks = [],
	Level = 0,
	%% 拿到Profile对应deps的存储路径
	DepsDir = profile_dep_dir(State, Profile),
	%% 将依赖项转化为应用数据结构rebar_app_info
	Deps1 = rebar_app_utils:parse_deps(DepsDir, Deps, State, Locks, Level),
	ProfileLevelDeps = [{Profile, Deps1, Level}],
	handle_profile_level(ProfileLevelDeps, [], sets:new(), Upgrade, Locks, State).

%% ===================================================================
%% Internal functions
%% ===================================================================

%% finds all the deps in `{deps, ...}` for each profile provided.
%% 解析每个profile对应下的所有依赖项
deps_per_profile(Profiles, Upgrade, State) ->
	Level = 0,
	Locks = rebar_state:get(State, {locks, default}, []),
	Deps = lists:foldl(fun(Profile, DepAcc) ->
							   [parsed_profile_deps(State, Profile, Level) | DepAcc]
					   end, [], Profiles),
	handle_profile_level(Deps, [], sets:new(), Upgrade, Locks, State).

parsed_profile_deps(State, Profile, Level) ->
	ParsedDeps = rebar_state:get(State, {parsed_deps, Profile}, []),
	{Profile, ParsedDeps, Level}.

%% Level-order traversal of all dependencies, across profiles.
%% If profiles x,y,z are present, then the traversal will go:
%% x0, y0, z0, x1, y1, z1, ..., xN, yN, zN.
handle_profile_level([], Apps, _Seen, _Upgrade, _Locks, State) ->
	{Apps, State};
handle_profile_level([{Profile, Deps, Level} | Rest], Apps, Seen, Upgrade, Locks, State) ->
	{Deps1, Apps1, State1, Seen1} =
		update_deps(Profile, Level, Deps, Apps
					,State, Upgrade, Seen, Locks),
	Deps2 = case Deps1 of
				[] -> Rest;
				_ -> Rest ++ [{Profile, Deps1, Level + 1}]
			end,
	handle_profile_level(Deps2, Apps1, sets:union(Seen, Seen1), Upgrade, Locks, State1).

find_cycles(Apps) ->
	case rebar_digraph:compile_order(Apps) of
		{error, {cycles, Cycles}} -> {cycles, Cycles};
		{error, Error} -> {error, Error};
		{ok, Sorted} -> {no_cycle, Sorted}
	end.

cull_compile(TopSortedDeps, ProjectApps) ->
	lists:dropwhile(fun not_needs_compile/1, TopSortedDeps -- ProjectApps).

maybe_lock(Profile, AppInfo, Seen, State, Level) ->
	Name = rebar_app_info:name(AppInfo),
	case rebar_app_info:is_checkout(AppInfo) of
		false ->
			case Profile of
				default ->
					case sets:is_element(Name, Seen) of
						false ->
							Locks = rebar_state:lock(State),
							case lists:any(fun(App) -> rebar_app_info:name(App) =:= Name end, Locks) of
								true ->
									{sets:add_element(Name, Seen), State};
								false ->
									{sets:add_element(Name, Seen),
									 rebar_state:lock(State, rebar_app_info:dep_level(AppInfo, Level))}
							end;
						true ->
							{Seen, State}
					end;
				_ ->
					{sets:add_element(Name, Seen), State}
			end;
		true ->
			{sets:add_element(Name, Seen), State}
	end.

update_deps(Profile, Level, Deps, Apps, State, Upgrade, Seen, Locks) ->
	lists:foldl(
	  fun(AppInfo, {DepsAcc, AppsAcc, StateAcc, SeenAcc}) ->
			  update_dep(AppInfo, Profile, Level,
						 DepsAcc, AppsAcc, StateAcc,
						 Upgrade, SeenAcc, Locks)
	  end,
	  {[], Apps, State, Seen},
	  rebar_utils:sort_deps(Deps)).

%% 更新依赖项
update_dep(AppInfo, Profile, Level, Deps, Apps, State, Upgrade, Seen, Locks) ->
	%% If not seen, add to list of locks to write out
	Name = rebar_app_info:name(AppInfo),
	case sets:is_element(Name, Seen) of
		true ->
			%% 更新已经找到的依赖项
			update_seen_dep(AppInfo, Profile, Level,
							Deps, Apps,
							State, Upgrade, Seen, Locks);
		false ->
			%% 更新没有找到的依赖项
			update_unseen_dep(AppInfo, Profile, Level,
							  Deps, Apps,
							  State, Upgrade, Seen, Locks)
	end.

%% 拿到Profile对应deps的存储路径
profile_dep_dir(State, Profile) ->
	case Profile of
		default -> filename:join([rebar_dir:profile_dir(rebar_state:opts(State), [default]), rebar_state:get(State, deps_dir, ?DEFAULT_DEPS_DIR)]);
		%% 获得对应依赖项存储目录，默认是lib目录
		_ -> rebar_dir:deps_dir(State)
	end.

%% 更新已经找到的依赖项
update_seen_dep(AppInfo, _Profile, _Level, Deps, Apps, State, Upgrade, Seen, Locks) ->
	Name = rebar_app_info:name(AppInfo),
	%% If seen from lock file or user requested an upgrade
	%% don't print warning about skipping
	case lists:keymember(Name, 1, Locks) of
		false when Upgrade -> ok;
		false when not Upgrade -> warn_skip_deps(AppInfo, State);
		true -> ok
	end,
	{Deps, Apps, State, Seen}.

%% 更新没有找到的依赖项
update_unseen_dep(AppInfo, Profile, Level, Deps, Apps, State, Upgrade, Seen, Locks) ->
	{NewSeen, State1} = maybe_lock(Profile, AppInfo, Seen, State, Level),
	%% 如果在应用的存储路径没有寻找到对应的应用，则会根据应用的源去下载该应用
	{_, AppInfo1} = maybe_fetch(AppInfo, Profile, Upgrade, Seen, State1),
	DepsDir = profile_dep_dir(State, Profile),
	%% 根据应用的rebar.config文件信息设置rebar_app_info数据结构，如果该应用还需要插件则立刻去安装插件
	{AppInfo2, NewDeps, State2} =
		handle_dep(State1, Profile, DepsDir, AppInfo1, Locks, Level),
	AppInfo3 = rebar_app_info:dep_level(AppInfo2, Level),
	{NewDeps ++ Deps, [AppInfo3 | Apps], State2, NewSeen}.

-spec handle_dep(rebar_state:t(), atom(), file:filename_all(), rebar_app_info:t(), list(), integer()) -> {rebar_app_info:t(), [rebar_app_info:t()], rebar_state:t()}.
%% 根据应用的rebar.config文件信息设置rebar_app_info数据结构，如果该应用还需要插件则立刻去安装插件
handle_dep(State, Profile, DepsDir, AppInfo, Locks, Level) ->
	Name = rebar_app_info:name(AppInfo),
	%% 获得当前应用的rebar.config文件信息
	C = rebar_config:consult(rebar_app_info:dir(AppInfo)),
	
	%% 更新应用对应于rebar.config文件的配置信息
	AppInfo0 = rebar_app_info:update_opts(AppInfo, rebar_app_info:opts(AppInfo), C),
	AppInfo1 = rebar_app_info:apply_overrides(rebar_app_info:get(AppInfo, overrides, []), AppInfo0),
	AppInfo2 = rebar_app_info:apply_profiles(AppInfo1, [default, prod]),
	
	%% 更新应用的对应于profile的插件信息
	Plugins = rebar_app_info:get(AppInfo2, plugins, []),
	AppInfo3 = rebar_app_info:set(AppInfo2, {plugins, Profile}, Plugins),
	
	%% Will throw an exception if checks fail
	%% 检查应用的版本号和应用的rebar.config中的配置信息是否满足
	rebar_app_info:verify_otp_vsn(AppInfo3),
	
	%% Dep may have plugins to install. Find and install here.
	%% 继续安装当前应用依赖的插件
	State1 = rebar_plugins:install(State, AppInfo3),
	
	%% Upgrade lock level to be the level the dep will have in this dep tree
	Deps = rebar_app_info:get(AppInfo3, {deps, default}, []) ++ rebar_app_info:get(AppInfo3, {deps, prod}, []),
	AppInfo4 = rebar_app_info:deps(AppInfo3, rebar_state:deps_names(Deps)),
	
	%% Keep all overrides from the global config and this dep when parsing its deps
	Overrides = rebar_app_info:get(AppInfo0, overrides, []),
	Deps1 = rebar_app_utils:parse_deps(Name, DepsDir, Deps, rebar_state:set(State, overrides, Overrides)
									   ,Locks, Level + 1),
	{AppInfo4, Deps1, State1}.

-spec maybe_fetch(rebar_app_info:t(), atom(), boolean(),
                  sets:set(binary()), rebar_state:t()) -> {boolean(), rebar_app_info:t()}.
%% 如果在应用的存储路径没有寻找到对应的应用，则会根据应用的源去下载该应用
maybe_fetch(AppInfo, Profile, Upgrade, Seen, State) ->
	AppDir = ec_cnv:to_list(rebar_app_info:dir(AppInfo)),
	%% Don't fetch dep if it exists in the _checkouts dir
	case rebar_app_info:is_checkout(AppInfo) of
		true ->
			{false, AppInfo};
		false ->
			case rebar_app_discover:find_app(AppInfo, AppDir, all) of
				false ->
					%% 根据应用信息去下载该应用包
					true = fetch_app(AppInfo, AppDir, State),
					maybe_symlink_default(State, Profile, AppDir, AppInfo),
					{true, rebar_app_info:valid(update_app_info(AppDir, AppInfo), false)};
				{true, AppInfo1} ->
					case sets:is_element(rebar_app_info:name(AppInfo1), Seen) of
						true ->
							{false, AppInfo1};
						false ->
							maybe_symlink_default(State, Profile, AppDir, AppInfo1),
							MaybeUpgrade = maybe_upgrade(AppInfo, AppDir, Upgrade, State),
							AppInfo2 = update_app_info(AppDir, AppInfo1),
							{MaybeUpgrade, AppInfo2}
					end
			end
	end.

needs_symlinking(State, Profile) ->
	case {rebar_state:current_profiles(State), Profile} of
		{[default], default} ->
			%% file will be in default already -- this is the only run we have
			false;
		{_, default} ->
			%% file fetched to default, needs to be linked to the current
			%% run's directory.
			true;
		_ ->
			%% File fetched to the right directory already
			false
	end.

maybe_symlink_default(State, Profile, AppDir, AppInfo) ->
	case needs_symlinking(State, Profile) of
		true ->
			SymDir = filename:join([rebar_dir:deps_dir(State),
									rebar_app_info:name(AppInfo)]),
			symlink_dep(State, AppDir, SymDir),
			true;
		false ->
			false
	end.

%% 对依赖项进行符号连接，避免拷贝带来的时间损耗
symlink_dep(State, From, To) ->
	filelib:ensure_dir(To),
	case rebar_file_utils:symlink_or_copy(From, To) of
		ok ->
			RelativeFrom = make_relative_to_root(State, From),
			RelativeTo = make_relative_to_root(State, To),
			?INFO("Linking ~s to ~s", [RelativeFrom, RelativeTo]),
			ok;
		exists ->
			ok
	end.

make_relative_to_root(State, Path) when is_binary(Path) ->
	make_relative_to_root(State, binary_to_list(Path));
make_relative_to_root(State, Path) when is_list(Path) ->
	Root = rebar_dir:root_dir(State),
	rebar_dir:make_relative_path(Path, Root).

%% 根据应用信息去下载该应用包
fetch_app(AppInfo, AppDir, State) ->
	?INFO("Fetching ~s (~p)", [rebar_app_info:name(AppInfo),
							   format_source(rebar_app_info:source(AppInfo))]),
	Source = rebar_app_info:source(AppInfo),
	true = rebar_fetch:download_source(AppDir, Source, State).

format_source({pkg, Name, Vsn, _Hash}) -> {pkg, Name, Vsn};
format_source(Source) -> Source.

%% This is called after the dep has been downloaded and unpacked, if it hadn't been already.
%% So this is the first time for newly downloaded apps that its .app/.app.src data can
%% be read in an parsed.
update_app_info(AppDir, AppInfo) ->
	case rebar_app_discover:find_app(AppInfo, AppDir, all) of
		{true, AppInfo1} ->
			AppInfo1;
		false ->
			throw(?PRV_ERROR({dep_app_not_found, AppDir, rebar_app_info:name(AppInfo)}))
	end.

maybe_upgrade(AppInfo, AppDir, Upgrade, State) ->
	Source = rebar_app_info:source(AppInfo),
	case Upgrade orelse rebar_app_info:is_lock(AppInfo) of
		true ->
			case rebar_fetch:needs_update(AppDir, Source, State) of
				true ->
					?INFO("Upgrading ~s (~p)", [rebar_app_info:name(AppInfo), rebar_app_info:source(AppInfo)]),
					true = rebar_fetch:download_source(AppDir, Source, State);
				false ->
					case Upgrade of
						true ->
							?INFO("No upgrade needed for ~s", [rebar_app_info:name(AppInfo)]),
							false;
						false ->
							false
					end
			end;
		false ->
			false
	end.

warn_skip_deps(AppInfo, State) ->
	Msg = "Skipping ~s (from ~p) as an app of the same name "
			  "has already been fetched",
	Args = [rebar_app_info:name(AppInfo),
			rebar_app_info:source(AppInfo)],
	case rebar_state:get(State, deps_error_on_conflict, false) of
		false -> ?WARN(Msg, Args);
		true -> ?ERROR(Msg, Args), ?FAIL
	end.

not_needs_compile(App) ->
	not(rebar_app_info:is_checkout(App))
		andalso rebar_app_info:valid(App)
		andalso rebar_app_info:has_all_artifacts(App) =:= true.