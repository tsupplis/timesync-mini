%%
%% timesync - Minimal SNTP client (RFC 5905 subset)
%%
%% SPDX-License-Identifier: MIT
%% Copyright (c) 2025 tsupplis
%%
%% Permission is hereby granted, free of charge, to any person obtaining a copy
%% of this software and associated documentation files (the "Software"), to deal
%% in the Software without restriction, including without limitation the rights
%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%% copies of the Software, and to permit persons to whom the Software is
%% furnished to do so, subject to the following conditions:
%%
%% The above copyright notice and this permission notice shall be included in all
%% copies or substantial portions of the Software.
%%
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
%% SOFTWARE.

-module(timesync).
-export([main/1]).

%% Constants
-define(NTP_PORT, 123).
-define(NTP_PACKET_SIZE, 48).
-define(NTP_UNIX_EPOCH, 2208988800).
-define(DEFAULT_SERVER, "pool.ntp.org").
-define(DEFAULT_TIMEOUT_MS, 2000).
-define(DEFAULT_RETRIES, 3).

%% Main entry point
main(Args) ->
    Config = parse_args(Args, #{
        server => ?DEFAULT_SERVER,
        timeout_ms => ?DEFAULT_TIMEOUT_MS,
        retries => ?DEFAULT_RETRIES,
        verbose => false,
        test_only => false,
        use_syslog => false
    }),
    
    %% Disable syslog in test mode
    Config2 = case maps:get(test_only, Config) of
        true -> Config#{use_syslog => false};
        false -> Config
    end,
    
    case maps:get(verbose, Config2) of
        true ->
            log_stderr("DEBUG Using server: ~s", [maps:get(server, Config2)]),
            log_stderr("DEBUG Timeout: ~B ms, Retries: ~B, Syslog: ~s",
                [maps:get(timeout_ms, Config2), maps:get(retries, Config2),
                 case maps:get(use_syslog, Config2) of true -> "on"; false -> "off" end]);
        false -> ok
    end,
    
    ExitCode = do_ntp_query(Config2),
    erlang:halt(ExitCode).

%% Parse command line arguments
parse_args([], Config) ->
    Config;
parse_args(["-h" | _], _Config) ->
    show_usage(),
    halt(0);
parse_args(["-t", Timeout | Rest], Config) ->
    Ms = clamp(list_to_integer(Timeout), 1, 6000),
    parse_args(Rest, Config#{timeout_ms => Ms});
parse_args(["-r", Retries | Rest], Config) ->
    R = clamp(list_to_integer(Retries), 1, 10),
    parse_args(Rest, Config#{retries => R});
parse_args([[$- | Flags] | Rest], Config) ->
    %% Handle combined flags like -nv, -v, etc.
    Config2 = parse_flags(Flags, Config),
    parse_args(Rest, Config2);
parse_args([Server | Rest], Config) when hd(Server) =/= $- ->
    parse_args(Rest, Config#{server => Server});
parse_args([_ | Rest], Config) ->
    parse_args(Rest, Config).

parse_flags([], Config) -> Config;
parse_flags([$h | _], _Config) -> show_usage(), halt(0);
parse_flags([$n | Rest], Config) -> parse_flags(Rest, Config#{test_only => true});
parse_flags([$v | Rest], Config) -> parse_flags(Rest, Config#{verbose => true});
parse_flags([$s | Rest], Config) -> parse_flags(Rest, Config#{use_syslog => true});
parse_flags([_ | Rest], Config) -> parse_flags(Rest, Config).

clamp(Val, Min, _Max) when Val < Min -> Min;
clamp(Val, _Min, Max) when Val > Max -> Max;
clamp(Val, _Min, _Max) -> Val.

show_usage() ->
    io:format(standard_error,
        "Usage: timesync [-t timeout_ms] [-r retries] [-n] [-v] [-s] [-h] [ntp server]~n"
        "  server       NTP server to query (default: pool.ntp.org)~n"
        "  -t timeout   Timeout in ms (default: 2000)~n"
        "  -r retries   Number of retries (default: 3)~n"
        "  -n           Test mode (no system time adjustment)~n"
        "  -v           Verbose output~n"
        "  -s           Enable syslog logging~n"
        "  -h           Show this help message~n", []).

%% Logging functions
log_stderr(Format, Args) ->
    {{Y,M,D},{H,Mi,S}} = calendar:local_time(),
    io:format(standard_error, "~4..0B-~2..0B-~2..0B ~2..0B:~2..0B:~2..0B " ++ Format ++ "~n",
        [Y,M,D,H,Mi,S | Args]).

%% Get current time in milliseconds
get_time_ms() ->
    {MegaSecs, Secs, MicroSecs} = os:timestamp(),
    (MegaSecs * 1000000 + Secs) * 1000 + MicroSecs div 1000.

%% Build NTP request packet
build_ntp_request() ->
    <<16#1b, 0:((?NTP_PACKET_SIZE - 1) * 8)>>.

%% Parse NTP timestamp to Unix milliseconds
ntp_to_unix_ms(<<Sec:32, Frac:32>>) ->
    case Sec < ?NTP_UNIX_EPOCH of
        true -> {error, invalid_timestamp};
        false ->
            UnixSec = Sec - ?NTP_UNIX_EPOCH,
            UnixMs = (Frac * 1000) div 16#100000000,
            {ok, UnixSec * 1000 + UnixMs}
    end.

%% Perform NTP query
do_ntp_query(Config) ->
    do_ntp_query(Config, 1).

do_ntp_query(Config, Attempt) ->
    MaxRetries = maps:get(retries, Config),
    case Attempt > MaxRetries of
        true ->
            log_stderr("ERROR Failed to contact NTP server ~s after ~B attempts",
                [maps:get(server, Config), MaxRetries]),
            2;
        false ->
            do_ntp_attempt(Config, Attempt)
    end.

do_ntp_attempt(Config, Attempt) ->
    Verbose = maps:get(verbose, Config),
    Server = maps:get(server, Config),
    
    case Verbose of
        true -> log_stderr("DEBUG Attempt (~B) at NTP query on ~s ...", [Attempt, Server]);
        false -> ok
    end,
    
    %% Ensure inet is started
    application:ensure_all_started(kernel),
    
    %% Resolve hostname
    case inet:getaddr(Server, inet) of
        {error, _} ->
            log_stderr("ERROR Cannot resolve hostname: ~s", [Server]),
            2;
        {ok, Ip} ->
            case query_ntp_server(Ip, Config) of
                {error, timeout} ->
                    case Attempt < maps:get(retries, Config) of
                        true ->
                            timer:sleep(200),
                            do_ntp_query(Config, Attempt + 1);
                        false ->
                            log_stderr("ERROR Timeout waiting for NTP response", []),
                            2
                    end;
                {error, Reason} ->
                    log_stderr("ERROR ~s", [Reason]),
                    2;
                {ok, Result} ->
                    handle_ntp_result(Result, Config, Ip)
            end
    end.

%% Query NTP server
query_ntp_server(Ip, Config) ->
    TimeoutMs = maps:get(timeout_ms, Config),
    
    case gen_udp:open(0, [binary, {active, false}]) of
        {error, Reason} ->
            {error, io_lib:format("Cannot create socket: ~p", [Reason])};
        {ok, Socket} ->
            Packet = build_ntp_request(),
            LocalBefore = get_time_ms(),
            
            case gen_udp:send(Socket, Ip, ?NTP_PORT, Packet) of
                ok ->
                    case gen_udp:recv(Socket, ?NTP_PACKET_SIZE, TimeoutMs) of
                        {ok, {_Addr, _Port, Response}} ->
                            LocalAfter = get_time_ms(),
                            gen_udp:close(Socket),
                            handle_response(Response, LocalBefore, LocalAfter);
                        {error, _} ->
                            gen_udp:close(Socket),
                            {error, timeout}
                    end;
                {error, Reason} ->
                    gen_udp:close(Socket),
                    {error, io_lib:format("Send failed: ~p", [Reason])}
            end
    end.

%% Handle NTP response
handle_response(Response, LocalBefore, LocalAfter) when byte_size(Response) =:= ?NTP_PACKET_SIZE ->
    <<FirstByte, Stratum, _Rest/binary>> = Response,
    Mode = FirstByte band 16#07,
    
    case {Mode, Stratum} of
        {4, S} when S > 0 ->
            %% Extract transmit timestamp (bytes 40-47)
            <<_:320, TxTimestamp:64, _/binary>> = Response,
            <<TxSec:32, TxFrac:32>> = <<TxTimestamp:64>>,
            
            case ntp_to_unix_ms(<<TxSec:32, TxFrac:32>>) of
                {ok, RemoteMs} ->
                    {ok, #{
                        local_before => LocalBefore,
                        local_after => LocalAfter,
                        remote_ms => RemoteMs
                    }};
                {error, Reason} ->
                    {error, Reason}
            end;
        {M, _} when M =/= 4 ->
            {error, io_lib:format("Invalid mode in NTP response: ~B", [M])};
        {_, 0} ->
            {error, "Invalid stratum in NTP response"}
    end;
handle_response(_Response, _LocalBefore, _LocalAfter) ->
    {error, "Invalid NTP response size"}.

%% Handle NTP result
handle_ntp_result(#{local_before := LocalBefore, local_after := LocalAfter, 
                     remote_ms := RemoteMs}, Config, Ip) ->
    AvgLocal = (LocalBefore + LocalAfter) div 2,
    Offset = RemoteMs - AvgLocal,
    Rtt = LocalAfter - LocalBefore,
    
    Verbose = maps:get(verbose, Config),
    IpStr = inet:ntoa(Ip),
    
    case Verbose of
        true ->
            log_stderr("DEBUG Server: ~s (~s)", [maps:get(server, Config), IpStr]),
            log_stderr("DEBUG Local before(ms): ~B", [LocalBefore]),
            log_stderr("DEBUG Local after(ms): ~B", [LocalAfter]),
            log_stderr("DEBUG Remote time(ms): ~B", [RemoteMs]),
            log_stderr("DEBUG Estimated roundtrip(ms): ~B", [Rtt]),
            log_stderr("DEBUG Estimated offset remote - local(ms): ~B", [Offset]);
        false -> ok
    end,
    
    %% Validate RTT
    case Rtt < 0 orelse Rtt > 10000 of
        true ->
            log_stderr("ERROR Invalid roundtrip time: ~B ms", [Rtt]),
            1;
        false ->
            AbsOffset = abs(Offset),
            case AbsOffset > 0 andalso AbsOffset < 500 of
                true ->
                    case Verbose of
                        true -> log_stderr("INFO Delta < 500ms, not setting system time.", []);
                        false -> ok
                    end,
                    0;
                false ->
                    validate_and_set_time(RemoteMs, Offset, Config)
            end
    end.

%% Validate remote time and set if needed
validate_and_set_time(RemoteMs, Offset, Config) ->
    RemoteSec = RemoteMs div 1000,
    %% Unix epoch is 1970-01-01, convert to Erlang datetime
    UnixEpochSecs = calendar:datetime_to_gregorian_seconds({{1970,1,1},{0,0,0}}),
    {{RemoteYear, _, _}, _} = calendar:gregorian_seconds_to_datetime(UnixEpochSecs + RemoteSec),
    
    case RemoteYear < 2025 orelse RemoteYear > 2200 of
        true ->
            log_stderr("ERROR Remote year is out of valid range (2025-2200): ~B", [RemoteYear]),
            1;
        false ->
            case maps:get(test_only, Config) of
                true ->
                    case maps:get(verbose, Config) of
                        true -> log_stderr("INFO Test mode: would adjust system time by ~B ms", [Offset]);
                        false -> ok
                    end,
                    0;
                false ->
                    %% Check if running as root using port
                    case get_uid() of
                        0 ->
                            %% Running as root, try to set time
                            case set_system_time(RemoteMs) of
                                ok ->
                                    case maps:get(verbose, Config) of
                                        true -> log_stderr("INFO System time set (~B ms)", [RemoteMs]);
                                        false -> ok
                                    end,
                                    0;
                                {error, Reason} ->
                                    log_stderr("ERROR Failed to adjust system time: ~p", [Reason]),
                                    10
                            end;
                        _ ->
                            %% Not running as root
                            log_stderr("WARNING Not root, not setting system time.", []),
                            10
                    end
            end
    end.

%% Get current UID using a port
get_uid() ->
    try
        Port = open_port({spawn, "id -u"}, [exit_status, binary]),
        receive
            {Port, {data, Data}} ->
                UidStr = string:trim(binary_to_list(Data)),
                list_to_integer(UidStr);
            {Port, {exit_status, _}} ->
                -1
        after 1000 ->
            -1
        end
    catch
        _:_ -> -1
    end.

%% Set system time using a port to call date command
set_system_time(RemoteMs) ->
    try
        %% Convert ms to seconds
        Sec = RemoteMs div 1000,
        
        %% Try to use a helper script if it exists, otherwise use date command
        %% Format: YYYY-MM-DD HH:MM:SS
        UnixEpochSecs = calendar:datetime_to_gregorian_seconds({{1970,1,1},{0,0,0}}),
        {{Y, M, D}, {H, Min, S}} = calendar:gregorian_seconds_to_datetime(UnixEpochSecs + Sec),
        
        %% Use date command (macOS/BSD format)
        DateStr = io_lib:format("~4..0B~2..0B~2..0B~2..0B~2..0B.~2..0B", [Y, M, D, H, Min, S]),
        Cmd = lists:flatten(io_lib:format("date ~s", [DateStr])),
        
        Port = open_port({spawn, Cmd}, [exit_status]),
        receive
            {Port, {exit_status, 0}} ->
                ok;
            {Port, {exit_status, Status}} ->
                {error, {exit_status, Status}}
        after 5000 ->
            {error, timeout}
        end
    catch
        _:Error -> {error, Error}
    end.
