-module(wedge).
-export([run/0, single/0, stranded/0, check/0]).

%% The repro from the issue: another descriptor takes L's connection.
run() ->
    {L, Port} = listen(),
    %% D: a dup of L's fd, standing in for whatever else takes L's connection.
    D = dup(L),
    %% 1. Wait for a connection on L; this arms a one-shot select.
    Ref = make_ref(),
    {select, _} = socket:accept(L, Ref),
    %% 2. A client connects. The select fires, but D accepts the connection.
    connect(Port),
    receive {'$socket', L, select, Ref} -> ok end,
    {ok, _} = socket:accept(D, 1000),
    %% 3. Retry on L with a new handle, as socket:accept/2 does.
    Retry = show("retry", fun() -> socket:accept(L, make_ref()) end),
    %% 4. A blocking accept on L now fails at once.
    show("accept(L, 5000)", fun() -> socket:accept(L, 5000) end),
    show("accept(L, 5000)", fun() -> socket:accept(L, 5000) end),
    %% 5. Cancelling with the first handle clears it.
    show("cancel", fun() -> socket:cancel(L, {select_info, accept, Ref}) end),
    show("accept(L, 1000)", fun() -> socket:accept(L, 1000) end),
    case Retry of
        {select, _} -> ok;
        _ -> wedged
    end.

%% erlang/otp#11537's case: another process accepts on L before the retry.
single() ->
    {L, Port} = listen(),
    Ref = make_ref(),
    {select, _} = socket:accept(L, Ref),
    connect(Port),
    receive {'$socket', L, select, Ref} -> ok end,
    Self = self(),
    spawn(fun() -> Self ! {other, timed(fun() -> socket:accept(L, 1000) end)} end),
    timer:sleep(100),
    Retry = show("retry", fun() -> socket:accept(L, make_ref()) end),
    Other = other(),
    show("accept(L, 1000)", fun() -> socket:accept(L, 1000) end),
    case {Retry, Other} of
        {{select, _}, {ok, _}} -> direct;
        {{ok, _}, _} -> queued;
        _ -> wedged
    end.

%% After the wedge, another process on L misses a new connection.
stranded() ->
    {L, Port} = listen(),
    D = dup(L),
    Ref = make_ref(),
    {select, _} = socket:accept(L, Ref),
    connect(Port),
    receive {'$socket', L, select, Ref} -> ok end,
    {ok, _} = socket:accept(D, 1000),
    %% Retry, cancel with the handle it returns (as socket:accept/2 does on
    %% timeout), and stop accepting on L.
    case show("retry", fun() -> socket:accept(L, make_ref()) end) of
        {select, Info} -> show("cancel", fun() -> socket:cancel(L, Info) end);
        _ -> ok
    end,
    Self = self(),
    spawn(fun() -> Self ! {other, timed(fun() -> socket:accept(L, 3000) end)} end),
    timer:sleep(100),
    connect(Port),
    Other = other(),
    show("accept(L, 1000)", fun() -> socket:accept(L, 1000) end),
    case Other of
        {ok, _} -> ok;
        _ -> missed
    end.

%% Runs all three; the last line is the verdict.
check() ->
    io:format("OTP ~s, erts ~s, ~s~n",
              [erlang:system_info(otp_release), erlang:system_info(version),
               erlang:system_info(system_architecture)]),
    Vs =[{Name, section(Name, F)} || {Name, F} <- [{dup, fun run/0},
                                                    {single, fun single/0},
                                                    {stranded, fun stranded/0}]],
    io:format("~s~n", [lists:join(" ", [io_lib:format("~s=~s", [N, V]) || {N, V} <- Vs])]).

section(Name, F) ->
    io:format("== ~s~n", [Name]),
    F().

listen() ->
    {ok, L} = socket:open(inet, stream, tcp),
    ok = socket:bind(L, #{family => inet, addr => loopback, port => 0}),
    ok = socket:listen(L),
    {ok, #{port := Port}} = socket:sockname(L),
    {L, Port}.

dup(L) ->
    {ok, Fd} = socket:getopt(L, {otp, fd}),
    {ok, D} = socket:open(Fd, #{domain => inet, type => stream, protocol => tcp}),
    D.

connect(Port) ->
    {ok, C} = socket:open(inet, stream, tcp),
    ok = socket:connect(C, #{family => inet, addr => loopback, port => Port}),
    C.

other() ->
    receive
        {other, {R, Ms}} ->
            io:format("~-16s ~p (~p ms)~n", ["other process", brief(R), Ms]),
            R
    end.

show(What, F) ->
    {R, Ms} = timed(F),
    io:format("~-16s ~p (~p ms)~n", [What, brief(R), Ms]),
    R.

timed(F) ->
    T0 = erlang:monotonic_time(millisecond),
    R = try F() catch Class:Reason -> {raised, Class, Reason} end,
    {R, erlang:monotonic_time(millisecond) - T0}.

brief({ok, {'$socket', _}}) -> {ok, socket};
brief(R) -> R.
