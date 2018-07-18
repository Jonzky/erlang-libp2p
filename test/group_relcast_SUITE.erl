-module(group_relcast_SUITE).

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([unicast_test/1, multicast_test/1, defer_test/1, restart_test/1]).

all() ->
    [ %% restart_test,
      unicast_test,
      multicast_test,
      defer_test
    ].

init_per_testcase(defer_test, Config) ->
    Swarms = test_util:setup_swarms(2, [{libp2p_peerbook, [{notify_time, 1000}]}]),
    [{swarms, Swarms} | Config];
init_per_testcase(_, Config) ->
    Swarms = test_util:setup_swarms(3, [{libp2p_peerbook, [{notify_time, 1000}]}]),
    [{swarms, Swarms} | Config].

end_per_testcase(_, Config) ->
    Swarms = proplists:get_value(swarms, Config),
    test_util:teardown_swarms(Swarms).

await_peerbook(Swarm, Swarms) ->
    Addrs = lists:delete(
              libp2p_swarm:address(Swarm),
              [libp2p_swarm:address(S) || S <- Swarms]),
    PeerBook = libp2p_swarm:peerbook(Swarm),
    test_util:wait_until(
      fun() ->
              lists:all(fun(Addr) -> libp2p_peerbook:is_key(PeerBook, Addr) end,
                        Addrs)
      end).

await_peerbooks(Swarms) ->
    lists:foreach(fun(S) ->
                          ok = await_peerbook(S, Swarms)
                  end, Swarms).

unicast_test(Config) ->
    Swarms = [S1, S2, S3] = proplists:get_value(swarms, Config),

    test_util:connect_swarms(S1, S2),
    test_util:connect_swarms(S1, S3),

    await_peerbooks(Swarms),

    Members = [libp2p_swarm:address(S) || S <- Swarms],

    %% G1 takes input and unicasts it to itself, then handles the
    %% message to self by sending a message to G2
    G1Args = [relcast_handler, [Members, input_unicast(1), handle_msg({send, [{unicast, 2, <<"unicast1">>}]})]],
    {ok, G1} = libp2p_swarm:add_group(S1, "test", libp2p_group_relcast, G1Args),
    %% Adding the same group twice is the same group pid
    {ok, G1} = libp2p_swarm:add_group(S1, "test", libp2p_group_relcast, G1Args),

    %% G2 handles any incoming message by sending a message to member
    %% 3 (G3)
    G2Args = [relcast_handler, [Members, undefined, handle_msg({send, [{unicast, 3, <<"unicast2">>}]})]],
    {ok, _G2} = libp2p_swarm:add_group(S2, "test", libp2p_group_relcast, G2Args),

    %% G3 handles a messages by just aknowledging it
    G3Args = [relcast_handler, [Members, undefined, handle_msg(ok)]],
    {ok, _G3} = libp2p_swarm:add_group(S3, "test", libp2p_group_relcast, G3Args),

    %% Give G1 some input. This should end up getting to G2 who then
    %% sends a message to G3.
    libp2p_group_relcast:handle_input(G1, <<"unicast">>),

    %% Receive input message from G1 as handled by G1
    receive
        {handle_msg, 1, <<"unicast">>} -> ok
    after 5000 -> error(timeout)
    end,

    %% Receive message from G1 as handled by G2
    receive
        {handle_msg, 1, <<"unicast1">>} -> ok
    after 5000 -> error(timeout)
    end,

    %% Receive the message from G2 as handled by G3
    receive
        {handle_msg, 2, <<"unicast2">>} -> ok
    after 5000 -> error(timeout)
    end,
    ok.


multicast_test(Config) ->
    Swarms = [S1, S2, S3] = proplists:get_value(swarms, Config),

    test_util:connect_swarms(S1, S2),
    test_util:connect_swarms(S1, S3),

    await_peerbooks(Swarms),

    Members = [libp2p_swarm:address(S) || S <- Swarms],

    %% G1 takes input and broadcasts
    G1Args = [relcast_handler, [Members, input_multicast(), undefined]],
    {ok, G1} = libp2p_swarm:add_group(S1, "test", libp2p_group_relcast, G1Args),

    %% G2 handles a message by acknowledging it
    G2Args = [relcast_handler, [Members, undefined, handle_msg(ok)]],
    {ok, _G2} = libp2p_swarm:add_group(S2, "test", libp2p_group_relcast, G2Args),

    %% G3 handles a messages by aknowledging it
    G3Args = [relcast_handler, [Members, undefined, handle_msg(ok)]],
    {ok, _G3} = libp2p_swarm:add_group(S3, "test", libp2p_group_relcast, G3Args),

    libp2p_group_relcast:handle_input(G1, <<"multicast">>),

    Messages = receive_messages([]),
    %% Messages are delivered at least once
    true = length(Messages) >= 2,

    true = is_map(libp2p_group_relcast:info(G1)),

    ok.


defer_test(Config) ->
    Swarms = [S1, S2] = proplists:get_value(swarms, Config),

    test_util:connect_swarms(S1, S2),

    await_peerbooks(Swarms),

    Members = [libp2p_swarm:address(S) || S <- Swarms],

    %% G1 takes input and unicasts it to G2
    G1Args = [relcast_handler, [Members, input_unicast(2), handle_msg(ok)]],
    {ok, G1} = libp2p_swarm:add_group(S1, "test", libp2p_group_relcast, G1Args),

    %% G2 handles a message by deferring it
    G2Args = [relcast_handler, [Members, input_unicast(1), handle_msg(defer)]],
    {ok, G2} = libp2p_swarm:add_group(S2, "test", libp2p_group_relcast, G2Args),

    libp2p_group_relcast:handle_input(G1, <<"defer">>),

    %% G2 should receive the message at least once from G1 even though it defers it
    [{handle_msg, 1, <<"defer">>} | _] = receive_messages([]),

    %% Then we ack it by telling G2 to ack for G1
    libp2p_group_relcast:handle_ack(G2, 1),

    %% Send a message from G2 to G1
    libp2p_group_relcast:handle_input(G2, <<"defer2">>),

    %% Which G1 should see as a message from G2
    [{handle_msg, 2, <<"defer2">>} | _] = receive_messages([]),

    true = is_map(libp2p_group_relcast:info(G1)),
    ok.


    %% Then we ack

restart_test(_Config) ->
    %% Restarting a relcast group should resend outbound messages that
    %% were not acknowledged, and re-deliver inbould messages to the
    %% handler.
    ok.


%% Utils
%%

input_unicast(Index) ->
    fun(Msg) ->
            {send, [{unicast, Index, Msg}]}
    end.

input_multicast() ->
    fun(Msg) ->
            {send, [{multicast, Msg}]}
    end.

handle_msg(Resp) ->
    Parent = self(),
    fun(Index, Msg) ->
            Parent ! {handle_msg, Index, Msg},
            Resp
    end.

receive_messages(Acc) ->
    receive_messages(Acc, 5000).

receive_messages(Acc, Timeout) ->
    receive
        Msg ->
            receive_messages([Msg | Acc])
    after Timeout ->
            Acc
    end.