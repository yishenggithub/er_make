%%%------------------------------------
%%% @author
%%% @doc 本地开发热更模块（开发调试用）.
%%% @end
%%%------------------------------------

-module(h).

-export([
	h/0     % 热更修改过的erl文件
	, hh/0   % 热更修改过的hrl头文件
]).
-compile(export_all).

-include_lib("kernel/include/file.hrl").
-include("common.hrl").

-define(default_max_worker, erlang:system_info(schedulers)).

h() ->
	CodePath = sys_env:get(code_path),
	ErlFileList = filelib:wildcard(lists:concat([CodePath, "/src/**/*.erl"])),
	F = fun(ErlFile) ->
		case file:read_file_info(ErlFile) of
			{ok, #file_info{mtime = ErlTime}} ->
				BeamName = lists:concat([
					CodePath,
					"/ebin/",
					filename:basename(ErlFile, ".erl"),
					code:objfile_extension()]
				),
				case file:read_file_info(BeamName) of
					{ok, #file_info{mtime = BeamTime}} when ErlTime > BeamTime ->
						ErlFile;
					{ok, _} ->
						skip;
					_E ->
						ErlFile
				end;
			_ ->
				skip
		end
	    end,
	CompileFiles = [Y || Y <- [F(X) || X <- ErlFileList], Y =/= skip],
	StartTime = date:unixtime(),
	io:format("----------makes----------~n"),
	IDir = lists:concat([CodePath, "/inc"]),
	OutDir = lists:concat([CodePath, "/ebin"]),
	
	Res = make:files(CompileFiles,
		[
			netload,
			{i, IDir},
			{outdir, OutDir},
			{hipe, [o3]},
			{parse_transform, lager_transform}
	]),
	EndTime = date:unixtime(),
	io:format("Make result = ~p~nMake Time : ~p s", [Res, EndTime - StartTime]),
	% 其他服加载代码（cast到某条线调用，通过跨服中心让所有服务器加载这些文件）
	catch nodes_load_beam(CompileFiles),
	ok.

%% 编译期间会改变工作目录导致日志输出到server上，谨慎使用，可以优化
%% 可以在tools目录下用mmake
hh() ->
	StartTime = date:unixtime(),
	c:l(mmake),
	io:format("----------makes----------~n", []),
	{ok, Pwd} = file:get_cwd(),
	CodePath = sys_env:get(code_path),
	file:set_cwd(CodePath),
	Res = (catch mmake2:all(?default_max_worker, [netload])),
	_ = file:set_cwd(Pwd),
	EndTime = date:unixtime(),
	io:format("MMake result = ~p~nMMake Time : ~p s", [Res, EndTime - StartTime]),
	ok.

%% 跨服加载代码（跨服加载，通知所有服务器加载）
nodes_load_beam([]) -> skip;
nodes_load_beam(Files) ->
	Modules = [list_to_atom(filename:basename(File, ".erl")) || File <- Files],
	case nodes(connected) of
		[Node | _] ->
			rpc:cast(Node, ?MODULE, load_beam, [Modules]);
		_ ->
			skip
	end,
	ok.

% 本地某节点运行
load_beam(Modules) ->
	?INFO("通知加载beam文件~p~n", [Modules]),
	[c:nl(M) || M <- Modules],
	ok.

