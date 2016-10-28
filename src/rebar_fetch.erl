%% -*- erlang-indent-level: 4;indent-tabs-mode: nil -*-
%% ex: ts=4 sw=4 et
%% -------------------------------------------------------------------
%%
%% rebar: Erlang Build Tools
%%
%% -------------------------------------------------------------------
-module(rebar_fetch).

-export([lock_source/3,
         download_source/3,
         needs_update/3]).

-export([format_error/1]).

-include("rebar.hrl").
-include_lib("providers/include/providers.hrl").

-spec lock_source(file:filename_all(), rebar_resource:resource(), rebar_state:t()) ->
                         rebar_resource:resource() | {error, string()}.
lock_source(AppDir, Source, State) ->
	Resources = rebar_state:resources(State),
	Module = get_resource_type(Source, Resources),
	Module:lock(AppDir, Source).

-spec download_source(file:filename_all(), rebar_resource:resource(), rebar_state:t()) ->
                             true | {error, any()}.
%% 根据Source下载对应的应用包
download_source(AppDir, Source, State) ->
	try download_source_(AppDir, Source, State) of
		true ->
			true;
		Error ->
			throw(?PRV_ERROR(Error))
	catch
		C:T ->
			?DEBUG("rebar_fetch exception ~p ~p ~p", [C, T, erlang:get_stacktrace()]),
			throw(?PRV_ERROR({fetch_fail, Source}))
	end.

%% 根据应用包源类型得到对应的处理模块，然后去下载对应的应用包
download_source_(AppDir, Source, State) ->
	Resources = rebar_state:resources(State),
	%% 根据类型查找对应的资源下载处理模块
	Module = get_resource_type(Source, Resources),
	TmpDir = ec_file:insecure_mkdtemp(),
	AppDir1 = ec_cnv:to_list(AppDir),
	case Module:download(TmpDir, Source, State) of
		{ok, _} ->
			%% 确保存储该应用的路径的存在
			ec_file:mkdir_p(AppDir1),
			%% 先将该应用的ebin路径从erlang的代码搜索路径中移除
			code:del_path(filename:absname(filename:join(AppDir1, "ebin"))),
			%% 将存储该应用的路径下的所有文件递归的全部删除掉
			ec_file:remove(filename:absname(AppDir1), [recursive]),
			?DEBUG("Moving checkout ~p to ~p", [TmpDir, filename:absname(AppDir1)]),
			%% 将下载好的应用从下载存储路径移动到本应用要存储的路径下
			ok = rebar_file_utils:mv(TmpDir, filename:absname(AppDir1)),
			true;
		Error ->
			Error
	end.

-spec needs_update(file:filename_all(), rebar_resource:resource(), rebar_state:t()) -> boolean() | {error, string()}.
needs_update(AppDir, Source, State) ->
	Resources = rebar_state:resources(State),
	Module = get_resource_type(Source, Resources),
	try
		Module:needs_update(AppDir, Source)
	catch
		_:_ ->
			true
	end.

format_error({bad_download, CachePath}) ->
    io_lib:format("Download of package does not match md5sum from server: ~s", [CachePath]);
format_error({unexpected_hash, CachePath, Expected, Found}) ->
    io_lib:format("The checksum for package at ~s (~s) does not match the "
                  "checksum previously locked (~s). Either unlock or "
                  "upgrade the package, or make sure you fetched it from "
                  "the same index from which it was initially fetched.",
                  [CachePath, Found, Expected]);
format_error({failed_extract, CachePath}) ->
    io_lib:format("Failed to extract package: ~s", [CachePath]);
format_error({bad_etag, Source}) ->
    io_lib:format("MD5 Checksum comparison failed for: ~s", [Source]);
format_error({fetch_fail, Name, Vsn}) ->
    io_lib:format("Failed to fetch and copy dep: ~s-~s", [Name, Vsn]);
format_error({fetch_fail, Source}) ->
    io_lib:format("Failed to fetch and copy dep: ~p", [Source]);
format_error({bad_checksum, File}) ->
    io_lib:format("Checksum mismatch against tarball in ~s", [File]);
format_error({bad_registry_checksum, File}) ->
    io_lib:format("Checksum mismatch against registry in ~s", [File]).

get_resource_type({Type, Location}, Resources) ->
	find_resource_module(Type, Location, Resources);
get_resource_type({Type, Location, _}, Resources) ->
	find_resource_module(Type, Location, Resources);
get_resource_type({Type, _, _, Location}, Resources) ->
	find_resource_module(Type, Location, Resources);
get_resource_type(_, _) ->
	rebar_pkg_resource.

%% 根据类型查找对应的资源下载处理模块
find_resource_module(Type, Location, Resources) ->
    case lists:keyfind(Type, 1, Resources) of
        false ->
            case code:which(Type) of
                non_existing ->
                    {error, io_lib:format("Cannot handle dependency ~s.~n"
                                         "     No module for resource type ~p", [Location, Type])};
                _ ->
                    Type
            end;
        {Type, Module} ->
            Module
    end.
