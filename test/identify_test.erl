-module(identify_test).

-include_lib("eunit/include/eunit.hrl").

identify_test_() ->
    test_util:foreach([fun identify/1]).

identify([S1, S2]) ->
    [S1Addr|_] = libp2p_swarm:listen_addrs(S1),
    [S2Addr|_] = libp2p_swarm:listen_addrs(S2),

    % identify S2
    {ok, Session} = libp2p_swarm:connect(S1, S2Addr),
    {ok, S2Addr, Identify} = libp2p_identify:identify(Session),
    % check some basic properties
    ?assertEqual("identify/1.0.0", libp2p_identify:protocol_version(Identify)),
    ?assert(lists:member(multiaddr:new(S2Addr), libp2p_identify:listen_addrs(Identify))),
    ?assertMatch(("erlang-libp2p/" ++  _), libp2p_identify:agent_version(Identify)),

    % Compare observed ip addresses and port.
    ?assertEqual(S1Addr, libp2p_identify:observed_addr(Identify)),
    [S1IP,  S1Port] = multiaddr:protocols(multiaddr:new(S1Addr)),
    [ObservedIP, ObservedPort] = multiaddr:protocols(libp2p_identify:observed_maddr(Identify)),
    ?assertEqual(S1IP, ObservedIP),
    ?assertEqual(S1Port, ObservedPort),

    %% Compare stream protocols
    StreamHandlers = lists:sort([Key || {Key, _} <- libp2p_swarm:stream_handlers(S1)]),
    ?assertEqual(StreamHandlers, lists:sort(libp2p_identify:protocols(Identify))),

    ok.
