%%%-------------------------------------------------------------------
%%% @author LWL
%%% @copyright (C) 2018, <COMPANY>
%%% @doc
%%% 在shell里编译加载文件到所有节点(只用于开发环境)
%%% 知道热更文件最好用cl/1, 热更hrl头文件epp请求会频繁请求code_server可能会对代码加载有影响
%%% @end
%%% Created : 20. 十一月 2018 20:02
%%%-------------------------------------------------------------------
-module(cc).

-include_lib("kernel/include/file.hrl").
-define(default_max_worker, erlang:system_info(schedulers)).  %% default number worker = schedulers

%% API
-export([help/0]).
-export([cl/0, cl/1, cl_hrl/1, cl_hrl/2]).
-export([nl/3, nl_ex/4]). %% internal api

help() ->
    io:put_chars(<<"description:\n"
    "cl()           -- compile *.erl exclude hrl modify and load code to nodes\n"
    "cl(Module)     -- compile <Module>.erl and load code to nodes\n"
    "cl_hrl(Hrl)    -- compile *.erl include <Hrl>.hrl and load code to nodes\n"
    "cl_hrl(Hrl,N)  -- same as cl_hrl(Hrl), N is number of search compile worker\n"
    "\n"
    "usage:\n"
    "cl()           --  cl().\n"
    "cl(Module)     --  cl(lib_role). cl([lib_role, lib_role_attr]).\n"
    "cl_hrl(Hrl)    --  cl_hrl(role). cl_hrl([role, scene, prot_706])\n"
    "cl_hrl(Hrl,N)  --  cl_hrl(role, 4). cl_hrl([role, scene, prot_706], 4)\n">>).

cl() ->
    {ok, Pwd} = file:get_cwd(),
    case pwd_is_dir_config(Pwd) of
        true ->
            Start = format_time(),
            _ = file:set_cwd("../"),
            DefaultWorkerNum = ?default_max_worker,
            Ret =
                try
                    compile_nl_exclude_hrl(DefaultWorkerNum)
                catch
                    _Class:Error -> Error
                end,
            _ = file:set_cwd(Pwd),
            io:format("*** Start at ~s, Finish at ~s ***~n", [Start, format_time()]),
            Ret;
        false ->
            "pwd is not dir:config"
    end.

%% @doc 编译热更erl文件
cl(Module) when is_atom(Module) ->
    {ok, Pwd} = file:get_cwd(),
    case pwd_is_dir_config(Pwd) of
        true ->
            Start = format_time(),
            _ = file:set_cwd("../"),
            Ret =
                try
                    case get_compile(Module) of
                        {ok, File, Options} ->
                            compile_nl(File, Options);
                        _ ->
                            error
                    end
                catch
                    _Class:Error -> Error
                end,
            _ = file:set_cwd(Pwd),
            io:format("*** Start at ~s, Finish at ~s ***~n", [Start, format_time()]),
            Ret;
        false ->
            "pwd is not dir:config"
    end;
cl(ModuleList) when is_list(ModuleList) ->
    [{Module, cl(Module)} || Module <- lists:usort(ModuleList), is_atom(Module)].

%% @doc 编译热更hrl头文件
cl_hrl(Hrl) when is_atom(Hrl) ->
    cl_hrl([Hrl]);
cl_hrl(HrlFiles) when is_list(HrlFiles) ->
    DefaultWorkerNum = ?default_max_worker,
    cl_hrl(HrlFiles, DefaultWorkerNum).

cl_hrl(Hrl, WorkerNum) when is_atom(Hrl), is_integer(WorkerNum), WorkerNum > 0 ->
    cl_hrl([Hrl], WorkerNum);
cl_hrl(HrlFiles, WorkerNum) when is_list(HrlFiles), is_integer(WorkerNum), WorkerNum > 0 ->
    {ok, Pwd} = file:get_cwd(),
    case pwd_is_dir_config(Pwd) of
        true ->
            Start = format_time(),
            _ = file:set_cwd("../"),
            Ret =
                try
                    compile_nl_include_hrl(HrlFiles, WorkerNum)
                catch
                    _Class:Error -> Error
                end,
            _ = file:set_cwd(Pwd),
            io:format("*** Start at ~s, Finish at ~s ***~n", [Start, format_time()]),
            Ret;
        false ->
            "pwd is not dir:config"
    end.

pwd_is_dir_config(Pwd) ->
    filename:basename(Pwd) =:= "config".

get_compile(Module) ->
    case code:is_loaded(Module) of
        {file, _} ->
            get_compile_from_beam(Module);
        _ ->
            get_compile_from_src(Module)
    end.

compile_file(File, Opts) ->
    case compile:file(File, Opts) of
        {ok, Mod} ->
            {ok, Mod};
        {ok, Mod, []} ->
            {ok, Mod};
        {ok, _Mod, Ws} ->
            io:format("~s~n", [format_warnings(File, Ws)]),
            error;
        {error, Es, Ws} ->
            io:format("~s ~s~n", [format_errors(File, Es), format_warnings(File, Ws)]),
            error;
        error ->
            error
    end.

compile_nl(File, Options) ->
    io:format("~s compile: ~s.erl~n", [format_time(), File]),
    case compile_file(File, Options) of
        {ok, Module} ->
            nl(Module, File, Options);
        _ ->
            error
    end.

%% @doc 加载代码到所有节点netload
nl(Module, File, Options) ->
    Dir = outdir(Options),
    Obj = filename:basename(File, ".erl") ++ code:objfile_extension(),
    Filename = filename:join(Dir, Obj),
    AbsFilename = filename:absname(Filename),
    case file:read_file(Filename) of
        {ok, Bin} ->
            Nodes = [node() | nodes(connected)],
            rpc:eval_everywhere(Nodes, ?MODULE, nl_ex, [Module, AbsFilename, Bin, Nodes]),
%%            AllNodes = lists:usort(lists:flatten(nodes() ++ [rpc:call(X, erlang, nodes, [connected]) || X <- nodes()])),
            ok;
        Error ->
            Error
    end.

nl_ex(Module, Filename, Bin, ExcludeNodes) ->
    code:load_binary(Module, Filename, Bin),
    Nodes = nodes(connected) -- ExcludeNodes,
    rpc:eval_everywhere(Nodes, code, load_binary, [Module, Filename, Bin]).

%% 并行编译erl文件
parallel_compile_nl(Files, #{worker_fun := WorkerFun, max_num := 1} = Worker) ->
    %% 顺序编译
    case pick_file(Files) of
        {ok, PickFile, PickOpts, RestFiles} ->
            case WorkerFun(PickFile, PickOpts) of
                {compile_nl_result, ok} ->
                    parallel_compile_nl(RestFiles, Worker);
                _Error ->
                    flush(),
                    error
            end;
        empty ->
            flush(),
            ok
    end;
parallel_compile_nl(Files, #{worker_fun := WorkerFun, run_num := RunNum, max_num := MaxNum} = Worker) when RunNum < MaxNum ->
    case pick_file(Files) of
        {ok, PickFile, PickOpts, RestFiles} ->
            spawn(fun() -> WorkerFun(PickFile, PickOpts) end),
            parallel_compile_nl(RestFiles, Worker#{run_num => RunNum + 1});
        empty ->
            wait_worker(RunNum),
            ok
    end;
parallel_compile_nl(Files, #{run_num := RunNum, max_num := MaxNum} = Worker) when RunNum >= MaxNum ->
    receive
        {compile_nl_result, ok} ->
            parallel_compile_nl(Files, Worker#{run_num => RunNum - 1});
        {compile_nl_result, Rs} ->  %% 编译报错,立刻停止
            wait_worker(RunNum - 1),
            Rs;
        Error ->
            wait_worker(RunNum - 1),
            Error
    end.

pick_file([{[], _Opts} | Rest]) ->
    pick_file(Rest);
pick_file([{[File | T], Opts} | Rest]) ->
    {ok, File, Opts, [{T, Opts} | Rest]};
pick_file([]) ->
    empty.

wait_worker(RunNum) when RunNum > 0 ->
    receive
        {compile_nl_result, ok} ->
            wait_worker(RunNum - 1);
        {compile_nl_result, _Rs} ->
            wait_worker(RunNum - 1);
        _Error ->
            wait_worker(RunNum - 1)
    after 20 * 1000 ->  %% 20s 没有返回,停止编译
        flush(),
        timeout
    end;
wait_worker(_) ->
    flush(),
    ok.

%% 并行编译hrl,时间主要消耗在epp处理文件
compile_nl_include_hrl(HrlFiles0, WorkerNum) ->
    HrlFiles = [atom_to_list(Hrl) || Hrl <- lists:usort(HrlFiles0), is_atom(Hrl)],
    IncludeHrlFiles = [filename:basename(Hrl, ".hrl") || Hrl <- filelib:wildcard("include/**/*.hrl")],
    case HrlFiles =/= [] andalso validator_hrl_files(HrlFiles, IncludeHrlFiles) of
        true ->
            case read_emakefile() of
                [] ->
                    io:format("src any subdirectory notfound *.erl !"),
                    error;
                {[], _} ->
                    io:format("src any subdirectory notfound *.erl !"),
                    error;
                Files when is_list(Files) ->
                    compile_nl_include_hrl(Files, HrlFiles, WorkerNum);
                error ->
                    error
            end;
        false ->
            io:format("include directory notfound hrl ~w!", [HrlFiles]),
            error
    end.

compile_nl_include_hrl(Files, HrlFiles, WorkerNum) ->
    Parent = self(),
    Fun =
        fun(File, Opts) ->
            IncludePath = include_opt(Opts),
            Rs =
                try
                    case check_includes(lists:append(File, ".erl"), IncludePath, HrlFiles) of
                        true ->
                            compile_nl(File, Opts);
                        false ->
                            ok;
                        Error ->
                            error_logger:error_report(lists:flatten(io_lib:format("~p", [Error]))),
                            error
                    end
                catch
                    _:E ->
                        E
                end,
            if
                WorkerNum > 1 ->
                        catch Parent ! {compile_nl_result, Rs};
                true ->
                    {compile_nl_result, Rs}
            end
        end,
    Worker = #{worker_fun => Fun, run_num => 0, max_num => WorkerNum},
    parallel_compile_nl(Files, Worker).

%% 并行编译,不对比查找hrl文件的修改,只编译有更改的erl
compile_nl_exclude_hrl(WorkerNum) ->
    case read_emakefile() of
        [] ->
            io:format("src any subdirectory notfound *.erl !"),
            error;
        {[], _} ->
            io:format("src any subdirectory notfound *.erl !"),
            error;
        Files when is_list(Files) ->
            compile_nl_exclude_hrl(Files, WorkerNum);
        error ->
            error
    end.

compile_nl_exclude_hrl(Files, WorkerNum) ->
    Parent = self(),
    WorkerFun =
        fun(File, Opts) ->
            Dir = outdir(Opts),
            Obj = filename:basename(File, ".erl") ++ code:objfile_extension(),
            ObjFile = filename:join(Dir, Obj),
            Recompile =
                case file:read_file_info(ObjFile) of
                    {ok, _} ->
                        {ok, #file_info{mtime = Te}} = file:read_file_info(lists:append(File, ".erl")),
                        {ok, #file_info{mtime = To}} = file:read_file_info(ObjFile),
                        Te > To;
                    _ ->
                        true
                end,
            Rs =
                if
                    Recompile ->
                        compile_nl(File, Opts);
                    true ->
                        ok
                end,
            if
                WorkerNum > 1 ->
                        catch Parent ! {compile_nl_result, Rs};
                true ->
                    {compile_nl_result, Rs}
            end
        end,
    Worker = #{worker_fun => WorkerFun, run_num => 0, max_num => WorkerNum},
    parallel_compile_nl(Files, Worker).

outdir(Opts) ->
    case lists:keyfind(outdir, 1, Opts) of
        false -> "ebin";
        {outdir, O} -> O
    end.

include_opt([{i, Path} | Rest]) ->
    [Path | include_opt(Rest)];
include_opt([_First | Rest]) ->
    include_opt(Rest);
include_opt([]) ->
    [].

validator_hrl_files([], _IncludeHrlFiles) -> true;
validator_hrl_files([H | T], IncludeHrlFiles) ->
    case lists:member(H, IncludeHrlFiles) of
        true ->
            validator_hrl_files(T, IncludeHrlFiles);
        false ->
            io:format("~s.hrl is notfound!", [H]),
            false
    end.

get_compile_from_beam(Module) ->
    Props = Module:module_info(compile),
    Options1 = proplists:get_value(options, Props, []),
    Source = proplists:get_value(source, Props),
    case filelib:is_regular(Source) of
        true ->
            case file:consult('Emakefile') of
                {ok, Emake} ->
                    [{_Mods, Opts} | _] = Emake,
                    Options2 = lists:filter(fun({i, _}) -> false; ({outdir, _}) -> false; (_) -> true end, Options1);
                _ ->
                    Opts = [],
                    Options2 = Options1
            end,
%%            BeamDir = filename:dirname(code:which(Module)),
            File = filename:join([filename:dirname(Source), filename:basename(Source, ".erl")]),
            Options = lists:usort([report_errors, report_warnings, error_summary] ++ Opts ++ Options2),
            {ok, File, Options};
        false ->
            %% maybe move src/erl file to another dir, search src
            get_compile_from_src(Module)
    end.

get_compile_from_src(Module) ->
    ModuleStr = atom_to_list(Module),
    case read_emakefile() of
        [] ->
            io:format("src any subdirectory notfound *.erl, search:~s is not found!", [ModuleStr]),
            error;
        [{[], _}] ->
            io:format("src any subdirectory notfound *.erl, search:~s is notfound!", [ModuleStr]),
            error;
        Files when is_list(Files) ->
            case search_src_file_is_module(Files, ModuleStr) of
                {ok, File, Options} ->
                    {ok, File, Options};
                false ->
                    io:format("module:~s is notfound!", [ModuleStr]),
                    error
            end;
        error ->
            error
    end.

search_src_file_is_module([{[], _Opts} | Rest], ModuleStr) ->
    search_src_file_is_module(Rest, ModuleStr);
search_src_file_is_module([{[File | T], Opts} | Rest], ModuleStr) ->
    case filename:basename(File, ".erl") =:= ModuleStr of
        true ->
            {ok, File, Opts};
        false ->
            search_src_file_is_module([{T, Opts} | Rest], ModuleStr)
    end;
search_src_file_is_module([], _ModuleStr) ->
    false.

%%% Reads the given Emakefile and returns a list of tuples: {Mods,Opts}
%%% Mods is a list of module names (strings)
%%% Opts is a list of options to be used when compiling Mods
%%%
%%% Emakefile can contain elements like this:
%%% Mod.
%%% {Mod,Opts}.
%%% Mod is a module name which might include '*' as wildcard
%%% or a list of such module names
%%%
%%% These elements are converted to [{ModList,OptList},...]
%%% ModList is a list of modulenames (strings)
read_emakefile() ->
    case file:consult('Emakefile') of
        {ok, Emake} ->
            Opts = [report_errors, report_warnings, error_summary],
            transform(Emake, Opts, [], []);
        {error, enoent} ->
            %% No Emakefile found - return all modules in src any subdirectory
            %% directory and the options given at command line
            Mods = [filename:rootname(F) || F <- filelib:wildcard("src/**/*.erl")],
            Opts = [report_errors, report_warnings, error_summary, debug_info,
                {i, "include"}, {outdir, "ebin"}, {d, xyj_debug}, {d, strict}],
            [{Mods, Opts}];
        {error, Other} ->
            io:format("make: Trouble reading 'Emakefile':~n~tp~n", [Other]),
            error
    end.

transform([{Mod, ModOpts} | Emake], Opts, Files, Already) ->
    case expand(Mod, Already) of
        [] ->
            transform(Emake, Opts, Files, Already);
        Mods ->
            transform(Emake, Opts, [{Mods, ModOpts ++ Opts} | Files], Mods ++ Already)
    end;
transform([Mod | Emake], Opts, Files, Already) ->
    case expand(Mod, Already) of
        [] ->
            transform(Emake, Opts, Files, Already);
        Mods ->
            transform(Emake, Opts, [{Mods, Opts} | Files], Mods ++ Already)
    end;
transform([], _Opts, Files, _Already) ->
    lists:reverse(Files).

expand(Mod, Already) when is_atom(Mod) ->
    expand(atom_to_list(Mod), Already);
expand(Mods, Already) when is_list(Mods), not is_integer(hd(Mods)) ->
    lists:concat([expand(Mod, Already) || Mod <- Mods]);
expand(Mod, Already) ->
    case lists:member($*, Mod) of
        true ->
            Fun = fun(F, Acc) ->
                M = filename:rootname(F),
                case lists:member(M, Already) of
                    true -> Acc;
                    false -> [M | Acc]
                end
                  end,
            lists:foldl(Fun, [], filelib:wildcard(Mod ++ ".erl"));
        false ->
            Mod2 = filename:rootname(Mod, ".erl"),
            case lists:member(Mod2, Already) of
                true -> [];
                false -> [Mod2]
            end
    end.

%%% If you an include file is found with a modification
%%% time larger than the modification time of the object
%%% file, return true. Otherwise return false.
check_includes(File, IncludePath, HrlFiles) ->
    Path = [filename:dirname(File) | IncludePath],
    case epp:open(File, Path, []) of
        {ok, Epp} ->
            check_includes2(Epp, File, HrlFiles);
        _Error ->
            false
    end.

check_includes2(Epp, File, HrlFiles) ->
    case epp:parse_erl_form(Epp) of
        {ok, {attribute, 1, file, {File, 1}}} ->
            check_includes2(Epp, File, HrlFiles);
        {ok, {attribute, 1, file, {IncFile, 1}}} ->
            Hrl = filename:basename(IncFile, ".hrl"),
            case lists:member(Hrl, HrlFiles) of
                true ->
                    epp:close(Epp),
                    true;
                _ ->
                    check_includes2(Epp, File, HrlFiles)
            end;
        {ok, _} ->
            check_includes2(Epp, File, HrlFiles);
        {eof, _} ->
            epp:close(Epp),
            false;
        {warning, _} ->
            check_includes2(Epp, File, HrlFiles);
        {error, _Error} ->
            check_includes2(Epp, File, HrlFiles)
    end.

format_errors(Source, Errors) ->
    format_errors(Source, "", Errors).

format_warnings(Source, Warnings) ->
    format_warnings(Source, Warnings, []).

format_warnings(Source, Warnings, Opts) ->
    Prefix =
        case lists:member(warnings_as_errors, Opts) of
            true -> "";
            false -> "Warning: "
        end,
    format_errors(Source, Prefix, Warnings).

format_errors(_MainSource, Extra, Errors) ->
    [begin
         [format_error(Source, Extra, Desc) || Desc <- Descs]
     end
        || {Source, Descs} <- Errors].

format_error(AbsSource, Extra, {{Line, Column}, Mod, Desc}) ->
    ErrorDesc = Mod:format_error(Desc),
    io_lib:format("~s:~w:~w: ~s~s~n", [AbsSource, Line, Column, Extra, ErrorDesc]);
format_error(AbsSource, Extra, {Line, Mod, Desc}) ->
    ErrorDesc = Mod:format_error(Desc),
    io_lib:format("~s:~w: ~s~s~n", [AbsSource, Line, Extra, ErrorDesc]);
format_error(AbsSource, Extra, {Mod, Desc}) ->
    ErrorDesc = Mod:format_error(Desc),
    io_lib:format("~s: ~s~s~n", [AbsSource, Extra, ErrorDesc]).


format_time() ->
    format_time(erlang:localtime()).

format_time({{Y, M, D}, {H, Mi, S}}) ->
    lists:flatten([integer_to_list(Y), $-, i2l(M), $-, i2l(D), $ , i2l(H), $:, i2l(Mi), $:, i2l(S)]).

i2l(I) when I < 10 -> [$0, $0 + I];
i2l(I) -> integer_to_list(I).

flush() ->
    receive
        _ ->
            flush()
    after 0 ->
        ok
    end.