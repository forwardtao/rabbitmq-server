%%   The contents of this file are subject to the Mozilla Public License
%%   Version 1.1 (the "License"); you may not use this file except in
%%   compliance with the License. You may obtain a copy of the License at
%%   http://www.mozilla.org/MPL/
%%
%%   Software distributed under the License is distributed on an "AS IS"
%%   basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%   License for the specific language governing rights and limitations
%%   under the License.
%%
%%   The Original Code is RabbitMQ.
%%
%%   The Initial Developers of the Original Code are LShift Ltd,
%%   Cohesive Financial Technologies LLC, and Rabbit Technologies Ltd.
%%
%%   Portions created before 22-Nov-2008 00:00:00 GMT by LShift Ltd,
%%   Cohesive Financial Technologies LLC, or Rabbit Technologies Ltd
%%   are Copyright (C) 2007-2008 LShift Ltd, Cohesive Financial
%%   Technologies LLC, and Rabbit Technologies Ltd.
%%
%%   Portions created by LShift Ltd are Copyright (C) 2007-2010 LShift
%%   Ltd. Portions created by Cohesive Financial Technologies LLC are
%%   Copyright (C) 2007-2010 Cohesive Financial Technologies
%%   LLC. Portions created by Rabbit Technologies Ltd are Copyright
%%   (C) 2007-2010 Rabbit Technologies Ltd.
%%
%%   All Rights Reserved.
%%
%%   Contributor(s): ______________________________________.
%%

-module(rabbit_networking).

-export([boot/0, start/0, start_tcp_listener/1, start_ssl_listener/2,
         stop_tcp_listener/1, on_node_down/1, active_listeners/0,
         node_listeners/1, connections/0, connection_info_keys/0,
         connection_info/1, connection_info/2,
         connection_info_all/0, connection_info_all/1,
         close_connection/2]).

%%used by TCP-based transports, e.g. STOMP adapter
-export([check_tcp_listener_address/2]).

-export([tcp_listener_started/3, tcp_listener_stopped/3,
         start_client/1, start_ssl_client/2]).

-include("rabbit.hrl").
-include_lib("kernel/include/inet.hrl").

-define(RABBIT_TCP_OPTS, [
        binary,
        {packet, raw}, % no packaging
        {reuseaddr, true}, % allow rebind without waiting
        {backlog, 128}, % use the maximum listen(2) backlog value
        %% {nodelay, true}, % TCP_NODELAY - disable Nagle's alg.
        %% {delay_send, true},
        {exit_on_close, false}
    ]).

-define(SSL_TIMEOUT, 5). %% seconds

%%----------------------------------------------------------------------------

-ifdef(use_specs).

-export_type([ip_port/0, hostname/0]).

-type(family() :: atom()).
-type(listener_config() :: {hostname(), ip_port()} |
                           {hostname(), ip_port(), family()}).

-spec(start/0 :: () -> 'ok').
-spec(start_tcp_listener/1 :: (listener_config()) -> 'ok').
-spec(start_ssl_listener/2 ::
        (listener_config(), rabbit_types:infos()) -> 'ok').
-spec(stop_tcp_listener/1 :: (listener_config()) -> 'ok').
-spec(active_listeners/0 :: () -> [rabbit_types:listener()]).
-spec(node_listeners/1 :: (node()) -> [rabbit_types:listener()]).
-spec(connections/0 :: () -> [rabbit_types:connection()]).
-spec(connection_info_keys/0 :: () -> rabbit_types:info_keys()).
-spec(connection_info/1 ::
        (rabbit_types:connection()) -> rabbit_types:infos()).
-spec(connection_info/2 ::
        (rabbit_types:connection(), rabbit_types:info_keys())
        -> rabbit_types:infos()).
-spec(connection_info_all/0 :: () -> [rabbit_types:infos()]).
-spec(connection_info_all/1 ::
        (rabbit_types:info_keys()) -> [rabbit_types:infos()]).
-spec(close_connection/2 :: (pid(), string()) -> 'ok').
-spec(on_node_down/1 :: (node()) -> 'ok').
-spec(check_tcp_listener_address/2 :: (atom(), listener_config())
        -> [{inet:ip_address(), ip_port(), family(), atom()}]).

-endif.

%%----------------------------------------------------------------------------

boot() ->
    ok = start(),
    ok = boot_tcp(),
    ok = boot_ssl().

boot_tcp() ->
    {ok, TcpListeners} = application:get_env(tcp_listeners),
    [ok = start_tcp_listener(Listener) || Listener <- TcpListeners],
    ok.

boot_ssl() ->
    case application:get_env(ssl_listeners) of
        {ok, []} ->
            ok;
        {ok, SslListeners} ->
            ok = rabbit_misc:start_applications([crypto, public_key, ssl]),
            {ok, SslOptsConfig} = application:get_env(ssl_options),
            % unknown_ca errors are silently ignored  prior to R14B unless we
            % supply this verify_fun - remove when at least R14B is required
            SslOpts =
                case proplists:get_value(verify, SslOptsConfig, verify_none) of
                    verify_none -> SslOptsConfig;
                    verify_peer -> [{verify_fun, fun([])    -> true;
                                                    ([_|_]) -> false
                                                 end}
                                   | SslOptsConfig]
                end,
            [start_ssl_listener(Listener, SslOpts) || Listener <- SslListeners],
            ok
    end.

start() ->
    {ok,_} = supervisor:start_child(
               rabbit_sup,
               {rabbit_tcp_client_sup,
                {tcp_client_sup, start_link,
                 [{local, rabbit_tcp_client_sup},
                  {rabbit_connection_sup,start_link,[]}]},
                transient, infinity, supervisor, [tcp_client_sup]}),
    ok.

%% inet_parse:address takes care of ip string, like "0.0.0.0"
%% inet:getaddr returns immediately for ip tuple {0,0,0,0},
%%  and runs 'inet_gethost' port process for dns lookups.
%% On Windows inet:getaddr runs dns resolver for ip string, which may fail.

getaddr(Host, Family) ->
    case inet_parse:address(Host) of
        {ok, IPAddress} -> {IPAddress, resolve_family(IPAddress, Family)};
        {error, _}      -> gethostaddr(Host, Family)
    end.

gethostaddr(Host, auto) ->
    case inet:getaddr(Host, inet6) of
        {ok, IPAddress6} ->
            {IPAddress6, inet6};
        {error, Reason6} ->
            case inet:getaddr(Host, inet) of
                {ok, IPAddress4} -> {IPAddress4, inet};
                {error, Reason4} -> host_lookup_error(
                                      Host, {{ipv6, Reason6}, {ipv4, Reason4}})
            end
    end;

gethostaddr(Host, Family) ->
    case inet:getaddr(Host, Family) of
        {ok, IPAddress} -> {IPAddress, Family};
        {error, Reason} -> host_lookup_error(Host, Reason)
    end.

host_lookup_error(Host, Reason) ->
    error_logger:error_msg("invalid host ~p - ~p~n", [Host, Reason]),
    throw({error, {invalid_host, Host, Reason}}).

resolve_family({_,_,_,_},         auto) -> inet;
resolve_family({_,_,_,_,_,_,_,_}, auto) -> inet6;
resolve_family(IP,                auto) -> throw({error, {strange_family, IP}});
resolve_family(_,                 F)    -> F.

check_tcp_listener_address(NamePrefix, Port) when is_integer(Port) ->
    case ipv6_status(Port) of
        ipv4_only ->
            check_tcp_listener_address(NamePrefix, {"0.0.0.0", Port, inet});
        ipv6_single_stack ->
            check_tcp_listener_address(NamePrefix, {"::", Port, inet6});
        ipv6_dual_stack ->
            check_tcp_listener_address(NamePrefix, {"0.0.0.0", Port, inet})
                ++ check_tcp_listener_address(NamePrefix, {"::", Port, inet6})
    end;

check_tcp_listener_address(NamePrefix, {Host, Port}) ->
    %% auto: determine family IPv4 / IPv6 after converting to IP address
    check_tcp_listener_address(NamePrefix, {Host, Port, auto});

check_tcp_listener_address(NamePrefix, {Host, Port, Family0}) ->
    {IPAddress, Family} = getaddr(Host, Family0),
    if is_integer(Port) andalso (Port >= 0) andalso (Port =< 65535) -> ok;
       true -> error_logger:error_msg("invalid port ~p - not 0..65535~n",
                                      [Port]),
               throw({error, {invalid_port, Port}})
    end,
    Name = rabbit_misc:tcp_name(NamePrefix, IPAddress, Port),
    [{IPAddress, Port, Family, Name}].

start_tcp_listener(Listener) ->
    start_listener(Listener, amqp, "TCP Listener",
                   {?MODULE, start_client, []}).

start_ssl_listener(Listener, SslOpts) ->
    start_listener(Listener, 'amqp/ssl', "SSL Listener",
                   {?MODULE, start_ssl_client, [SslOpts]}).

start_listener(Listener, Protocol, Label, OnConnect) ->
    [start_listener0(Spec, Protocol, Label, OnConnect) ||
        Spec <- check_tcp_listener_address(rabbit_tcp_listener_sup, Listener)],
    ok.

start_listener0({IPAddress, Port, Family, Name}, Protocol, Label, OnConnect) ->
    {ok,_} = supervisor:start_child(
               rabbit_sup,
               {Name,
                {tcp_listener_sup, start_link,
                 [IPAddress, Port, [Family | ?RABBIT_TCP_OPTS],
                  {?MODULE, tcp_listener_started, [Protocol]},
                  {?MODULE, tcp_listener_stopped, [Protocol]},
                  OnConnect, Label]},
                transient, infinity, supervisor, [tcp_listener_sup]}).

stop_tcp_listener(Listener) ->
    [stop_tcp_listener0(Spec) ||
        Spec <- check_tcp_listener_address(rabbit_tcp_listener_sup, Listener)].

stop_tcp_listener0({IPAddress, Port, _Family, Name}) ->
    Name = rabbit_misc:tcp_name(rabbit_tcp_listener_sup, IPAddress, Port),
    ok = supervisor:terminate_child(rabbit_sup, Name),
    ok = supervisor:delete_child(rabbit_sup, Name),
    ok.

tcp_listener_started(Protocol, IPAddress, Port) ->
    %% We need the ip to distinguish e.g. 0.0.0.0 and 127.0.0.1
    %% We need the host so we can distinguish multiple instances of the above
    %% in a cluster.
    ok = mnesia:dirty_write(
           rabbit_listener,
           #listener{node = node(),
                     protocol = Protocol,
                     host = tcp_host(IPAddress),
                     ip_address = IPAddress,
                     port = Port}).

tcp_listener_stopped(Protocol, IPAddress, Port) ->
    ok = mnesia:dirty_delete_object(
           rabbit_listener,
           #listener{node = node(),
                     protocol = Protocol,
                     host = tcp_host(IPAddress),
                     ip_address = IPAddress,
                     port = Port}).

active_listeners() ->
    rabbit_misc:dirty_read_all(rabbit_listener).

node_listeners(Node) ->
    mnesia:dirty_read(rabbit_listener, Node).

on_node_down(Node) ->
    ok = mnesia:dirty_delete(rabbit_listener, Node).

start_client(Sock, SockTransform) ->
    {ok, _Child, Reader} = supervisor:start_child(rabbit_tcp_client_sup, []),
    ok = rabbit_net:controlling_process(Sock, Reader),
    Reader ! {go, Sock, SockTransform},
    Reader.

start_client(Sock) ->
    start_client(Sock, fun (S) -> {ok, S} end).

start_ssl_client(SslOpts, Sock) ->
    start_client(
      Sock,
      fun (Sock1) ->
              case catch ssl:ssl_accept(Sock1, SslOpts, ?SSL_TIMEOUT * 1000) of
                  {ok, SslSock} ->
                      rabbit_log:info("upgraded TCP connection ~p to SSL~n",
                                      [self()]),
                      {ok, #ssl_socket{tcp = Sock1, ssl = SslSock}};
                  {error, Reason} ->
                      {error, {ssl_upgrade_error, Reason}};
                  {'EXIT', Reason} ->
                      {error, {ssl_upgrade_failure, Reason}}

              end
      end).

connections() ->
    [rabbit_connection_sup:reader(ConnSup) ||
        Node <- rabbit_mnesia:running_clustered_nodes(),
        {_, ConnSup, supervisor, _}
            <- supervisor:which_children({rabbit_tcp_client_sup, Node})].

connection_info_keys() -> rabbit_reader:info_keys().

connection_info(Pid) -> rabbit_reader:info(Pid).
connection_info(Pid, Items) -> rabbit_reader:info(Pid, Items).

connection_info_all() -> cmap(fun (Q) -> connection_info(Q) end).
connection_info_all(Items) -> cmap(fun (Q) -> connection_info(Q, Items) end).

close_connection(Pid, Explanation) ->
    case lists:member(Pid, connections()) of
        true  -> rabbit_reader:shutdown(Pid, Explanation);
        false -> throw({error, {not_a_connection_pid, Pid}})
    end.

%%--------------------------------------------------------------------

tcp_host({0,0,0,0}) ->
    hostname();

tcp_host({0,0,0,0,0,0,0,0}) ->
    hostname();

tcp_host(IPAddress) ->
    case inet:gethostbyaddr(IPAddress) of
        {ok, #hostent{h_name = Name}} -> Name;
        {error, _Reason} -> inet_parse:ntoa(IPAddress)
    end.

hostname() ->
    {ok, Hostname} = inet:gethostname(),
    case inet:gethostbyname(Hostname) of
        {ok,    #hostent{h_name = Name}} -> Name;
        {error, _Reason}                 -> Hostname
    end.

cmap(F) -> rabbit_misc:filter_exit_map(F, connections()).

%%--------------------------------------------------------------------

%% How to test on Linux:
%% Single stack (default):
%% echo 0 > /proc/sys/net/ipv6/bindv6only
%% Dual stack:
%% echo 1 > /proc/sys/net/ipv6/bindv6only
%% IPv4 only:
%% add ipv6.disable=1 to GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub then
%% sudo update-grub && sudo reboot

ipv6_status(Port) ->
    %% Unfortunately it seems there is no way to detect single vs dual stack
    %% apart from attempting to bind to the socket.
    IPv4 = [inet,  {ip, {0,0,0,0}}],
    IPv6 = [inet6, {ip, {0,0,0,0,0,0,0,0}}],
    case gen_tcp:listen(Port, IPv6) of
        {ok, LSock6} ->
            Status = case gen_tcp:listen(Port, IPv4) of
                         {ok, LSock4} ->
                             gen_tcp:close(LSock4),
                             ipv6_dual_stack;
                         {error, _} ->
                             ipv6_single_stack
                     end,
            gen_tcp:close(LSock6),
            Status;
        {error, _} ->
            %% It could be that there's a general problem binding to
            %% the port, but plow on; the error will get picked up
            %% later when we bind for real.
            ipv4_only
    end.
