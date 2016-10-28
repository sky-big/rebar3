%% -*- erlang-indent-level: 4;indent-tabs-mode: nil -*-
%% ex: ts=4 sw=4 et
%% -------------------------------------------------------------------
%%
%% rebar: Erlang Build Tools
%%
%% Copyright (c) 2009, 2010 Dave Smith (dizzyd@dizzyd.com)
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
-module(rebar_erlc_compiler).

-export([compile/1, compile/2, compile/3,
         compile_dir/3, compile_dir/4,
         compile_dirs/5,
         clean/1]).

-include("rebar.hrl").
-include_lib("stdlib/include/erl_compile.hrl").

-define(ERLCINFO_VSN, 2).
-define(ERLCINFO_FILE, "erlcinfo").
-type erlc_info_v() :: {digraph:vertex(), term()} | 'false'.
-type erlc_info_e() :: {digraph:vertex(), digraph:vertex()}.
-type erlc_info() :: {list(erlc_info_v()), list(erlc_info_e()), list(string())}.
-record(erlcinfo, {
    vsn = ?ERLCINFO_VSN :: pos_integer(),
    info = {[], [], []} :: erlc_info()
}).

-type compile_opts() :: [compile_opt()].
-type compile_opt() :: {recursive, boolean()}.

-record(compile_opts, {
    recursive = true
}).

-define(DEFAULT_OUTDIR, "ebin").
-define(RE_PREFIX, "^[^._]").

%% ===================================================================
%% Public API
%% ===================================================================

%% Supported configuration variables:
%%
%% * erl_opts - Erlang list of options passed to compile:file/2
%%              It is also possible to specify platform specific
%%              options by specifying a pair or a triplet where the
%%              first string is a regex that is checked against the
%%              string
%%
%%                OtpRelease ++ "-" ++ SysArch ++ "-" ++ Words.
%%
%%              where
%%
%%                OtpRelease = erlang:system_info(otp_release).
%%                SysArch = erlang:system_info(system_architecture).
%%                Words = integer_to_list(8 *
%%                            erlang:system_info({wordsize, external})).
%%
%%              E.g. to define HAVE_SENDFILE only on systems with
%%              sendfile(), to define BACKLOG on Linux/FreeBSD as 128,
%%              and to define 'old_inets' for R13 OTP release do:
%%
%%              {erl_opts, [{platform_define,
%%                           "(linux|solaris|freebsd|darwin)",
%%                           'HAVE_SENDFILE'},
%%                          {platform_define, "(linux|freebsd)",
%%                           'BACKLOG', 128},
%%                          {platform_define, "R13",
%%                           'old_inets'}]}.
%%

%% @equiv compile(AppInfo, []).

-spec compile(rebar_app_info:t()) -> ok.
%% 编译单个应用的入口
compile(AppInfo) when element(1, AppInfo) == app_info_t ->
    compile(AppInfo, []).

%% @doc compile an individual application.

-spec compile(rebar_app_info:t(), compile_opts()) -> ok.
%% 编译单个应用的入口
compile(AppInfo, CompileOpts) when element(1, AppInfo) == app_info_t ->
    Dir = ec_cnv:to_list(rebar_app_info:out_dir(AppInfo)),
    RebarOpts = rebar_app_info:opts(AppInfo),

    rebar_base_compiler:run(RebarOpts,
                            check_files([filename:join(Dir, File)
                                         || File <- rebar_opts:get(RebarOpts, xrl_first_files, [])]),
                            filename:join(Dir, "src"), ".xrl", filename:join(Dir, "src"), ".erl",
                            fun compile_xrl/3),
    rebar_base_compiler:run(RebarOpts,
                            check_files([filename:join(Dir, File)
                                         || File <- rebar_opts:get(RebarOpts, yrl_first_files, [])]),
                            filename:join(Dir, "src"), ".yrl", filename:join(Dir, "src"), ".erl",
                            fun compile_yrl/3),
    rebar_base_compiler:run(RebarOpts,
                            check_files([filename:join(Dir, File)
                                         || File <- rebar_opts:get(RebarOpts, mib_first_files, [])]),
                            filename:join(Dir, "mibs"), ".mib", filename:join([Dir, "priv", "mibs"]), ".bin",
                            compile_mib(AppInfo)),

    SrcDirs = lists:map(fun(SrcDir) -> filename:join(Dir, SrcDir) end,
                        rebar_dir:src_dirs(RebarOpts, ["src"])),
    OutDir = filename:join(Dir, outdir(RebarOpts)),
	%% 编译根据配置找到的源代码路径目录
    compile_dirs(RebarOpts, Dir, SrcDirs, OutDir, CompileOpts),

	%% 寻找需要额外编译的文件目录
    ExtraDirs = rebar_dir:extra_src_dirs(RebarOpts),
    F = fun(D) ->
        case ec_file:is_dir(filename:join([Dir, D])) of
            true  -> compile_dirs(RebarOpts, Dir, [D], D, CompileOpts);
            false -> ok
        end
    end,
    lists:foreach(F, lists:map(fun(SrcDir) -> filename:join(Dir, SrcDir) end, ExtraDirs)).

%% @hidden
%% these are kept for backwards compatibility but they're bad functions with
%% bad interfaces you probably shouldn't use
%% State/RebarOpts have to have src_dirs set and BaseDir must be the parent
%% directory of those src_dirs

-spec compile(rebar_dict() | rebar_state:t(), file:name(), file:name()) -> ok.
compile(State, BaseDir, OutDir) when element(1, State) == state_t ->
    compile(rebar_state:opts(State), BaseDir, OutDir, [{recursive, false}]);
compile(RebarOpts, BaseDir, OutDir) ->
    compile(RebarOpts, BaseDir, OutDir, [{recursive, false}]).

%% @hidden

-spec compile(rebar_dict() | rebar_state:t(), file:name(), file:name(), compile_opts()) -> ok.
compile(State, BaseDir, OutDir, CompileOpts) when element(1, State) == state_t ->
    compile(rebar_state:opts(State), BaseDir, OutDir, CompileOpts);
compile(RebarOpts, BaseDir, OutDir, CompileOpts) ->
    SrcDirs = lists:map(fun(SrcDir) -> filename:join(BaseDir, SrcDir) end,
                        rebar_dir:src_dirs(RebarOpts, ["src"])),
    compile_dirs(RebarOpts, BaseDir, SrcDirs, OutDir, CompileOpts),

    ExtraDirs = rebar_dir:extra_src_dirs(RebarOpts),
    F = fun(D) ->
        case ec_file:is_dir(filename:join([BaseDir, D])) of
            true  -> compile_dirs(RebarOpts, BaseDir, [D], D, CompileOpts);
            false -> ok
        end
    end,
    lists:foreach(F, lists:map(fun(SrcDir) -> filename:join(BaseDir, SrcDir) end, ExtraDirs)).

%% @equiv compile_dirs(Context, BaseDir, [Dir], Dir, [{recursive, false}]).

-spec compile_dir(rebar_dict() | rebar_state:t(), file:name(), file:name()) -> ok.
compile_dir(State, BaseDir, Dir) when element(1, State) == state_t ->
    compile_dir(rebar_state:opts(State), BaseDir, Dir, [{recursive, false}]);
compile_dir(RebarOpts, BaseDir, Dir) ->
    compile_dir(RebarOpts, BaseDir, Dir, [{recursive, false}]).

%% @equiv compile_dirs(Context, BaseDir, [Dir], Dir, Opts).

-spec compile_dir(rebar_dict() | rebar_state:t(), file:name(), file:name(), compile_opts()) -> ok.
compile_dir(State, BaseDir, Dir, Opts) when element(1, State) == state_t ->
    compile_dirs(rebar_state:opts(State), BaseDir, [Dir], Dir, Opts);
compile_dir(RebarOpts, BaseDir, Dir, Opts) ->
    compile_dirs(RebarOpts, BaseDir, [Dir], Dir, Opts).

%% @doc compile a list of directories with the given opts.

-spec compile_dirs(rebar_dict() | rebar_state:t(),
                   file:filename(),
                   [file:filename()],
                   file:filename(),
                   compile_opts()) -> ok.
%% 编译给定的源代码路径目录
compile_dirs(State, BaseDir, Dirs, OutDir, CompileOpts) when element(1, State) == state_t ->
    compile_dirs(rebar_state:opts(State), BaseDir, Dirs, OutDir, CompileOpts);
compile_dirs(RebarOpts, BaseDir, SrcDirs, OutDir, Opts) ->
    CompileOpts = parse_opts(Opts),
  
    ErlOpts = rebar_opts:erl_opts(RebarOpts),
    ?DEBUG("erlopts ~p", [ErlOpts]),
    Recursive = CompileOpts#compile_opts.recursive,
	%% 递归的获得对应不同路径下的所有源代码文件
    AllErlFiles = gather_src(SrcDirs, Recursive),
    ?DEBUG("files to compile ~p", [AllErlFiles]),

    %% Make sure that outdir is on the path
    ok = filelib:ensure_dir(filename:join(OutDir, "dummy.beam")),
    true = code:add_patha(filename:absname(OutDir)),

	%% include_abs_dirs()函数从配置中得到hrl文件的存储路径加上默认include目录
	%% init_erlcinfo()函数根据应用的全部源代码文件和include文件目录得到最新的源代码模块文件最新的有向图
    G = init_erlcinfo(include_abs_dirs(ErlOpts, BaseDir), AllErlFiles, BaseDir, OutDir),

	%% 根据有向图和beam文件的对比以及其他的条件来判断得到需要重新编译的源代码模块文件列表
    NeededErlFiles = needed_files(G, ErlOpts, BaseDir, OutDir, AllErlFiles),
	%% 从需要编译的模块文件列表中找到需要先编译的模块文件列表
    {ErlFirstFiles, ErlOptsFirst} = erl_first_files(RebarOpts, ErlOpts, BaseDir, NeededErlFiles),
	%% 从需要编译的文件模块列表中得到别人依赖自己的和没有其他模块依赖自己的两个列表
    {DepErls, OtherErls} = lists:partition(
                             fun(Source) -> digraph:in_degree(G, Source) > 0 end,
                             [File || File <- NeededErlFiles, not lists:member(File, ErlFirstFiles)]),
	%% 将有模块依赖自己的模块列表重新组建有向图
    SubGraph = digraph_utils:subgraph(G, DepErls),
	%% 得到该别人依赖自己模块的拓扑排序
    DepErlsOrdered = digraph_utils:topsort(SubGraph),
	%% 将首先需要编译的模块加上别人依赖自己的模块列表组成需要首先编译的模块文件列表
    FirstErls = ErlFirstFiles ++ lists:reverse(DepErlsOrdered),
    try
        rebar_base_compiler:run(
            RebarOpts, FirstErls, OtherErls,
            fun(S, C) ->
                    ErlOpts1 = case lists:member(S, ErlFirstFiles) of
                                   true -> ErlOptsFirst;
                                   false -> ErlOpts
                               end,
                    internal_erl_compile(C, BaseDir, S, OutDir, ErlOpts1)
            end)
    after
        true = digraph:delete(SubGraph),
        true = digraph:delete(G)
    end,
    ok.

%% @doc remove compiled artifacts from an AppDir.

-spec clean(rebar_app_info:t()) -> 'ok'.
clean(AppInfo) ->
    AppDir = rebar_app_info:out_dir(AppInfo),

    MibFiles = rebar_utils:find_files(filename:join([AppDir, "mibs"]), ?RE_PREFIX".*\\.mib\$"),
    MIBs = [filename:rootname(filename:basename(MIB)) || MIB <- MibFiles],
    rebar_file_utils:delete_each(
      [filename:join([AppDir, "include",MIB++".hrl"]) || MIB <- MIBs]),
    ok = rebar_file_utils:rm_rf(filename:join([AppDir, "priv/mibs/*.bin"])),

    YrlFiles = rebar_utils:find_files(filename:join([AppDir, "src"]), ?RE_PREFIX".*\\.[x|y]rl\$"),
    rebar_file_utils:delete_each(
      [ binary_to_list(iolist_to_binary(re:replace(F, "\\.[x|y]rl$", ".erl")))
        || F <- YrlFiles ]),

    BinDirs = ["ebin"|rebar_dir:extra_src_dirs(rebar_app_info:opts(AppInfo))],
    ok = clean_dirs(AppDir, BinDirs),

    %% Delete the build graph, if any
    rebar_file_utils:rm_rf(erlcinfo_file(AppDir)).

clean_dirs(_AppDir, []) -> ok;
clean_dirs(AppDir, [Dir|Rest]) ->
    ok = rebar_file_utils:rm_rf(filename:join([AppDir, Dir, "*.beam"])),
    %% Erlang compilation is recursive, so it's possible that we have a nested
    %% directory structure in ebin with .beam files within. As such, we want
    %% to scan whatever is left in the app's out_dir directory for sub-dirs which
    %% satisfy our criteria.
    BeamFiles = rebar_utils:find_files(filename:join([AppDir, Dir]), ?RE_PREFIX".*\\.beam\$"),
    rebar_file_utils:delete_each(BeamFiles),
    lists:foreach(fun(D) -> delete_dir(D, dirs(D)) end, dirs(filename:join([AppDir, Dir]))),
    clean_dirs(AppDir, Rest).


%% ===================================================================
%% Internal functions
%% ===================================================================
%% Recursive决定是否递归获得对应规则的文件
gather_src(Dirs, Recursive) ->
    gather_src(Dirs, [], Recursive).

gather_src([], Srcs, _Recursive) -> Srcs;
gather_src([Dir|Rest], Srcs, Recursive) ->
    gather_src(Rest, Srcs ++ rebar_utils:find_files(Dir, ?RE_PREFIX".*\\.erl\$", Recursive), Recursive).
    
%% Get files which need to be compiled first, i.e. those specified in erl_first_files
%% and parse_transform options.  Also produce specific erl_opts for these first
%% files, so that yet to be compiled parse transformations are excluded from it.
erl_first_files(Opts, ErlOpts, Dir, NeededErlFiles) ->
    ErlFirstFilesConf = rebar_opts:get(Opts, erl_first_files, []),
    NeededSrcDirs = lists:usort(lists:map(fun filename:dirname/1, NeededErlFiles)),
    %% NOTE: order of files here is important!
	%% 从需要编译的模块列表中找到需要首先编译的模块文件列表
    ErlFirstFiles =
        [filename:join(Dir, File) || File <- ErlFirstFilesConf,
                                     lists:member(filename:join(Dir, File), NeededErlFiles)],
    {ParseTransforms, ParseTransformsErls} =
        lists:unzip(lists:flatmap(
                      fun(PT) ->
                              PTerls = [filename:join(D, module_to_erl(PT)) || D <- NeededSrcDirs],
                              [{PT, PTerl} || PTerl <- PTerls, lists:member(PTerl, NeededErlFiles)]
                      end, proplists:get_all_values(parse_transform, ErlOpts))),
    ErlOptsFirst = lists:filter(fun({parse_transform, PT}) ->
                                        not lists:member(PT, ParseTransforms);
                                   (_) ->
                                        true
                               end, ErlOpts),
    {ErlFirstFiles ++ ParseTransformsErls, ErlOptsFirst}.

%% Get subset of SourceFiles which need to be recompiled, respecting
%% dependencies induced by given graph G.
%% 根据有向图和beam文件的对比以及其他的条件来判断得到需要重新编译的源代码模块文件列表
needed_files(G, ErlOpts, Dir, OutDir, SourceFiles) ->
    lists:filter(fun(Source) ->
                         TargetBase = target_base(OutDir, Source),
						 %% 得到要编译成的beam文件的绝对路径名字
                         Target = TargetBase ++ ".beam",
                         AllOpts = [{outdir, filename:dirname(Target)}
                                   ,{i, filename:join(Dir, "include")}
                                   ,{i, Dir}] ++ ErlOpts,
						 %% 根据有向图中该源代码模块文件的修改时间大于对应beam文件的修改时间则该文件需要重新编译
                         digraph:vertex(G, Source) > {Source, filelib:last_modified(Target)}
				 			%% 根据beam文件的编译参数和当前要编译的参数进行对比判断是否发生变化
                              orelse opts_changed(AllOpts, TargetBase)
				 			%% 如果系统变量ERL_COMPILER_OPTIONS设置了true则表示所有的模块重新编译
                              orelse erl_compiler_opts_set()
                 end, SourceFiles).

%% 有源代码模块文件被删除，则将该模块从beam文件删除，同时将有向图中的节点删除掉
maybe_rm_beam_and_edge(G, OutDir, Source) ->
    %% This is NOT a double check it is the only check that the source file is actually gone
    case filelib:is_regular(Source) of
        true ->
            %% Actually exists, don't delete
            false;
        false ->
            Target = target_base(OutDir, Source) ++ ".beam",
            ?DEBUG("Source ~s is gone, deleting previous beam file if it exists ~s", [Source, Target]),
            file:delete(Target),
            digraph:del_vertex(G, Source),
            true
    end.

%% 根据beam文件的编译参数和当前要编译的参数进行对比判断是否发生变化
opts_changed(NewOpts, Target) ->
    case compile_info(Target) of
        {ok, Opts} -> lists:sort(Opts) =/= lists:sort(NewOpts);
        _          -> true
    end.

compile_info(Target) ->
    case beam_lib:chunks(Target, [compile_info]) of
        {ok, {_mod, Chunks}} ->
            CompileInfo = proplists:get_value(compile_info, Chunks, []),
            {ok, proplists:get_value(options, CompileInfo, [])};
        {error, beam_lib, Reason} ->
            ?WARN("Couldn't read debug info from ~p for reason: ~p", [Target, Reason]),
            {error, Reason}
    end.

%% 如果系统变量ERL_COMPILER_OPTIONS设置了true则表示所有的模块重新编译
erl_compiler_opts_set() ->
    case os:getenv("ERL_COMPILER_OPTIONS") of
        false -> false;
        _     -> true
    end.

erlcinfo_file(Dir) ->
    filename:join(rebar_dir:local_cache_dir(Dir), ?ERLCINFO_FILE).

%% Get dependency graph of given Erls files and their dependencies (header files,
%% parse transforms, behaviours etc.) located in their directories or given
%% InclDirs. Note that last modification times stored in vertices already respect
%% dependencies induced by given graph G.
%% 根据应用的全部源代码文件和include文件目录得到最新的源代码模块文件最新的有向图
init_erlcinfo(InclDirs, Erls, Dir, OutDir) ->
    G = digraph:new([acyclic]),
	%% 从erlcinfo文件中将缓冲的编译数据读取出来
    try restore_erlcinfo(G, InclDirs, Dir)
    catch
        _:_ ->
            ?WARN("Failed to restore ~s file. Discarding it.~n", [erlcinfo_file(Dir)]),
            file:delete(erlcinfo_file(Dir))
    end,
	%% 得到erl文件的目录以及include目录列表
    Dirs = source_and_include_dirs(InclDirs, Erls),
    %% A source file may have been renamed or deleted. Remove it from the graph
    %% and remove any beam file for that source if it exists.
	%% 如果有源代码模块被删除，则将该beam文件删除，同时将有向图中该节点的信息删除掉
    Modified = maybe_rm_beams_and_edges(G, OutDir, Erls),
	%% 检查每个模块文件是否需要编译，即得到有向图是否发生了变化
    Modified1 = lists:foldl(update_erlcinfo_fun(G, Dirs), Modified, Erls),
    if
		%% 如果发现有向图有变化则立刻重新存储erlcinfo文件最新的数据
		Modified1 ->
		   store_erlcinfo(G, InclDirs, Dir);
		not Modified1 ->
			ok
	end,
    G.

%% 如果有源代码模块被删除，则将该beam文件删除，同时将有向图中该节点的信息删除掉
maybe_rm_beams_and_edges(G, Dir, Files) ->
    Vertices = digraph:vertices(G),
    case lists:filter(fun(File) ->
                              case filename:extension(File) =:= ".erl" of
                                  true ->
									  %% 有源代码模块文件被删除，则将该模块从beam文件删除，同时将有向图中的节点删除掉
                                      maybe_rm_beam_and_edge(G, Dir, File);
                                  false ->
                                      false
                              end
					  %% 有向图中的节点减去要编译的文件数得到已经删除的源代码文件
                      end, lists:sort(Vertices) -- lists:sort(Files)) of
        [] ->
            false;
        _ ->
            true
    end.

%% 得到erl文件的目录以及include目录列表
source_and_include_dirs(InclDirs, Erls) ->
    SourceDirs = lists:map(fun filename:dirname/1, Erls),
    lists:usort(InclDirs ++ SourceDirs).

%% 判断单个模块文件是否需要重新编译,同时将信息更新到有向图中
update_erlcinfo(G, Dirs, Source) ->
    case digraph:vertex(G, Source) of
		%% 源代码模块文件存在的情况
        {_, LastUpdated} ->
            case filelib:last_modified(Source) of
				%% 源代码文件不存在的情况，则将该文件模块从有向图中删除掉
                0 ->
                    %% The file doesn't exist anymore,
                    %% erase it from the graph.
                    %% All the edges will be erased automatically.
                    digraph:del_vertex(G, Source),
                    modified;
				%% 模块文件的修改时间大于beam文件的更新时间的情况
                LastModified when LastUpdated < LastModified ->
					%% 修改摸个模块文件在有向图中最新修改时间以及最新的依赖项
                    modify_erlcinfo(G, Source, LastModified, filename:dirname(Source), Dirs);
				%% 此种情况是模块文件的修改时间大于等于beam文件的更新时间，则需要去看模块文件的依赖include文件是否有变化来觉得该模块文件是否需要进行编译
                _ ->
					%% 此处查看该模块文件的依赖项是否发生变化,如果发生了变化，则需要将该文件重新进行编译
                    Modified = lists:foldl(
                        update_erlcinfo_fun(G, Dirs),
                        false, digraph:out_neighbours(G, Source)),
					%% 得到源代码模块文件包括依赖项最后的更新时间，同时将找到的最大时间更新为当前模块文件的更新时间，然后返回该最大修改时间
                    MaxModified = update_max_modified_deps(G, Source),
					%% 如果依赖项中有变化或者依赖项包括自己的最大修改时间超过了该模块文件的修改时间，则表示该有向图已经修改过
                    case Modified orelse MaxModified > LastUpdated of
                        true -> modified;
                        false -> unmodified
                    end
            end;
		%% 此种情况是该源代码文件是新增加的模块
        false ->
			%% 修改摸个模块文件在有向图中最新修改时间以及最新的依赖项
            modify_erlcinfo(G, Source, filelib:last_modified(Source), filename:dirname(Source), Dirs)
    end.

%% 更新erlcinfo信息的函数
update_erlcinfo_fun(G, Dirs) ->
    fun(Erl, Modified) ->
        case update_erlcinfo(G, Dirs, Erl) of
            modified -> true;
            unmodified -> Modified
        end
    end.

%% 得到源代码模块文件包括依赖项最后的更新时间，同时将找到的最大时间更新为当前模块文件的更新时间，然后返回该最大修改时间
update_max_modified_deps(G, Source) ->
    MaxModified = lists:max(lists:map(
        fun(File) -> {_, MaxModified} = digraph:vertex(G, File), MaxModified end,
        [Source|digraph:out_neighbours(G, Source)])),
    digraph:add_vertex(G, Source, MaxModified),
    MaxModified.

%% 修改摸个模块文件在有向图中最新修改时间以及最新的依赖项
modify_erlcinfo(G, Source, LastModified, Dir, Dirs) ->
	%% 打开源代码模块文件
    {ok, Fd} = file:open(Source, [read]),
	%% 解析该源代码模块文件属性得到依赖的文件列表
    Incls = parse_attrs(Fd, [], Dir),
	%% 判断依赖的文件是否是合法的
    AbsIncls = expand_file_names(Incls, Dirs),
	%% 将模块文件的句柄关闭掉
    ok = file:close(Fd),
	%% 将该源代码模块文件添加到有向图中
    digraph:add_vertex(G, Source, LastModified),
	%% 将该源代码模块文件的边删除掉
    digraph:del_edges(G, digraph:out_edges(G, Source)),
	%% 根据解析源代码模块文件得到的最新依赖文件列表添加该模块文件对应的边
    lists:foreach(
      fun(Incl) ->
			  %% 检查Incl文件是否需要发生改变
              update_erlcinfo(G, Dirs, Incl),
			  %% 增加图的有向边
              digraph:add_edge(G, Source, Incl)
      end, AbsIncls),
    modified.

%% 从erlcinfo文件中将缓冲的编译数据读取出来
restore_erlcinfo(G, InclDirs, Dir) ->
    case file:read_file(erlcinfo_file(Dir)) of
        {ok, Data} ->
            % Since externally passed InclDirs can influence erlcinfo graph (see
            % modify_erlcinfo), we have to check here that they didn't change.
            #erlcinfo{vsn=?ERLCINFO_VSN, info={Vs, Es, InclDirs}} =
                binary_to_term(Data),
            lists:foreach(
              fun({V, LastUpdated}) ->
                      digraph:add_vertex(G, V, LastUpdated)
              end, Vs),
            lists:foreach(
              fun({_, V1, V2, _}) ->
                      digraph:add_edge(G, V1, V2)
              end, Es);
        {error, _} ->
            ok
    end.

%% 存储erlcinfo文件数据
store_erlcinfo(G, InclDirs, Dir) ->
    Vs = lists:map(fun(V) -> digraph:vertex(G, V) end, digraph:vertices(G)),
    Es = lists:map(fun(E) -> digraph:edge(G, E) end, digraph:edges(G)),
    File = erlcinfo_file(Dir),
    ok = filelib:ensure_dir(File),
    Data = term_to_binary(#erlcinfo{info={Vs, Es, InclDirs}}, [{compressed, 2}]),
    file:write_file(File, Data).

%% NOTE: If, for example, one of the entries in Files, refers to
%% gen_server.erl, that entry will be dropped. It is dropped because
%% such an entry usually refers to the beam file, and we don't pass a
%% list of OTP src dirs for finding gen_server.erl's full path. Also,
%% if gen_server.erl was modified, it's not rebar's task to compile a
%% new version of the beam file. Therefore, it's reasonable to drop
%% such entries. Also see process_attr(behaviour, Form, Includes).
-spec expand_file_names([file:filename()],
                        [file:filename()]) -> [file:filename()].
%% 判断依赖的文件是否是合法的
expand_file_names(Files, Dirs) ->
    %% We check if Files exist by itself or within the directories
    %% listed in Dirs.
    %% Return the list of files matched.
    lists:flatmap(
      fun(Incl) ->
              case filelib:is_regular(Incl) of
                  true ->
                      [Incl];
                  false ->
                      lists:flatmap(
                        fun(Dir) ->
                                FullPath = filename:join(Dir, Incl),
                                case filelib:is_regular(FullPath) of
                                    true ->
                                        [FullPath];
                                    false ->
                                        []
                                end
                        end, Dirs)
              end
      end, Files).

-spec internal_erl_compile(rebar_dict(), file:filename(), file:filename(),
    file:filename(), list()) -> ok | {ok, any()} | {error, any(), any()}.
%% 真实对Erlang源代码模块文件进行编译的函数
internal_erl_compile(Opts, Dir, Module, OutDir, ErlOpts) ->
	%% 得到要编译成的beam文件绝对路径名
    Target = target_base(OutDir, Module) ++ ".beam",
	%% 确保目标文件的文件夹的存在
    ok = filelib:ensure_dir(Target),
    AllOpts = [{outdir, filename:dirname(Target)}] ++ ErlOpts ++
        [{i, filename:join(Dir, "include")}, {i, Dir}, return],
	%% 实际编译的动作
    case compile:file(Module, AllOpts) of
        {ok, _Mod} ->
            ok;
        {ok, _Mod, Ws} ->
            FormattedWs = format_error_sources(Ws, Opts),
            rebar_base_compiler:ok_tuple(Module, FormattedWs);
        {error, Es, Ws} ->
            error_tuple(Module, Es, Ws, AllOpts, Opts)
    end.

error_tuple(Module, Es, Ws, AllOpts, Opts) ->
    FormattedEs = format_error_sources(Es, Opts),
    FormattedWs = format_error_sources(Ws, Opts),
    rebar_base_compiler:error_tuple(Module, FormattedEs, FormattedWs, AllOpts).

format_error_sources(Es, Opts) ->
    [{rebar_base_compiler:format_error_source(Src, Opts), Desc}
     || {Src, Desc} <- Es].

target_base(OutDir, Source) ->
    filename:join(OutDir, filename:basename(Source, ".erl")).

-spec compile_mib(rebar_app_info:t()) ->
    fun((file:filename(), file:filename(), rebar_dict()) -> 'ok').
compile_mib(AppInfo) ->
    fun(Source, Target, Opts) ->
        Dir = filename:dirname(Target),
        Mib = filename:rootname(Target),
        HrlFilename = Mib ++ ".hrl",

        AppInclude = filename:join([rebar_app_info:dir(AppInfo), "include"]),

        ok = filelib:ensure_dir(Target),
        ok = filelib:ensure_dir(filename:join([AppInclude, "dummy.hrl"])),

        AllOpts = [{outdir, Dir}
                  ,{i, [Dir]}] ++
            rebar_opts:get(Opts, mib_opts, []),

        case snmpc:compile(Source, AllOpts) of
            {ok, _} ->
                MibToHrlOpts =
                    case proplists:get_value(verbosity, AllOpts, undefined) of
                        undefined ->
                            #options{specific = []};
                        Verbosity ->
                            #options{specific = [{verbosity, Verbosity}]}
                    end,
                ok = snmpc:mib_to_hrl(Mib, Mib, MibToHrlOpts),
                rebar_file_utils:mv(HrlFilename, AppInclude),
                ok;
            {error, compilation_failed} ->
                ?FAIL
        end
    end.

-spec compile_xrl(file:filename(), file:filename(),
                  rebar_dict()) -> 'ok'.
compile_xrl(Source, Target, Opts) ->
    AllOpts = [{scannerfile, Target} | rebar_opts:get(Opts, xrl_opts, [])],
    compile_xrl_yrl(Opts, Source, Target, AllOpts, leex).

-spec compile_yrl(file:filename(), file:filename(),
                  rebar_dict()) -> 'ok'.
compile_yrl(Source, Target, Opts) ->
    AllOpts = [{parserfile, Target} | rebar_opts:get(Opts, yrl_opts, [])],
    compile_xrl_yrl(Opts, Source, Target, AllOpts, yecc).

-spec compile_xrl_yrl(rebar_dict(), file:filename(),
                      file:filename(), list(), module()) -> 'ok'.
compile_xrl_yrl(_Opts, Source, Target, AllOpts, Mod) ->
    %% FIX ME: should be the outdir or something
    Dir = filename:dirname(filename:dirname(Target)),
    AllOpts1 = [{includefile, filename:join(Dir, I)} || {includefile, I} <- AllOpts,
                                                        filename:pathtype(I) =:= relative],
    case needs_compile(Source, Target) of
        true ->
            case Mod:file(Source, AllOpts1 ++ [{return, true}]) of
                {ok, _} ->
                    ok;
                {ok, _Mod, Ws} ->
                    rebar_base_compiler:ok_tuple(Source, Ws);
                {error, Es, Ws} ->
                    rebar_base_compiler:error_tuple(Source,
                                                    Es, Ws, AllOpts1)
            end;
        false ->
            skipped
    end.

needs_compile(Source, Target) ->
    filelib:last_modified(Source) > filelib:last_modified(Target).



-spec dirs(file:filename()) -> [file:filename()].
dirs(Dir) ->
    [F || F <- filelib:wildcard(filename:join([Dir, "*"])), filelib:is_dir(F)].

-spec delete_dir(file:filename(), [string()]) -> 'ok' | {'error', atom()}.
delete_dir(Dir, []) ->
    file:del_dir(Dir);
delete_dir(Dir, Subdirs) ->
    lists:foreach(fun(D) -> delete_dir(D, dirs(D)) end, Subdirs),
    file:del_dir(Dir).

%% 解析源代码模块文件，找到该模块文件所有的文件列表
parse_attrs(Fd, Includes, Dir) ->
    case io:parse_erl_form(Fd, "") of
        {ok, Form, _Line} ->
            case erl_syntax:type(Form) of
                attribute ->
					%% 解析该源代码模块文件属性得到依赖的文件列表
                    NewIncludes = process_attr(Form, Includes, Dir),
                    parse_attrs(Fd, NewIncludes, Dir);
                _ ->
                    parse_attrs(Fd, Includes, Dir)
            end;
        {eof, _} ->
            Includes;
        _Err ->
            parse_attrs(Fd, Includes, Dir)
    end.

%% 分析单条Erlang模块源代码属性
process_attr(Form, Includes, Dir) ->
    AttrName = erl_syntax:atom_value(erl_syntax:attribute_name(Form)),
    process_attr(AttrName, Form, Includes, Dir).

%% 属性为import类型，得到本模块有导入的其他模块方法的模块
process_attr(import, Form, Includes, _Dir) ->
    case erl_syntax_lib:analyze_import_attribute(Form) of
        {Mod, _Funs} ->
            [module_to_erl(Mod) | Includes];
        Mod ->
            [module_to_erl(Mod) | Includes]
    end;
%% 属性为file类型，直接将该文件加入到本模块的依赖项里
process_attr(file, Form, Includes, _Dir) ->
    {File, _} = erl_syntax_lib:analyze_file_attribute(Form),
    [File|Includes];
%% 属性为include类型，直接将该文件加入到本模块的依赖项里
process_attr(include, Form, Includes, _Dir) ->
    [FileNode] = erl_syntax:attribute_arguments(Form),
    File = erl_syntax:string_value(FileNode),
    [File|Includes];
%% 属性为include_lib类型，扩展寻找对应的hrl文件路径
process_attr(include_lib, Form, Includes, Dir) ->
    [FileNode] = erl_syntax:attribute_arguments(Form),
    RawFile = erl_syntax:string_value(FileNode),
    maybe_expand_include_lib_path(RawFile, Dir) ++ Includes;
%% 属性behaviour类型
process_attr(behaviour, Form, Includes, _Dir) ->
    [FileNode] = erl_syntax:attribute_arguments(Form),
    File = module_to_erl(erl_syntax:atom_value(FileNode)),
    [File | Includes];
%% 属性compile类型
process_attr(compile, Form, Includes, _Dir) ->
    [Arg] = erl_syntax:attribute_arguments(Form),
    case erl_syntax:concrete(Arg) of
        {parse_transform, Mod} ->
            [module_to_erl(Mod)|Includes];
        {core_transform, Mod} ->
            [module_to_erl(Mod)|Includes];
        L when is_list(L) ->
            lists:foldl(
              fun({parse_transform, Mod}, Acc) ->
                      [module_to_erl(Mod) | Acc];
                 ({core_transform, Mod}, Acc) ->
                      [module_to_erl(Mod) | Acc];
                 (_, Acc) ->
                      Acc
              end, Includes, L);
        _ ->
            Includes
    end;
%% 其他的源代码属性直接忽略掉
process_attr(_, _Form, Includes, _Dir) ->
    Includes.

module_to_erl(Mod) ->
    atom_to_list(Mod) ++ ".erl".

%% Given a path like "stdlib/include/erl_compile.hrl", return
%% "OTP_INSTALL_DIR/lib/erlang/lib/stdlib-x.y.z/include/erl_compile.hrl".
%% Usually a simple [Lib, SubDir, File1] = filename:split(File) should
%% work, but to not crash when an unusual include_lib path is used,
%% utilize more elaborate logic.
maybe_expand_include_lib_path(File, Dir) ->
    File1 = filename:basename(File),
    case filename:split(filename:dirname(File)) of
        [_] ->
            warn_and_find_path(File, Dir);
        [Lib | SubDir] ->
            case code:lib_dir(list_to_atom(Lib), list_to_atom(filename:join(SubDir))) of
                {error, bad_name} ->
                    warn_and_find_path(File, Dir);
                AppDir ->
                    [filename:join(AppDir, File1)]
            end
    end.

%% The use of -include_lib was probably incorrect by the user but lets try to make it work.
%% We search in the outdir and outdir/../include to see if the header exists.
warn_and_find_path(File, Dir) ->
    SrcHeader = filename:join(Dir, File),
    case filelib:is_regular(SrcHeader) of
        true ->
            [SrcHeader];
        false ->
            IncludeDir = filename:join(rebar_utils:droplast(filename:split(Dir))++["include"]),
            IncludeHeader = filename:join(IncludeDir, File),
            case filelib:is_regular(IncludeHeader) of
                true ->
                    [filename:join(IncludeDir, File)];
                false ->
                    []
            end
    end.

%%
%% Ensure all files in a list are present and abort if one is missing
%%
-spec check_files([file:filename()]) -> [file:filename()].
check_files(FileList) ->
    [check_file(F) || F <- FileList].

check_file(File) ->
    case filelib:is_regular(File) of
        false -> ?ABORT("File ~p is missing, aborting\n", [File]);
        true -> File
    end.

outdir(RebarOpts) ->
    ErlOpts = rebar_opts:erl_opts(RebarOpts),
    proplists:get_value(outdir, ErlOpts, ?DEFAULT_OUTDIR).

%% 从配置中得到hrl文件的存储路径加上默认include目录
include_abs_dirs(ErlOpts, BaseDir) ->
    InclDirs = ["include"|proplists:get_all_values(i, ErlOpts)],
    lists:map(fun(Incl) -> filename:join([BaseDir, Incl]) end, InclDirs).

parse_opts(Opts) -> parse_opts(Opts, #compile_opts{}).

parse_opts([], CompileOpts) -> CompileOpts;
parse_opts([{recursive, Recursive}|Rest], CompileOpts) when Recursive == true; Recursive == false ->
    parse_opts(Rest, CompileOpts#compile_opts{recursive = Recursive}).
