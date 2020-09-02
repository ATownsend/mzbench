-module(mns_worker).

-export([initial_state/0, metrics/0]).

-export([gk_connect/4, set_options/3, gk_disconnect/2,
    get/3, gk_post/4, put/4, set_prefix/3, mns_register/4]).

-export([
    connect/3,
    disconnect/2,
    publish/5,
    publish/6,
    subscribe/3,
    subscribe/4,
    unsubscribe/3,
    random_client_id/3,
    random_client_ip/3,
    subscribe_to_self/4,
    publish_to_self/5,
    idle/2,
    forward/4,
    publish_to_one/6,
    publish_to_one/7,
    client/2,
    worker_id/2,
    fixed_client_id/4,
    load_client_cert/3,
    load_client_key/3,
    load_cas/3,
    get_cert_bin/1,
    mq_cluster_connect/2,
    mq_cluster_publish_motion/2,
    mq_cluster_publish_guardian/2,
    mq_cluster_publish_heartbeat/2,
    mq_cluster_publish_history/2]).

% gen_mqtt stats callback
-export([stats/2]).

% gen_mqtt callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3,
    on_connect/1,
    on_connect_error/2,
    on_disconnect/1,
    on_subscribe/2,
    on_unsubscribe/2,
    on_publish/3]).

-include_lib("public_key/include/public_key.hrl").

%-record(state, {mqtt_fsm, client}).
-record(mqtt, {action}).

-behaviour(gen_emqtt).
























-type meta() :: [{Key :: atom(), Value :: any()}].
-type http_options() :: list().

-record(state,
    { mqtt_fsm
    , client
    , mqtt_con_status = "F"
    , gk_connection = undefined
    , prefix = "default"
    , http_options = [] :: http_options()
    , network_mac
    , string_mac
    , network_id
    , guardian_id
    , mq_server
    , mq_password
    , mq_type
    }).

-type state() :: #state{}.

-define(TIMED(Name, Expr),
    (fun () ->
        StartTime = os:timestamp(),
        Result = Expr,
        Value = timer:now_diff(os:timestamp(), StartTime),
        mzb_metrics:notify({Name, histogram}, Value),
        Result
    end)()).

-spec initial_state() -> state().
initial_state() ->
    application:set_env(hackney, use_default_pool, false),
    #state{}.

init(State) ->  % init gen_mqtt
    {A,B,C} = os:timestamp(),
    random:seed(A,B,C),
    {ok, State}.

-spec metrics() -> list().
metrics() -> metrics("default").

metrics(Prefix) ->
    [
        {group, "HTTP (" ++ Prefix ++ ")", [
            {graph, #{title => "HTTP Response",
                      units => "N",
                      metrics => [{Prefix ++ ".http_ok", counter},{Prefix ++ ".http_master", counter},{Prefix ++ ".http_secondary", counter}, {Prefix ++ ".http_mns_retry", counter},  {Prefix ++ ".http_fail", counter}, {Prefix ++ ".other_fail", counter}]}},
            {graph, #{title => "HTTP Latency",
                      units => "microseconds",
                      metrics => [{Prefix ++ ".http_latency", histogram}]}},
            {graph, #{title => "MNS Response",
                      units => "N",
                      metrics => [{Prefix ++ ".success", counter},{Prefix ++ ".retry", counter}]}}
        ]},
        {group, "MQTT Pub to Sub Latency", [
            {graph, #{title => "Pub to Sub Latency (QoS 0)", metrics => [{"mqtt.message.pub_to_sub.latency", histogram}]}},
            {graph, #{title => "Pub to Sub Latency (QoS 1)", metrics => [{"mqtt.message.pub_to_sub.latency.qos1", histogram}]}},
            {graph, #{title => "Pub to Sub Latency (QoS 2)", metrics => [{"mqtt.message.pub_to_sub.latency.qos2", histogram}]}}
        ]},
        {group, "MQTT Publishers QoS 1", [
            % QoS 1 Publisher flow
            {graph, #{title => "QoS 1: Publish to Puback latency", metrics => [{"mqtt.publisher.qos1.puback.latency", histogram}]}},
            {graph, #{title => "QoS 1: Pubacks received total", metrics => [{"mqtt.publisher.qos1.puback.in.total", counter}]}},
            {graph, #{title => "QoS 1: Outstanding Pubacks (Waiting Acks)", metrics => [{"mqtt.publisher.qos1.puback.waiting", counter}]}}
        ]},
        {group, "MQTT Publishers QoS 2", [
            % QoS 2 Publisher flow
            {graph, #{title => "QoS 2: Publish to Pubrec_in latency", metrics => [{"mqtt.publisher.qos2.pub_out_to_pubrec_in.latency", histogram}]}},
            {graph, #{title => "QoS 2: Pubrecs received total", metrics => [{"mqtt.publisher.qos2.pubrec.in.total", counter}]}},
            {graph, #{
                title => "QoS 2: Pubrec_in to Pubrel_out internal latency",
                metrics => [{"mqtt.publisher.qos2.pubrec_in_to_pubrel_out.internal_latency", histogram}]
            }},
            {graph, #{
                title => "QoS 2: Pubrel_out to Pubcomp_in latency",
                metrics => [{"mqtt.publisher.qos2.pubrel_out_to_pubcomp_in.latency", histogram}]
            }},
            {graph, #{title => "QoS 2: Outstanding Pubrecs (Waiting Acks)", metrics => [{"mqtt.publisher.qos2.pubrec.waiting", counter}]}},
            {graph, #{title => "QoS 2: Outstanding Pubcomps (Waiting Acks)", metrics => [{"mqtt.publisher.qos2.pubcomp.waiting", counter}]}}
        ]},
        {group, "MQTT Connections", [
            {graph, #{title => "Connack Latency", metrics => [{"mqtt.connection.connack.latency", histogram}]}},
            {graph, #{title => "Total Connections", metrics => [{"mqtt.connection.current_total", counter}]}},
            {graph, #{title => "Total Cluster Connect Success", metrics => [{"mqtt.connection.cluster_total", counter}]}},
            {graph, #{title => "Connection errors", metrics => [{"mqtt.connection.connect.errors", histogram}]}},
            {graph, #{title => "Reconnects", metrics => [{"mqtt.connection.reconnects", counter}]}}
        ]},
        {group, "MQTT Messages", [
            {graph, #{title => "Total published messages", metrics => [{"mqtt.message.published.total", counter}]}},
            {graph, #{title => "Total consumed messages", metrics => [{"mqtt.message.consumed.total", counter}]}}
        ]},
        {group, "MQTT Consumers", [
            {graph, #{title => "Suback Latency", metrics => [{"mqtt.consumer.suback.latency", histogram}]}},
            {graph, #{title => "Unsuback Latency", metrics => [{"mqtt.consumer.unsuback.latency", histogram}]}},
            {graph, #{title => "Consumer Total", metrics => [{"mqtt.consumer.current_total", counter}]}},
            {graph, #{title => "Consumer Suback Errors", metrics => [{"mqtt.consumer.suback.errors", counter}]}},
            % QoS 1 consumer flow
            {graph, #{
                title => "QoS 1: Publish_in to Puback_out internal latency",
                metrics => [{"mqtt.consumer.qos1.publish_in_to_puback_out.internal_latency", histogram}]
            }},
            % QoS 2 consumer flow
            {graph, #{
                title => "QoS 2: Publish_in to Pubrec_out internal latency",
                metrics => [{"mqtt.consumer.qos2.publish_in_to_pubrec_out.internal_latency", histogram}]
            }},
            {graph, #{
                title => "QoS 2: Pubrec_out to Pubrel_in latency",
                metrics => [{"mqtt.consumer.qos2.pubrec_out_to_pubrel_in.latency", histogram}]
            }},
            {graph, #{
                title => "QoS 2: Pubrel_in to Pubcomp_out internal latency",
                metrics => [{"mqtt.consumer.qos2.pubrel_in_to_pubcomp_out.internal_latency", histogram}]
            }}
        ]}
    ].

-spec set_prefix(state(), meta(), string()) -> {nil, state()}.
set_prefix(State, _Meta, NewPrefix) ->
    mzb_metrics:declare_metrics(metrics(NewPrefix)),
    {nil, State#state{prefix = NewPrefix}}.

-spec gk_disconnect(state(), meta()) -> {nil, state()}.
gk_disconnect(#state{gk_connection = GK_connection} = State, _Meta) ->
    hackney:close(GK_connection),
    {nil, State}.

-spec gk_connect(state(), meta(), string() | binary(), integer()) -> {nil, state()}.
gk_connect(State, Meta, Host, Port) when is_list(Host) ->
    gk_connect(State, Meta, list_to_binary(Host), Port);
gk_connect(State, _Meta, Host, Port) ->
    {ok, ConnRef} = hackney:connect(hackney_ssl, Host, Port, []),
    {nil, State#state{gk_connection = ConnRef}}.

-spec set_options(state(), meta(), http_options()) -> {nil, state()}.
set_options(State, _Meta, NewOptions) ->
    {nil, State#state{http_options = NewOptions}}.

-spec get(state(), meta(), string() | binary()) -> {nil, state()}.
get(State, Meta, Endpoint) when is_list(Endpoint) ->
    get(State, Meta, list_to_binary(Endpoint));
get(#state{gk_connection = GK_connection, prefix = Prefix, http_options = Options} = State, _Meta, Endpoint) ->
    Response = ?TIMED(Prefix ++ ".http_latency", hackney:send_request(GK_connection,
        {get, Endpoint, Options, <<>>})),
    {nil, State#state{gk_connection = record_response(Prefix, Response)}}.

-spec gk_post(state(), meta(), string() | binary(), iodata()) -> {nil, state()}.
gk_post(State, Meta, Endpoint, Payload) when is_list(Endpoint) ->
    gk_post(State, Meta, list_to_binary(Endpoint), Payload);
gk_post(#state{gk_connection = GK_connection, prefix = Prefix, http_options = Options} = State, _Meta, Endpoint, Payload) ->
    Response = ?TIMED(Prefix ++ ".http_latency", hackney:send_request(GK_connection,
        {post, Endpoint, Options, Payload})),
    {ok, ResponsePayload} =  hackney:body(GK_connection),
    lager:info("Payload Returned: ~s", [ResponsePayload]),
    RetryCheck = re:run(ResponsePayload, "TRYAGAIN"),
    if
        RetryCheck == nomatch ->
            mzb_metrics:notify({Prefix ++ ".success", counter}, 1);
        true ->
            mzb_metrics:notify({Prefix ++ ".retry", counter}, 1),
            mzb_metrics:notify({Prefix ++ ".http_mns_retry", counter}, 1),
            lager:warning("TRYAGAIN: ~p", [ResponsePayload]),
            timer:sleep(6000),
            {ResponsePayload, State} = gk_post(State, _Meta, Endpoint,  Payload)
    end,
    record_response(Prefix, Response),
    {ResponsePayload, State}.




-spec mns_register(state(), meta(), string(), integer()) -> {nil,state()}.
mns_register(#state{prefix = Prefix} = State, Meta, Endpoint, MacPrefix) ->
    {Big, Medium, Small} = os:timestamp(),
    GKHeaders = [{<<"Content-Type">>, <<"application/json">>}],
    {WorkerId, State} = worker_id(State, Meta),
    StringMacPrefix = io_lib:format("~2..0B~8..0B", [MacPrefix, WorkerId ]),
    FinalMacPrefix = re:replace(StringMacPrefix,"[0-9]{2}", "&:", [global, {return, list}]),
    JsonOutput = io_lib:format("{\"radar_status\": {\"location_id\": \"device-~s00\", \"deviceId\": \"test-~s01\", \"ts\": 0.0, \"interfaces\": [{\"name\": \"wan0\", \"type\": \"ETHERNET\", \"mac\": \"~s01\", \"ip\": \"10.22.22.1\", \"routes\": [{\"dst\": \"0.0.0.0\"}]}], \"links\": [{\"mac\": \"~s10\", \"peer_type\": \"7\"}, {\"mac\": \"~s20\", \"peer_type\": \"7\"}, {\"mac\": \"~s30\", \"peer_type\": \"2\"}], \"ap_bssid_2ghz\": \"~s02\", \"ap_bssid_5ghz\": \"~s03\", \"mesh_bssid\": \"~s00\", \"gateway_bssid\": \"ff:00:00:00:00:00\", \"root_mode\": 2}, \"factory_reset\": \"False\", \"master_failed\": \"False\"}", [StringMacPrefix, StringMacPrefix, FinalMacPrefix, FinalMacPrefix, FinalMacPrefix, FinalMacPrefix, FinalMacPrefix, FinalMacPrefix, FinalMacPrefix]),
    %gk_connect( #state{gk_connection = GK_connection} = State, Meta,"mns.load.qa.wifimotion.ca", 443),
    set_options(State, Meta, GKHeaders),
    %Payload = <<"potato">>,
    Path = <<"/gatekeeper">>,
    {ResponseBody, State} = gk_post(State, Meta, Path,  JsonOutput),
    mzb_metrics:notify({Prefix ++ ".http_master", counter}, 1),
    MQUsername = <<"device">>,
    {match,NetworkId}=re:run(ResponseBody, "network_id\":([0-9]*)", [{capture, all_but_first, list}]),
    {match,GuardianId}=re:run(ResponseBody, "guardian_mqtt.*guardian_id\":\"([^\"]*)", [{capture, all_but_first, list}]),
    {match,MQServer}=re:run(ResponseBody, "guardian_mqtt.*mqServer\":\"([^\"]*)", [{capture, all_but_first, list}]),
    {match,MQPassword}=re:run(ResponseBody, "guardian_mqtt.*mqToken\":\"([^\"]*)", [{capture, all_but_first, list}]),
    {match,MQType}=re:run(ResponseBody, "guardian_mqtt.*mqType\":\"([^\"]*)", [{capture, all_but_first, list}]),
    %Sleep is required so that there's no race condition
    %lager:info("ID's Guardian: ~p NetworkId: ~p Mac String: ~p Mac: ~p MQ: ~p", [GuardianId,NetworkId, StringMacPrefix, FinalMacPrefix,MQServer]),
    JsonDevice2 = io_lib:format("{\"radar_status\": {\"deviceId\": \"test-~s11\", \"ts\": 0.0, \"interfaces\": [{\"name\": \"wan0\", \"type\": \"BRIDGE\", \"mac\": \"~s11\", \"ip\": \"10.22.22.1\", \"routes\": [{\"dst\": \"0.0.0.0\"}]}], \"links\": [{\"mac\": \"~s00\", \"peer_type\": \"7\"}, {\"mac\": \"~s20\", \"peer_type\": \"7\"}, {\"mac\": \"~s30\", \"peer_type\": \"2\"}], \"ap_bssid_2ghz\": \"~s12\", \"ap_bssid_5ghz\": \"~s13\", \"mesh_bssid\": \"~s20\", \"gateway_bssid\": \"01:00:01:00:01:00\", \"root_mode\": 1}, \"factory_reset\": \"False\", \"master_failed\": \"False\", \"location_id\": \"device-~s00\"}", [StringMacPrefix, FinalMacPrefix, FinalMacPrefix, FinalMacPrefix, FinalMacPrefix, FinalMacPrefix, FinalMacPrefix, FinalMacPrefix, StringMacPrefix]),
    {SecondResponseBody, State} = gk_post(State, Meta, Path,  JsonDevice2),
    mzb_metrics:notify({Prefix ++ ".http_secondary", counter}, 1),
    JsonDevice3 = io_lib:format("{\"radar_status\": {\"deviceId\": \"test-~s21\", \"ts\": 0.0, \"interfaces\": [{\"name\": \"wan0\", \"type\": \"BRIDGE\", \"mac\": \"~s21\", \"ip\": \"10.22.22.1\", \"routes\": [{\"dst\": \"0.0.0.0\"}]}], \"links\": [{\"mac\": \"~s00\", \"peer_type\": \"7\"}, {\"mac\": \"~s20\", \"peer_type\": \"7\"}, {\"mac\": \"~s30\", \"peer_type\": \"2\"}], \"ap_bssid_2ghz\": \"~s22\", \"ap_bssid_5ghz\": \"~s23\", \"mesh_bssid\": \"~s30\", \"gateway_bssid\": \"01:00:01:00:01:00\", \"root_mode\": 1}, \"factory_reset\": \"False\", \"master_failed\": \"False\", \"location_id\": \"device-~s00\"}", [StringMacPrefix, FinalMacPrefix, FinalMacPrefix, FinalMacPrefix, FinalMacPrefix, FinalMacPrefix, FinalMacPrefix, FinalMacPrefix, StringMacPrefix]),
    {ThirdResponseBody, State} = gk_post(State, Meta, Path,  JsonDevice3),
    mzb_metrics:notify({Prefix ++ ".http_secondary", counter}, 1),
    {nil, State#state{network_mac = FinalMacPrefix, string_mac = StringMacPrefix, network_id = lists:concat(NetworkId), guardian_id = lists:concat(GuardianId), mq_server = lists:concat(MQServer), mq_password = lists:concat(MQPassword), mq_type = lists:concat(MQType)}}.
    
-spec put(state(), meta(), string() | binary(), iodata()) -> {nil, state()}.
put(State, Meta, Endpoint, Payload) when is_list(Endpoint) ->
    put(State, Meta, list_to_binary(Endpoint), Payload);
put(#state{gk_connection = GK_connection, prefix = Prefix, http_options = Options} = State, _Meta, Endpoint, Payload) ->
    Response = ?TIMED(Prefix ++ ".http_latency", hackney:send_request(GK_connection,
        {put, Endpoint, Options, Payload})),
    {nil, State#state{gk_connection = record_response(Prefix, Response)}}.

record_response(Prefix, Response) ->
    case Response of
        {ok, 200, _, GK_connection} ->
            %{ok, Body} = hackney:body(GK_connection),
            mzb_metrics:notify({Prefix ++ ".http_ok", counter}, 1),
            GK_connection;
        {ok, _, _, GK_connection} ->
            %{ok, Body} = hackney:body(GK_connection),
            %lager:error("hackney:response fail: ~p", [Body]),
            %lager:error("hackney: failed: ~p", [E]),
            mzb_metrics:notify({Prefix ++ ".http_fail", counter}, 1),
            GK_connection;
        E ->
            lager:error("hackney:request failed: ~p", [E]),
            mzb_metrics:notify({Prefix ++ ".other_fail", counter}, 1)
    end.

-spec mq_cluster_connect(state(), meta() ) -> {nil, state()}.
mq_cluster_connect(#state{network_mac = FinalMacPrefix, network_id = NetworkId, guardian_id = GuardianId, mq_server = MQServer, mq_password = MQPassword } = State, Meta)->
    lager:warning("MetaData: ~p", [Meta]),
    {WorkerId, State} = worker_id(State, Meta),
    {ClientId, State} = fixed_client_id(State, Meta, "pool1", WorkerId),
    {Something, NewState} = connect(State, Meta, [{host,  MQServer},
            {port , 1883},
            {username ,  "device"},
            {password , MQPassword},
            {client , GuardianId},
            {clean_session,true},
            {keepalive_interval , 60},
            {proto_version , 4},
            {reconnect_timeout,10}
            ]),
    MqPid = element(2,NewState),
    lager:warning("MQTTPID: ~p", [MqPid]),
    mzb_metrics:notify({"mqtt.connection.cluster_total", counter}, 1),
    register("Mqtt", MqPid),
    %#state.mqtt_fsm=SessionPid, client=ClientId}}
    {nil, NewState}.

-spec mq_cluster_publish_motion(state(), meta()) -> {nil, state()}.
mq_cluster_publish_motion(#state{network_mac = MacPrefix, string_mac = StringMacPrefix, guardian_id = GuardianId, network_id = NetworkID, mq_type = MQType } = State, Meta) ->
    SysId = re:replace(StringMacPrefix,"^.{6}", "", [{return, list}]),
    {BigTime, MediumTime, SmallTime} = os:timestamp(),
    Timestamp = io_lib:format("~4..0B~6..0B", [BigTime, MediumTime ]),
    PublishLocation = io_lib:format("iot-2/type/~s/id/~s/evt/motion-matrix/fmt/json",[MQType, GuardianId]),
    
    %MotionMatrix
    MQmessage = io_lib:format("{\"ts\": 946684865, \"interval\": 500, \"count\": 60,\"motion\": {\"mkai\": [[0.7, 0.6, 0.5, 0.5, 0.4, 0.3, 0.6, 0.2, 0.8, 0.3, 0.6, 0.6, 0.2, 0.6, 0.2, 0.1, 0.0, 0.5, 0.8, 0.3, 0.9, 0.0, 0.0, 0.9, 0.0, 0.0, 0.3, 0.5, 0.7, 0.5, 0.8, 0.3, 0.8, 0.3, 0.7, 0.8, 0.9, 0.6, 0.6, 0.8, 0.2, 0.1, 0.5, 0.6, 0.8, 0.2, 0.0, 0.5, 0.1, 0.8, 0.0, 0.8, 0.4, 0.9, 0.3, 0.0, 0.6, 0.1, 0.9, 0.0], [0.7, 0.3, 0.8, 0.1, 0.4, 0.2, 0.8, 0.0, 0.0, 0.5, 0.8, 0.2, 0.1, 0.3, 0.2, 0.1, 0.0, 0.4, 0.9, 0.2, 0.2, 0.1, 0.1, 0.3, 0.2, 0.3, 0.6, 0.3, 0.0, 0.0, 0.5, 0.1, 0.6, 0.3, 0.8, 0.1, 0.1, 0.6, 0.5, 0.0, 0.7, 0.7, 0.3, 0.7, 0.8, 0.4, 0.2, 0.4, 0.3, 0.8, 0.2, 0.7, 0.6, 0.5, 0.6, 0.0, 0.0, 0.9, 0.8, 0.6], [0.4, 0.3, 0.8, 0.2, 0.6, 0.7, 0.8, 0.9, 0.4, 0.0, 0.7, 0.9, 0.3, 0.5, 0.8, 0.2, 0.1, 0.1, 0.2, 0.0, 0.4, 0.4, 0.0, 0.0, 0.0, 0.1, 0.3, 0.9, 0.5, 0.3, 0.1, 0.9, 0.3, 0.4, 0.1, 0.1, 0.0, 0.2, 0.9, 0.4, 0.0, 0.4, 0.5, 0.7, 0.3, 0.2, 0.6, 0.7, 0.7, 0.8, 0.5, 0.4, 0.7, 0.2, 0.2, 0.7, 0.6, 0.8, 0.6, 0.1], [0.9, 0.7, 0.1, 0.6, 0.7, 0.7, 0.8, 0.3, 0.1, 0.1, 0.6, 0.6, 0.2, 0.9, 0.6, 0.5, 0.8, 0.6, 0.8, 0.0, 0.1, 0.2, 0.6, 0.0, 0.5, 0.4, 0.2, 0.2, 0.0, 0.4, 0.8, 0.1, 0.6, 0.8, 0.4, 0.7, 0.8, 0.6, 0.8, 0.9, 0.8, 0.8, 0.7, 0.8, 0.3, 0.6, 0.2, 0.4, 0.8, 0.6, 0.4, 0.3, 0.4, 0.3, 0.6, 0.9, 0.4, 0.6, 0.2, 0.5], [0.1, 0.7, 0.8, 0.5, 0.0, 0.3, 0.4, 0.8, 0.1, 0.4, 0.2, 0.9, 0.4, 0.7, 0.2, 0.6, 0.6, 0.6, 0.3, 0.9, 0.8, 0.0, 0.7, 0.7, 0.4, 0.6, 0.0, 0.9, 0.5, 0.9, 0.3, 0.5, 0.4, 0.6, 0.1, 0.4, 0.0, 0.8, 0.5, 0.2, 0.1, 0.6, 0.5, 0.5, 0.1, 0.6, 0.1, 0.3, 0.9, 0.9, 0.6, 0.6, 0.5, 0.5, 0.9, 0.8, 0.4, 0.3, 0.1, 0.0], [0.9, 0.6, 0.2, 0.2, 0.0, 0.9, 0.4, 0.9, 0.0, 0.1, 0.0, 0.8, 0.3, 0.9, 0.1, 0.7, 0.1, 0.0, 0.1, 0.8, 0.2, 0.2, 0.7, 0.4, 0.0, 0.5, 0.6, 0.3, 0.2, 0.4, 0.8, 0.1, 0.7, 0.9, 0.4, 0.7, 0.4, 0.5, 0.4, 0.8, 0.8, 0.4, 0.7, 0.2, 0.0, 0.7, 0.0, 0.5, 0.1, 0.5, 0.6, 0.0, 0.4, 0.8, 0.7, 0.1, 0.3, 0.8, 0.9, 0.3], [0.5, 0.0, 0.2, 0.5, 0.6, 0.5, 0.6, 0.8, 0.5, 0.1, 0.0, 0.3, 0.1, 0.5, 0.8, 0.0, 0.7, 0.4, 0.4, 0.6, 0.4, 0.7, 0.8, 0.1, 0.8, 0.5, 0.8, 0.5, 0.4, 0.1, 0.9, 0.1, 0.5, 0.7, 0.5, 0.9, 0.0, 0.2, 0.9, 0.4, 0.1, 0.1, 0.6, 0.5, 0.5, 0.2, 0.6, 0.3, 0.8, 0.3, 0.0, 0.2, 0.6, 0.2, 0.2, 0.6, 0.7, 0.1, 0.2, 0.6], [0.1, 0.3, 0.2, 0.3, 0.4, 0.3, 0.5, 0.5, 0.8, 0.0, 0.6, 0.2, 0.4, 0.0, 0.1, 0.1, 0.2, 0.6, 0.8, 0.1, 0.1, 0.9, 0.0, 0.4, 0.2, 0.5, 0.3, 0.8, 0.8, 0.6, 0.9, 0.0, 0.8, 0.4, 0.1, 0.3, 0.9, 0.2, 0.1, 0.5, 0.1, 0.8, 0.0, 0.8, 0.6, 0.3, 0.1, 0.1, 0.9, 0.9, 0.5, 0.2, 0.7, 0.5, 0.1, 0.2, 0.8, 0.8, 0.8, 0.9], [0.3, 0.8, 0.1, 0.9, 0.6, 0.9, 0.7, 0.5, 0.8, 0.1, 0.9, 0.1, 0.7, 0.0, 0.6, 0.6, 0.8, 0.1, 0.5, 0.6, 0.7, 0.1, 0.8, 0.3, 0.5, 0.9, 0.1, 0.1, 0.0, 0.0, 0.1, 0.3, 0.6, 0.5, 0.2, 0.4, 0.1, 0.7, 0.2, 0.3, 0.1, 0.7, 0.5, 0.1, 0.4, 0.4, 0.7, 0.1, 0.0, 0.2, 0.3, 0.3, 0.9, 0.8, 0.1, 0.1, 0.2, 0.4, 0.4, 0.9], [0.5, 0.3, 0.7, 0.5, 0.1, 0.4, 0.9, 0.8, 0.2, 0.5, 0.6, 0.0, 0.2, 0.5, 0.1, 0.7, 0.0, 0.0, 0.3, 0.9, 0.0, 0.0, 0.5, 0.8, 0.5, 0.0, 0.5, 0.7, 0.1, 0.2, 0.7, 0.0, 0.7, 0.0, 0.5, 0.5, 0.4, 0.4, 0.4, 0.7, 0.9, 0.0, 0.0, 0.1, 0.8, 0.9, 0.1, 0.2, 0.1, 0.3, 0.3, 0.1, 0.6, 0.5, 0.3, 0.2, 0.9, 0.4, 0.5, 0.2], [0.3, 0.0, 0.7, 0.3, 0.6, 0.8, 0.3, 0.9, 0.6, 0.5, 0.4, 0.9, 0.9, 0.2, 0.6, 0.1, 0.0, 0.5, 0.5, 0.9, 0.3, 0.2, 0.9, 0.4, 0.7, 0.5, 0.2, 0.4, 0.3, 0.6, 0.7, 0.7, 0.8, 0.7, 0.1, 0.9, 0.2, 0.6, 0.8, 0.1, 0.3, 0.6, 0.0, 0.6, 0.2, 0.3, 0.6, 0.3, 0.4, 0.5, 0.5, 0.8, 0.1, 0.9, 0.3, 0.7, 0.9, 0.0, 0.5, 0.8], [0.6, 0.8, 0.1, 0.3, 0.5, 0.2, 0.1, 0.8, 0.0, 0.8, 0.6, 0.8, 0.7, 0.9, 0.7, 0.4, 0.5, 0.9, 0.7, 0.0, 0.9, 0.7, 0.2, 0.9, 0.6, 0.3, 0.9, 0.2, 0.8, 0.2, 0.4, 0.0, 0.3, 0.1, 0.3, 0.2, 0.4, 0.4, 0.1, 0.6, 0.9, 0.4, 0.2, 0.9, 0.2, 0.6, 0.0, 0.1, 0.8, 0.1, 0.1, 0.7, 0.8, 0.9, 0.9, 0.8, 0.7, 0.5, 0.7, 0.9], [0.3, 0.4, 0.9, 0.5, 0.2, 0.1, 0.5, 0.9, 0.9, 0.9, 0.1, 0.0, 0.1, 0.2, 0.8, 0.2, 0.5, 0.7, 0.6, 0.5, 0.0, 0.7, 0.3, 0.8, 0.3, 0.4, 0.6, 0.6, 0.4, 0.8, 0.0, 0.0, 0.6, 0.3, 0.1, 0.1, 0.9, 0.7, 0.9, 0.5, 0.0, 0.7, 0.4, 0.1, 0.1, 0.7, 0.5, 0.4, 0.5, 0.1, 0.1, 0.5, 0.1, 0.6, 0.8, 0.8, 0.4, 0.7, 0.1, 0.5], [0.8, 0.0, 0.7, 0.6, 0.2, 0.7, 0.8, 0.0, 0.6, 0.8, 0.6, 0.1, 0.7, 0.2, 0.7, 0.7, 0.6, 0.8, 0.7, 0.6, 0.8, 0.9, 0.0, 0.4, 0.3, 0.2, 0.3, 0.0, 0.8, 0.1, 0.0, 0.0, 0.1, 0.7, 0.0, 0.1, 0.3, 0.0, 0.1, 0.9, 0.3, 0.3, 0.9, 0.4, 0.6, 0.6, 0.6, 0.4, 0.6, 0.2, 0.4, 0.4, 0.7, 0.7, 0.4, 0.5, 0.1, 0.8, 0.4, 0.7], [0.4, 0.5, 0.3, 0.6, 0.1, 0.0, 0.7, 0.8, 0.3, 0.2, 0.1, 0.4, 0.7, 0.6, 0.3, 0.9, 0.0, 0.5, 0.4, 0.1, 0.2, 0.7, 0.3, 0.5, 0.9, 0.4, 0.0, 0.7, 0.5, 0.9, 0.2, 0.6, 0.3, 0.6, 0.6, 0.4, 0.0, 0.4, 0.3, 0.0, 0.5, 0.8, 0.3, 0.6, 0.1, 0.9, 0.0, 0.9, 0.6, 0.4, 0.4, 0.1, 0.1, 0.1, 0.9, 0.5, 0.0, 0.4, 0.4, 0.3]], \"throughput\": [[0.3, 0.3, 0.7, 0.4, 0.1, 0.0, 0.8, 0.3, 0.5, 0.3, 0.5, 0.7, 0.2, 0.5, 0.8, 0.7, 0.5, 0.1, 0.1, 0.1, 0.9, 0.6, 0.2, 0.2, 0.6, 0.2, 0.2, 0.1, 0.2, 0.9, 0.8, 0.7, 0.8, 0.6, 0.8, 0.2, 0.8, 0.8, 0.7, 0.1, 0.1, 0.1, 0.5, 0.3, 0.8, 0.8, 0.9, 0.7, 0.0, 0.4, 0.9, 0.4, 0.1, 0.3, 0.1, 0.7, 0.8, 0.7, 0.9, 0.7], [0.1, 0.7, 0.3, 0.8, 0.7, 0.6, 0.8, 0.2, 0.8, 0.0, 0.6, 0.2, 0.8, 0.6, 0.5, 0.2, 0.6, 0.3, 0.2, 0.3, 0.5, 0.3, 0.7, 0.4, 0.9, 0.1, 0.1, 0.1, 0.5, 0.5, 0.4, 0.7, 0.3, 0.9, 0.2, 0.0, 0.4, 0.3, 0.8, 0.0, 0.2, 0.3, 0.4, 0.2, 0.7, 0.8, 0.2, 0.0, 0.9, 0.9, 0.3, 0.4, 0.4, 0.2, 0.9, 0.4, 0.3, 0.8, 0.2, 0.3], [0.3, 0.8, 0.4, 0.9, 0.7, 0.5, 0.6, 0.1, 0.4, 0.9, 0.0, 0.3, 0.6, 0.8, 0.3, 0.8, 0.2, 0.7, 0.6, 0.8, 0.4, 0.5, 0.8, 0.1, 0.6, 0.3, 0.2, 0.1, 0.3, 0.6, 0.5, 0.1, 0.7, 0.4, 0.7, 0.0, 0.5, 0.7, 0.5, 0.4, 0.1, 0.4, 0.4, 0.7, 0.8, 0.9, 0.0, 0.2, 0.7, 0.2, 0.0, 0.1, 0.5, 0.8, 0.4, 0.5, 0.1, 0.4, 0.8, 0.5], [0.5, 0.9, 0.3, 0.1, 0.5, 0.2, 0.2, 0.7, 0.9, 0.3, 0.0, 0.1, 0.0, 0.5, 0.7, 0.2, 0.2, 0.9, 0.3, 0.9, 0.0, 0.5, 0.2, 0.9, 0.1, 0.8, 0.5, 0.9, 0.0, 0.0, 0.0, 0.8, 0.8, 0.5, 0.8, 0.2, 0.5, 0.9, 0.9, 0.6, 0.6, 0.9, 0.4, 0.0, 0.0, 0.7, 0.7, 0.5, 0.2, 0.9, 0.6, 0.5, 0.4, 0.5, 0.5, 0.1, 0.7, 0.5, 0.6, 0.2], [0.2, 0.4, 0.6, 0.5, 0.7, 0.6, 0.0, 0.8, 0.4, 0.3, 0.3, 0.8, 0.5, 0.4, 0.9, 0.7, 0.6, 0.5, 0.9, 0.8, 0.1, 0.4, 0.8, 0.5, 0.4, 0.2, 0.9, 0.1, 0.8, 0.0, 0.9, 0.2, 0.3, 0.0, 0.4, 0.4, 0.7, 0.4, 0.9, 0.5, 0.9, 0.9, 0.6, 0.6, 0.8, 0.3, 0.2, 0.6, 0.6, 0.8, 0.9, 0.9, 0.2, 0.3, 0.1, 0.1, 0.6, 0.9, 0.1, 0.1], [0.2, 0.0, 0.4, 0.3, 0.6, 0.8, 0.4, 0.2, 0.4, 0.6, 0.4, 0.7, 0.2, 0.5, 0.3, 0.3, 0.0, 0.5, 0.8, 0.9, 0.8, 0.1, 0.6, 0.8, 0.2, 0.0, 0.9, 0.4, 0.0, 0.1, 0.3, 0.2, 0.0, 0.1, 0.7, 0.9, 0.8, 0.7, 0.1, 0.1, 0.3, 0.1, 0.4, 0.1, 0.1, 0.4, 0.6, 0.8, 0.8, 0.6, 0.2, 0.1, 0.2, 0.5, 0.5, 0.8, 0.6, 0.8, 0.3, 0.5], [0.3, 0.4, 0.3, 0.6, 0.8, 0.7, 0.7, 0.8, 0.6, 0.7, 0.7, 0.2, 0.0, 0.8, 0.0, 0.6, 0.5, 0.1, 0.7, 0.1, 0.2, 0.9, 0.8, 0.3, 0.5, 0.7, 0.3, 0.6, 0.2, 0.9, 0.5, 0.8, 0.2, 0.1, 0.3, 0.7, 0.5, 0.8, 0.9, 0.1, 0.2, 0.2, 0.4, 0.4, 0.3, 0.5, 0.5, 0.7, 0.6, 0.5, 0.7, 0.8, 0.2, 0.0, 0.9, 0.8, 0.4, 0.7, 0.3, 0.2], [0.3, 0.3, 0.6, 0.8, 0.7, 0.8, 0.5, 0.4, 0.3, 0.1, 0.7, 0.8, 0.5, 0.3, 0.7, 0.0, 0.7, 0.5, 0.5, 0.9, 0.5, 0.8, 0.0, 0.5, 0.5, 0.7, 0.1, 0.4, 0.6, 0.3, 0.9, 0.8, 0.4, 0.2, 0.7, 0.4, 0.3, 0.9, 0.9, 0.2, 0.2, 0.2, 0.3, 0.1, 0.4, 0.4, 0.9, 0.2, 0.2, 0.4, 0.7, 0.5, 0.9, 0.1, 0.8, 0.6, 0.7, 0.0, 0.1, 0.8], [0.5, 0.4, 0.4, 0.8, 0.7, 0.7, 0.8, 0.9, 0.2, 0.3, 0.4, 0.8, 0.1, 0.5, 0.4, 0.3, 0.2, 0.5, 0.5, 0.5, 0.1, 0.8, 0.0, 0.7, 0.5, 0.2, 0.6, 0.8, 0.0, 0.7, 0.2, 0.8, 0.7, 0.5, 0.4, 0.8, 0.4, 0.0, 0.7, 0.4, 0.1, 0.9, 0.7, 0.2, 0.0, 0.9, 0.4, 0.3, 0.2, 0.8, 0.4, 0.2, 0.1, 0.2, 0.8, 0.4, 0.7, 0.1, 0.4, 0.8], [0.8, 0.9, 0.0, 0.4, 0.8, 0.2, 0.7, 0.8, 0.7, 0.9, 0.3, 0.6, 0.9, 0.9, 0.9, 0.9, 0.6, 0.9, 0.7, 0.4, 0.9, 0.2, 0.6, 0.0, 0.2, 0.4, 0.9, 0.4, 0.8, 0.0, 0.2, 0.7, 0.8, 0.8, 0.3, 0.9, 0.4, 0.4, 0.0, 0.4, 0.4, 0.5, 0.6, 0.2, 0.8, 0.7, 0.7, 0.4, 0.7, 0.1, 0.8, 0.3, 0.2, 0.4, 0.0, 0.8, 0.8, 0.2, 0.6, 0.0], [0.4, 0.4, 0.0, 0.6, 0.5, 0.3, 0.9, 0.5, 0.5, 0.0, 0.0, 0.1, 0.6, 0.6, 0.1, 0.2, 0.5, 0.2, 0.3, 0.8, 0.7, 0.6, 0.3, 0.9, 0.5, 0.6, 0.5, 0.4, 0.7, 0.1, 0.6, 0.7, 0.4, 0.5, 0.8, 0.6, 0.9, 0.4, 0.9, 0.9, 0.1, 0.8, 0.6, 0.2, 0.1, 0.3, 0.2, 0.7, 0.6, 0.4, 0.3, 0.3, 0.9, 0.9, 0.4, 0.4, 0.0, 0.0, 0.9, 0.4], [0.9, 0.3, 0.4, 0.0, 0.6, 0.5, 0.7, 0.6, 0.8, 0.7, 0.9, 0.0, 0.5, 0.5, 0.0, 0.0, 0.2, 0.4, 0.4, 0.0, 0.8, 0.9, 0.8, 0.3, 0.9, 0.6, 0.0, 0.4, 0.3, 0.8, 0.2, 0.6, 0.1, 0.7, 0.5, 0.2, 0.5, 0.4, 0.5, 0.7, 0.5, 0.1, 0.3, 0.0, 0.2, 0.9, 0.8, 0.1, 0.9, 0.1, 0.0, 0.0, 0.2, 0.5, 0.6, 0.7, 0.9, 0.0, 0.4, 0.5], [0.7, 0.0, 0.0, 0.4, 0.4, 0.7, 0.8, 0.5, 0.8, 0.5, 0.8, 0.5, 0.4, 0.0, 0.7, 0.8, 0.0, 0.3, 0.0, 0.1, 0.2, 0.6, 0.6, 0.6, 0.6, 0.9, 0.6, 0.3, 0.0, 0.5, 0.2, 0.9, 0.1, 0.3, 0.1, 0.5, 0.2, 0.5, 0.6, 0.6, 0.7, 0.5, 0.9, 0.6, 0.6, 0.8, 0.3, 0.9, 0.0, 0.7, 0.0, 0.9, 0.9, 0.4, 0.8, 0.8, 0.7, 0.9, 0.4, 0.3], [0.4, 0.8, 0.9, 0.3, 0.6, 0.2, 0.0, 0.2, 0.8, 0.1, 0.4, 0.3, 0.1, 0.1, 0.6, 0.4, 0.9, 0.5, 0.3, 0.0, 0.6, 0.4, 0.9, 0.5, 0.7, 0.3, 0.0, 0.5, 0.6, 0.3, 0.8, 0.7, 0.3, 0.4, 0.8, 0.6, 0.7, 0.7, 0.6, 0.3, 0.5, 0.9, 0.9, 0.5, 0.3, 0.6, 0.5, 0.3, 0.0, 0.7, 0.2, 0.2, 0.9, 0.2, 0.0, 0.7, 0.5, 0.1, 0.7, 0.0], [0.9, 0.3, 0.0, 0.0, 0.8, 0.3, 0.5, 0.0, 0.2, 0.8, 0.5, 0.7, 0.7, 0.5, 0.6, 0.3, 0.1, 0.3, 0.2, 0.2, 0.6, 0.0, 0.5, 0.1, 0.8, 0.9, 0.8, 0.4, 0.7, 0.2, 0.0, 0.3, 0.2, 0.9, 0.9, 0.6, 0.3, 0.4, 0.8, 0.6, 0.8, 0.1, 0.2, 0.2, 0.9, 0.8, 0.3, 0.4, 0.4, 0.8, 0.7, 0.6, 0.2, 0.1, 0.9, 0.7, 0.6, 0.9, 0.1, 0.4]]},\"links\": [\"~s00-~s10\", \"~s00-~s20\", \"~s00-~s30\", \"~s00-~s40\", \"~s00-~s50\", \"~s10-~s20\", \"~s10-~s30\", \"~s10-~s40\", \"~s10-~s50\", \"~s20-~s30\", \"~s20-~s40\", \"~s20-~s50\", \"~s30-~s40\", \"~s30-~s50\", \"~s40-~s50\"]}", [SysId,SysId,SysId,SysId,SysId,SysId,SysId,SysId,SysId,SysId,SysId,SysId,SysId,SysId,SysId,SysId,SysId,SysId,SysId,SysId,SysId,SysId,SysId,SysId,SysId,SysId,SysId,SysId,SysId,SysId]),
    publish(State, Meta, PublishLocation, MQmessage, 0),
    {nil,State}.

-spec mq_cluster_publish_guardian(state(), meta()) -> {nil, state()}.
mq_cluster_publish_guardian(#state{network_mac = MacPrefix, string_mac = StringMacPrefix, guardian_id = GuardianId, network_id = NetworkID, mq_type = MQType } = State, Meta) ->
    SysId = re:replace(StringMacPrefix,"^.{6}", "", [{return, list}]),
    {BigTime, MediumTime, SmallTime} = os:timestamp(),
    Timestamp = io_lib:format("~4..0B~6..0B", [BigTime, MediumTime ]),
    PublishLocation = io_lib:format("iot-2/type/~s/id/~s/evt/guardian-status/fmt/json",[MQType, GuardianId]),
    
    %Guardian
    %MQmessage = <<"{'ts': #time#, 'guardian_id': '#guardian#', 'network_id': #network#, 'radars': [{'deviceId': 'test-#sys#01', 'ts': 0.0, 'interfaces': [{'name': 'wan0', 'type': 'ETHERNET', 'mac': '#mac#01', 'ip': '10.22.22.1', 'routes': [{'dst': '0.0.0.0'}]}], 'links': [{'mac': '#mac#10', 'peer_type': '7'}, {'mac': '#mac#20', 'peer_type': '7'}, {'mac': '#mac#30', 'peer_type': '2'}], 'ap_bssid_2ghz': '#mac#02', 'ap_bssid_5ghz': '#mac#03', 'mesh_bssid': '#mac#00', 'gateway_bssid': 'ff:00:00:00:00:00', 'root_mode': 2}, {'deviceId': 'test-#sys#11', 'ts': 0.0, 'interfaces': [{'name': 'wan0', 'type': 'BRIDGE', 'mac': '#mac#11', 'ip': '10.22.22.1', 'routes': [{'dst': '0.0.0.0'}]}], 'links': [{'mac': '#mac#00', 'peer_type': '7'}, {'mac': '#mac#20', 'peer_type': '7'}, {'mac': '#mac#40', 'peer_type': '2'}], 'ap_bssid_2ghz': '#mac#12', 'ap_bssid_5ghz': '#mac#13', 'mesh_bssid': '#mac#10', 'gateway_bssid': '#mac#00', 'root_mode': 1}, {'deviceId': 'test-#sys#21', 'ts': 0.0, 'interfaces': [{'name': 'wan0', 'type': 'BRIDGE', 'mac': '#mac#21', 'ip': '10.22.22.1', 'routes': [{'dst': '0.0.0.0'}]}], 'links': [{'mac': '#mac#00', 'peer_type': '7'}, {'mac': '#mac#10', 'peer_type': '7'}, {'mac': '#mac#50', 'peer_type': '2'}], 'ap_bssid_2ghz': '#mac#22', 'ap_bssid_5ghz': '#mac#23', 'mesh_bssid': '#mac#20', 'gateway_bssid': '#mac#00', 'root_mode': 1}], 'last_motion': 946685095}">>,
    MQmessage = io_lib:format(<<"{\"ts\": ~s, \"guardian_id\": \"~s01\", \"network_id\": ~s, \"radars\": {\"test-~s01\": { \"ts\": 0.0, \"interfaces\": [{\"name\": \"wan0\", \"type\": \"ETHERNET\", \"mac\": \"~s01\", \"ip\": \"10.22.22.1\", \"routes\": [{\"dst\": \"0.0.0.0\"}]}], \"links\": [{\"mac\": \"~s10\", \"peer_type\": \"7\"}, {\"mac\": \"~s20\", \"peer_type\": \"7\"}, {\"mac\": \"~s30\", \"peer_type\": \"2\"}], \"ap_bssid_2ghz\": \"~s02\", \"ap_bssid_5ghz\": \"~s03\", \"mesh_bssid\": \"~s00\", \"gateway_bssid\": \"ff:00:00:00:00:00\", \"root_mode\": 2}, \"test-~s11\":{ \"ts\": 0.0, \"interfaces\": [{\"name\": \"wan0\", \"type\": \"BRIDGE\", \"mac\": \"~s11\", \"ip\": \"10.22.22.1\", \"routes\": [{\"dst\": \"0.0.0.0\"}]}], \"links\": [{\"mac\": \"~s00\", \"peer_type\": \"7\"}, {\"mac\": \"~s20\", \"peer_type\": \"7\"}, {\"mac\": \"~s40\", \"peer_type\": \"2\"}], \"ap_bssid_2ghz\": \"~s12\", \"ap_bssid_5ghz\": \"~s13\", \"mesh_bssid\": \"~s10\", \"gateway_bssid\": \"~s00\", \"root_mode\": 1}, \"test-~s21\": {\"ts\": 0.0, \"interfaces\": [{\"name\": \"wan0\", \"type\": \"BRIDGE\", \"mac\": \"~s21\", \"ip\": \"10.22.22.1\", \"routes\": [{\"dst\": \"0.0.0.0\"}]}], \"links\": [{\"mac\": \"~s00\", \"peer_type\": \"7\"}, {\"mac\": \"~s10\", \"peer_type\": \"7\"}, {\"mac\": \"~s50\", \"peer_type\": \"2\"}], \"ap_bssid_2ghz\": \"~s22\", \"ap_bssid_5ghz\": \"~s23\", \"mesh_bssid\": \"~s20\", \"gateway_bssid\": \"~s00\", \"root_mode\": 1}}, \"last_motion\": 946685095}">>,[Timestamp,GuardianId,NetworkID,StringMacPrefix,MacPrefix,MacPrefix,MacPrefix,MacPrefix,MacPrefix,MacPrefix,MacPrefix,StringMacPrefix,MacPrefix,MacPrefix,MacPrefix,MacPrefix,MacPrefix,MacPrefix,MacPrefix,MacPrefix,StringMacPrefix,MacPrefix,MacPrefix,MacPrefix,MacPrefix,MacPrefix,MacPrefix,MacPrefix,MacPrefix]),
    
    publish(State, Meta, PublishLocation, MQmessage, 0),
    {nil,State}.

-spec mq_cluster_publish_heartbeat(state(), meta()) -> {nil, state()}.
mq_cluster_publish_heartbeat(#state{mqtt_fsm = MQTT_Connection, network_mac = MacPrefix, string_mac = StringMacPrefix, guardian_id = GuardianId, network_id = NetworkID, mq_type = MQType } = State, Meta) ->
    lager:warning("The ALIVE ~p ~p <<", [MQTT_Connection,is_process_alive(MQTT_Connection)]),
    SysId = re:replace(StringMacPrefix,"^.{6}", "", [{return, list}]),
    {BigTime, MediumTime, SmallTime} = os:timestamp(),
    Timestamp = io_lib:format("~4..0B~6..0B", [BigTime, MediumTime ]),
    PublishLocation = io_lib:format("iot-2/type/~s/id/~s/evt/guardian-status/fmt/json",[MQType, GuardianId]),
    
    %Guardian
    MQmessage = io_lib:format("{\"ts\": ~s, \"guardian_id\": \"~s\", \"network_id\": ~s, \"last_motion\": 946685095, \"motion_tripped\": 0, \"motion_enabled\": 1}",[Timestamp, GuardianId, NetworkID]),
    publish(State, Meta, PublishLocation, MQmessage, 0),
    {nil,State}.


-spec mq_cluster_publish_history(state(), meta()) -> {nil, state()}.
mq_cluster_publish_history(#state{network_mac = MacPrefix, string_mac = StringMacPrefix, guardian_id = GuardianId, network_id = NetworkID, mq_type = MQType } = State, Meta) ->
    SysId = re:replace(StringMacPrefix,"^.{6}", "", [{return, list}]),
    {BigTime, MediumTime, SmallTime} = os:timestamp(),
    Timestamp = io_lib:format("~4..0B~6..0B", [BigTime, MediumTime ]),
    PublishLocation = io_lib:format("iot-2/type/~s/id/~s/evt/motion-history/fmt/json",[MQType, GuardianId]),
    
    %Guardian
    %MQmessage = <<"{'ts': #time#, 'guardian_id': '#guardian#', 'network_id': #network#, 'radars': [{'deviceId': 'test-#sys#01', 'ts': 0.0, 'interfaces': [{'name': 'wan0', 'type': 'ETHERNET', 'mac': '#mac#01', 'ip': '10.22.22.1', 'routes': [{'dst': '0.0.0.0'}]}], 'links': [{'mac': '#mac#10', 'peer_type': '7'}, {'mac': '#mac#20', 'peer_type': '7'}, {'mac': '#mac#30', 'peer_type': '2'}], 'ap_bssid_2ghz': '#mac#02', 'ap_bssid_5ghz': '#mac#03', 'mesh_bssid': '#mac#00', 'gateway_bssid': 'ff:00:00:00:00:00', 'root_mode': 2}, {'deviceId': 'test-#sys#11', 'ts': 0.0, 'interfaces': [{'name': 'wan0', 'type': 'BRIDGE', 'mac': '#mac#11', 'ip': '10.22.22.1', 'routes': [{'dst': '0.0.0.0'}]}], 'links': [{'mac': '#mac#00', 'peer_type': '7'}, {'mac': '#mac#20', 'peer_type': '7'}, {'mac': '#mac#40', 'peer_type': '2'}], 'ap_bssid_2ghz': '#mac#12', 'ap_bssid_5ghz': '#mac#13', 'mesh_bssid': '#mac#10', 'gateway_bssid': '#mac#00', 'root_mode': 1}, {'deviceId': 'test-#sys#21', 'ts': 0.0, 'interfaces': [{'name': 'wan0', 'type': 'BRIDGE', 'mac': '#mac#21', 'ip': '10.22.22.1', 'routes': [{'dst': '0.0.0.0'}]}], 'links': [{'mac': '#mac#00', 'peer_type': '7'}, {'mac': '#mac#10', 'peer_type': '7'}, {'mac': '#mac#50', 'peer_type': '2'}], 'ap_bssid_2ghz': '#mac#22', 'ap_bssid_5ghz': '#mac#23', 'mesh_bssid': '#mac#20', 'gateway_bssid': '#mac#00', 'root_mode': 1}], 'last_motion': 946685095}">>,
    %MQmessage = io_lib:format(<<"{\"ts\": ~s, \"guardian_id\": \"~s01\", \"network_id\": ~s, \"radars\": {\"test-~s01\": { \"ts\": 0.0, \"interfaces\": [{\"name\": \"wan0\", \"type\": \"ETHERNET\", \"mac\": \"~s01\", \"ip\": \"10.22.22.1\", \"routes\": [{\"dst\": \"0.0.0.0\"}]}], \"links\": [{\"mac\": \"~s10\", \"peer_type\": \"7\"}, {\"mac\": \"~s20\", \"peer_type\": \"7\"}, {\"mac\": \"~s30\", \"peer_type\": \"2\"}], \"ap_bssid_2ghz\": \"~s02\", \"ap_bssid_5ghz\": \"~s03\", \"mesh_bssid\": \"~s00\", \"gateway_bssid\": \"ff:00:00:00:00:00\", \"root_mode\": 2}, \"test-~s11\":{ \"ts\": 0.0, \"interfaces\": [{\"name\": \"wan0\", \"type\": \"BRIDGE\", \"mac\": \"~s11\", \"ip\": \"10.22.22.1\", \"routes\": [{\"dst\": \"0.0.0.0\"}]}], \"links\": [{\"mac\": \"~s00\", \"peer_type\": \"7\"}, {\"mac\": \"~s20\", \"peer_type\": \"7\"}, {\"mac\": \"~s40\", \"peer_type\": \"2\"}], \"ap_bssid_2ghz\": \"~s12\", \"ap_bssid_5ghz\": \"~s13\", \"mesh_bssid\": \"~s10\", \"gateway_bssid\": \"~s00\", \"root_mode\": 1}, \"test-~s21\": {\"ts\": 0.0, \"interfaces\": [{\"name\": \"wan0\", \"type\": \"BRIDGE\", \"mac\": \"~s21\", \"ip\": \"10.22.22.1\", \"routes\": [{\"dst\": \"0.0.0.0\"}]}], \"links\": [{\"mac\": \"~s00\", \"peer_type\": \"7\"}, {\"mac\": \"~s10\", \"peer_type\": \"7\"}, {\"mac\": \"~s50\", \"peer_type\": \"2\"}], \"ap_bssid_2ghz\": \"~s22\", \"ap_bssid_5ghz\": \"~s23\", \"mesh_bssid\": \"~s20\", \"gateway_bssid\": \"~s00\", \"root_mode\": 1}}, \"last_motion\": 946685095}">>,[Timestamp,GuardianId,NetworkID,StringMacPrefix,MacPrefix,MacPrefix,MacPrefix,MacPrefix,MacPrefix,MacPrefix,MacPrefix,StringMacPrefix,MacPrefix,MacPrefix,MacPrefix,MacPrefix,MacPrefix,MacPrefix,MacPrefix,MacPrefix,StringMacPrefix,MacPrefix,MacPrefix,MacPrefix,MacPrefix,MacPrefix,MacPrefix,MacPrefix,MacPrefix]),
    %MQmessage = io_lib:format(<<"{"count": 60, "motion": {"mkai": [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0], "throughput": [0.97, 0.99, 0.98, 0.98, 0.97, 0.98, 0.96, 1.0, 0.97, 0.99, 1.0, 0.99, 0.98, 0.98, 0.98, 1.0, 0.99, 0.99, 0.91, 0.91, 0.9, 0.93, 0.9, 0.95, 0.96, 0.98, 0.95, 0.95, 0.96, 0.97, 0.98, 0.98, 0.98, 0.99, 0.99, 0.99, 0.95, 0.99, 0.98, 1.0, 0.99, 0.98, 0.97, 0.98, 0.99, 0.99, 0.98, 1.0, 0.97, 0.99, 0.98, 0.99, 0.97, 1.0, 0.99, 0.99, 0.96, 1.0, 0.96, 0.99]}, "interval": 5000, "location": {"macs": [], "density": [[], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], []]}, "ts": 1564805425} ">>,[]),
    MQmessage = io_lib:format(<<"{\"count\": 60, \"motion\": {\"mkai\": [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0], \"throughput\": [0.97, 0.99, 0.98, 0.98, 0.97, 0.98, 0.96, 1.0, 0.97, 0.99, 1.0, 0.99, 0.98, 0.98, 0.98, 1.0, 0.99, 0.99, 0.91, 0.91, 0.9, 0.93, 0.9, 0.95, 0.96, 0.98, 0.95, 0.95, 0.96, 0.97, 0.98, 0.98, 0.98, 0.99, 0.99, 0.99, 0.95, 0.99, 0.98, 1.0, 0.99, 0.98, 0.97, 0.98, 0.99, 0.99, 0.98, 1.0, 0.97, 0.99, 0.98, 0.99, 0.97, 1.0, 0.99, 0.99, 0.96, 1.0, 0.96, 0.99]}, \"interval\": 5000, \"location\": {\"macs\": [], \"density\": [[], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], []]}, \"ts\": ~s} ">>,[Timestamp]),
    publish(State, Meta, PublishLocation, MQmessage, 0),
    {nil,State}.












%% ------------------------------------------------
%% Gen_MQTT Callbacks (partly un-used)
%% ------------------------------------------------
on_connect(State) ->
    mzb_metrics:notify({"mqtt.connection.current_total", counter}, 1),
    {ok, State}.

on_connect_error(_Reason, State) ->
    mzb_metrics:notify({"mqtt.connection.connect.errors", counter}, 1),
    {ok, State}.

on_disconnect(State) ->
    mzb_metrics:notify({"mqtt.connection.current_total", counter}, -1),
    mzb_metrics:notify({"mqtt.connection.cluster_total", counter}, -1),
    mzb_metrics:notify({"mqtt.connection.reconnects", counter}, 1),
    lager:warning("The PID Stuff  ~p ~p<<", [State, registered()]),
    {ok, State}.

on_subscribe(Topics, State) ->
    case Topics of
        {error, _T, _QoSTable} ->
            mzb_metrics:notify({"mqtt.consumer.suback.errors", counter}, 1);
    _ ->
    mzb_metrics:notify({"mqtt.consumer.current_total", counter}, 1)
    end,
    {ok, State}.

on_unsubscribe(_Topics, State) ->
    mzb_metrics:notify({"mqtt.consumer.current_total", counter}, -1),
    {ok, State}.

on_publish(Topic, Payload, #mqtt{action=Action} = State) ->
    mzb_metrics:notify({"mqtt.message.consumed.total", counter}, 1),
    case Action of
        {forward, TopicPrefix, Qos} ->
            {_Timestamp, OrigPayload} = binary_to_term(Payload),
            ClientId = binary_to_list(lists:last(Topic)),
            case vmq_topic:validate_topic(publish, list_to_binary(TopicPrefix ++ ClientId)) of
                {ok, OutTopic} ->
                    NewPayload = term_to_binary({os:timestamp(), OrigPayload}),
                    gen_emqtt:publish(self(), OutTopic, NewPayload, Qos, false),
                    mzb_metrics:notify({"mqtt.message.published.total", counter}, 1),
                    {ok, State};
                {error, Reason} ->
                    error_logger:warning_msg("Can't validate topic ~p due to ~p~n", [Topic, Reason]),
                    {ok, State}
            end;
        {idle} ->
            {ok, State}
    end.

handle_call(_Req, _From, State) ->
    {reply, ok, State}.

handle_cast(Req, State) ->
    {noreply, State#mqtt{action=Req}}.

handle_info(_Req, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    mzb_metrics:notify({"mqtt.connection.current_total", counter}, -1),
    mzb_metrics:notify({"mqtt.connection.reconnects", counter}, 1),
    lager:warning("Reconnect Info ~p ", [_State] ),
    %mq_cluster_connect(_State, ""),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% ------------------------------------------------
%% MZBench API (Statement Functions)
%% ------------------------------------------------

connect(State, _Meta, ConnectOpts) ->
    ClientId = proplists:get_value(client, ConnectOpts),
    Args = #mqtt{action={idle}},
    {ok, SessionPid} = gen_emqtt:start_link(?MODULE, Args, [{info_fun, {fun stats/2, maps:new()}}|ConnectOpts]),
    lager:warning("The SessionID ~p <<", [SessionPid]),
    {nil, State#state{mqtt_fsm=SessionPid, client=ClientId}}.

disconnect(#state{mqtt_fsm=SessionPid} = State, _Meta) ->
    gen_emqtt:disconnect(SessionPid),
    {nil, State}.

publish(State, _Meta, Topic, Payload, QoS) ->
    publish(State, _Meta, Topic, Payload, QoS, false).

publish(#state{mqtt_fsm = SessionPid} = State, _Meta, Topic, Payload, QoS, Retain) ->
    %lager:warning("The State Options in publish ~p <<", [State]),
    case vmq_topic:validate_topic(publish, list_to_binary(Topic)) of
        {ok, TTopic} ->
            {BigTime, MediumTime, SmallTime} = os:timestamp(),
            Timestamp = io_lib:format("~4..0B~5..0B~6..0B", [BigTime, MediumTime, SmallTime]),
            Payload1 = term_to_binary(Payload),
            gen_emqtt:publish(SessionPid, TTopic, Payload, QoS, Retain),
            mzb_metrics:notify({"mqtt.message.published.total", counter}, 1),
            {nil, State};
        {error, Reason} ->
            error_logger:warning_msg("Can't validate topic ~p due to ~p~n", [Topic, Reason]),
            {nil, State}
    end.


subscribe(#state{mqtt_fsm = SessionPid} = State, _Meta, [T|_] = Topics) when is_tuple(T) ->
    ValidTopics = lists:filtermap(
        fun({Topic, Qos}) ->
            case vmq_topic:validate_topic(subscribe, list_to_binary(Topic)) of
                {ok, ValidTopic} ->
                    {true, {ValidTopic, Qos}};
                {error, Reason} ->
                    error_logger:warning_msg("Can't validate topic conf ~p due to ~p~n", [Topic, Reason]),
                    false
            end
        end,
        Topics
    ),
    gen_emqtt:subscribe(SessionPid, ValidTopics),
    {nil, State}.

subscribe(State, Meta, Topic, Qos) ->
    subscribe(State, Meta, [{Topic, Qos}]).

unsubscribe(#state{mqtt_fsm = SessionPid} = State, _Meta, Topics) ->
    gen_emqtt:unsubscribe(SessionPid, Topics),
    {nil, State}.

subscribe_to_self(#state{client = ClientId} = State, _Meta, TopicPrefix, Qos) ->
    subscribe(State, _Meta, TopicPrefix ++ ClientId, Qos).

publish_to_self(#state{client = ClientId} = State, _Meta, TopicPrefix, Payload, Qos) ->
    publish(State, _Meta, TopicPrefix ++ ClientId, Payload, Qos).

publish_to_one(State, Meta, TopicPrefix, ClientId, Payload, Qos) ->
    publish_to_one(State, Meta, TopicPrefix, ClientId, Payload, Qos, false).

publish_to_one(State, Meta, TopicPrefix, ClientId, Payload, Qos, Retain) ->
    publish(State, Meta, TopicPrefix ++ ClientId, Payload, Qos, Retain).

idle(#state{mqtt_fsm = SessionPid} = State, _Meta) ->
    gen_fsm:send_all_state_event(SessionPid, {idle}),
    {nil, State}.

forward(#state{mqtt_fsm = SessionPid} = State, _Meta, TopicPrefix, Qos) ->
    gen_fsm:send_all_state_event(SessionPid, {forward, TopicPrefix, Qos}),
    {nil, State}.

client(#state{client = Client}=State, _Meta) ->
    {Client, State}.

worker_id(State, Meta) ->
    ID = proplists:get_value(worker_id, Meta),
    {ID, State}.

fixed_client_id(State, _Meta, Name, Id) -> {[Name, "-", integer_to_list(Id)], State}.

random_client_id(State, _Meta, N) ->
    {randlist(N) ++ pid_to_list(self()), State}.

random_client_ip(State, _Meta, IfPrefix) ->
    {ok, Interfaces} = inet:getifaddrs(),
    IfConfigurations = [Conf || {IfName, Conf} <- Interfaces, lists:prefix(IfPrefix, IfName)],
    Addresses = [Ip || {addr, Ip} <- lists:flatten(IfConfigurations), tuple_size(Ip) == 4],
    case length(Addresses) of
        0 ->
            {"0.0.0.0", State};
        Total ->
            {lists:nth(random:uniform(Total), Addresses), State}
    end.

load_client_cert(State, _Meta, CertBin) ->
    Pems = public_key:pem_decode(CertBin),
    {value, Certificate} = lists:keysearch('Certificate', 1, Pems),
    PKey = get_cert_bin(Certificate),
    {PKey, State}.

load_client_key(State, _Meta, KeyBin) ->
    [{'RSAPrivateKey', KB, _}] = public_key:pem_decode(KeyBin),
    {{'RSAPrivateKey', KB}, State}.

load_cas(State, _Meta, CABin) ->
    CAList = public_key:pem_decode(CABin),
    CL = [get_cert_bin(Key) || Key <- CAList],
    {CL, State}.

get_cert_bin(Cert) ->
    {'Certificate', CertBin, _} = Cert,
    CertBin.

%% ------------------------------------------------
%% Gen_MQTT Info Callbacks
%% ------------------------------------------------

stats({connect_out, ClientId}, State) -> % log connection attempt
    io:format("connect_out for client_id: ~p~n", [ClientId]),
    T1 = os:timestamp(),
    maps:put(ClientId, T1, State);
stats({connack_in, ClientId}, State) ->
    diff(ClientId, State, "mqtt.connection.connack.latency", histogram);
stats({reconnect, _ClientId}, State) ->
    mzb_metrics:notify({"mqtt.connection.reconnects", counter}, 1),
    State;
stats({publish_out, MsgId, QoS}, State)  ->
    case QoS of
        0 -> ok;
        1 -> mzb_metrics:notify({"mqtt.publisher.qos1.puback.waiting", counter}, 1);
        2 -> mzb_metrics:notify({"mqtt.publisher.qos2.pubrec.waiting", counter}, 1)
    end,
    maps:put({outgoing, MsgId}, os:timestamp(), State);
stats({publish_in, MsgId, Payload, QoS}, State) ->
    T2 = os:timestamp(),
    {T1, _OldPayload} = binary_to_term(Payload),
    Diff = positive(timer:now_diff(T2, T1)),
    case QoS of
        0 -> mzb_metrics:notify({"mqtt.message.pub_to_sub.latency", histogram}, Diff);
        1 -> mzb_metrics:notify({"mqtt.message.pub_to_sub.latency.qos1", histogram}, Diff);
        2 -> mzb_metrics:notify({"mqtt.message.pub_to_sub.latency.qos2", histogram}, Diff)
    end,
    maps:put({incoming, MsgId}, T2, State);
stats({puback_in, MsgId}, State) ->
    T1 = maps:get({outgoing, MsgId}, State),
    T2 = os:timestamp(),
    mzb_metrics:notify({"mqtt.publisher.qos1.puback.latency", histogram}, positive(timer:now_diff(T2, T1))),
    mzb_metrics:notify({"mqtt.publisher.qos1.puback.in.total", counter}, 1),
    mzb_metrics:notify({"mqtt.publisher.qos1.puback.waiting", counter}, -1),
    NewState = maps:remove({outgoing, MsgId}, State),
    NewState;
stats({puback_out, MsgId}, State) ->
    diff({incoming, MsgId}, State, "mqtt.consumer.qos1.publish_in_to_puback_out.internal_latency", histogram);
stats({suback, MsgId}, State) ->
    diff(MsgId, State, "mqtt.consumer.suback.latency", histogram);
stats({subscribe_out, MsgId}, State) ->
    T1 = os:timestamp(),
    maps:put(MsgId, T1, State);
stats({unsubscribe_out, MsgId}, State) ->
    T1 = os:timestamp(),
    maps:put(MsgId, T1, State);
stats({unsuback, MsgId}, State) ->
    diff(MsgId, State, "mqtt.consumer.unsuback.latency", histogram);
stats({pubrec_in, MsgId}, State) ->
    T2 = os:timestamp(),
    T1 = maps:get({outgoing, MsgId}, State),
    mzb_metrics:notify({"mqtt.publisher.qos2.pub_out_to_pubrec_in.latency", histogram}, positive(timer:now_diff(T2, T1))),
    mzb_metrics:notify({"mqtt.publisher.qos2.pubrec.in.total"}, 1),
    mzb_metrics:notify({"mqtt.publisher.qos2.pubrec.waiting", counter}, -1),
    NewState = maps:update({outgoing, MsgId}, T2, State),
    NewState;
stats({pubrec_out, MsgId}, State) ->
    T2 = maps:get({incoming, MsgId}, State),
    T3 = os:timestamp(),
    mzb_metrics:notify({"mqtt.consumer.qos2.publish_in_to_pubrec_out.internal_latency", histogram}, positive(timer:now_diff(T3, T2))),
    NewState = maps:update({incoming, MsgId}, T3, State),
    NewState;
stats({pubrel_out, MsgId}, State) ->
    T3 = os:timestamp(),
    T2 = maps:get({outgoing, MsgId}, State),
    mzb_metrics:notify({"mqtt.publisher.qos2.pubrec_in_to_pubrel_out.internal_latency", histogram}, positive(timer:now_diff(T3, T2))),
    mzb_metrics:notify({"mqtt.publisher.qos2.pubcomp.waiting", counter}, 1),
    NewState = maps:update({outgoing, MsgId}, T3, State),
    NewState;
stats({pubrel_in, MsgId}, State) ->
    T4 = os:timestamp(),
    T3 = maps:get({incoming, MsgId}, State),
    mzb_metrics:notify({"mqtt.consumer.qos2.pubrec_out_to_pubrel_in.latency", histogram}, positive(timer:now_diff(T4, T3))),
    NewState = maps:update({incoming, MsgId}, T4, State),
    NewState;
stats({pubcomp_in, MsgId}, State) ->
    T4 = os:timestamp(),
    T3 = maps:get({outgoing, MsgId}, State),
    mzb_metrics:notify({"mqtt.publisher.qos2.pubrel_out_to_pubcomp_in.latency", histogram}, positive(timer:now_diff(T4, T3))),
    mzb_metrics:notify({"mqtt.publisher.qos2.pubcomp.waiting", counter}, -1),
    NewState = maps:remove({outgoing, MsgId}, State),
    NewState;
stats({pubcomp_out, MsgId}, State) ->
    T5 = os:timestamp(),
    T4 = maps:get({incoming, MsgId}, State),
    mzb_metrics:notify({"mqtt.consumer.qos2.pubrel_in_to_pubcomp_out.internal_latency", histogram}, positive(timer:now_diff(T5, T4))),
    NewState = maps:remove({incoming, MsgId}, State),
    NewState.

diff(MsgId, State, Metric, MetricType) ->
    T2 = os:timestamp(),
    T1 = maps:get(MsgId, State),
    mzb_metrics:notify({Metric, MetricType}, positive(timer:now_diff(T2, T1))),
    NewState = maps:remove(MsgId, State),
    NewState.

positive(Val) when Val < 0 -> 0;
positive(Val) when Val >= 0 -> Val.

randlist(N) ->
    randlist(N, []).
randlist(0, Acc) ->
    Acc;
randlist(N, Acc) ->
    randlist(N - 1, [random:uniform(26) + 96 | Acc]).










%DEMO
%Heartbeat:
%{"network_id": 11, "motion_tripped": 0, "last_motion": 1563389658.5, "ts": 1563391975.28, "guardian_id": "5d2e1d18fba27931c16e941d", "motion_enabled": 1}
%GK_STATUS:
%{"leafblower": {"98:01:a7:a4:e5:6b": {"is_static": "MOBILE", "sounding": null, "ap": {"4C724013AC": 0.1, "4C7240138C": 0.09, "4C72401397": 0.09}, "leaf": {}}, "60:b4:f7:f1:51:55": {"is_static": "MOBILE", "sounding": null, "ap": {"4C7240138C": 1}, "leaf": {}}, "c4:b3:01:c9:85:77": {"is_static": "MOBILE", "sounding": null, "ap": {"4C7240138C": 0.1}, "leaf": {}}, "d2:b4:f7:f1:51:14": {"is_static": "STATIC", "sounding": null, "ap": {"4C724013AC": 1, "4C72401397": 1}, "leaf": {"vht_capabilities": "0x338b79f2", "ht_capabilities": "0x000009ef", "peer_type": "7", "if_name": "bhaul-sta-u50", "hostname": "*", "mac": "d2:b4:f7:f1:51:14"}}, "c0:b6:58:58:fd:b4": {"is_static": "MOBILE", "sounding": null, "ap": {"4C724013AC": 0.08, "4C7240138C": 0.08, "4C72401397": 0.08}, "leaf": {"vht_capabilities": "0x00000000", "ht_capabilities": "0x0000402c", "peer_type": "2", "if_name": "home-ap-24", "hostname": "iPhoneXs-iPhone", "mac": "c0:b6:58:58:fd:b4"}}, "d2:b4:f7:f1:51:12": {"is_static": "MOBILE", "sounding": null, "ap": {"4C724013AC": 0.83, "4C72401397": -0.02}, "leaf": {}}, "54:99:63:b6:2c:c2": {"is_static": "MOBILE", "sounding": null, "ap": {"4C724013AC": 0.08, "4C7240138C": 0.08, "4C72401397": 0.08}, "leaf": {"vht_capabilities": "0x0f817032", "ht_capabilities": "0x0000006f", "peer_type": "2", "if_name": "home-ap-u50", "hostname": "Marijas-iPhone", "mac": "54:99:63:b6:2c:c2"}}, "08:c5:e1:c5:fa:09": {"is_static": "MOBILE", "sounding": null, "ap": {"4C724013AC": 0.1, "4C7240138C": 0.09, "4C72401397": 0.1}, "leaf": {}}, "d2:b4:f7:f1:51:54": {"is_static": "MOBILE", "sounding": null, "ap": {"4C724013AC": 0.09}, "leaf": {}}, "60:b4:f7:f1:51:54": {"is_static": "MOBILE", "sounding": null, "ap": {"4C7240138C": -0.04}, "leaf": {}}, "60:b4:f7:f1:51:56": {"is_static": "MOBILE", "sounding": null, "ap": {"4C724013AC": 0.09, "4C7240138C": 1}, "leaf": {"vht_capabilities": "0x338379f2", "ht_capabilities": "0x000009ef", "peer_type": "7", "if_name": "bhaul-ap-u50", "hostname": "4C72401397_Pod_900200600", "mac": "60:b4:f7:f1:51:56"}}, "6c:96:cf:d8:d2:c7": {"is_static": "MOBILE", "sounding": null, "ap": {"4C724013AC": 0.08, "4C7240138C": 0.08, "4C72401397": 0.08}, "leaf": {"vht_capabilities": "0x0f8259b2", "ht_capabilities": "0x000009ef", "peer_type": "2", "if_name": "home-ap-l50", "hostname": "Ivanas-MBP-2", "mac": "6c:96:cf:d8:d2:c7"}}, "c0:bd:d1:9e:c1:d3": {"is_static": "MOBILE", "sounding": null, "ap": {"4C72401397": 0.1}, "leaf": {"vht_capabilities": "0x0f815832", "ht_capabilities": "0x0000006f", "peer_type": "2", "if_name": "home-ap-l50", "hostname": "", "mac": "c0:bd:d1:9e:c1:d3"}}, "f4:5c:89:ac:d9:c1": {"is_static": "MOBILE", "sounding": null, "ap": {"4C724013AC": 0.09, "4C7240138C": 0.08, "4C72401397": 0.08}, "leaf": {"vht_capabilities": "0x0f8259b2", "ht_capabilities": "0x000009ef", "peer_type": "2", "if_name": "home-ap-u50", "hostname": "Rades-MBP-3", "mac": "f4:5c:89:ac:d9:c1"}}, "d2:b4:f7:f1:51:13": {"is_static": "MOBILE", "sounding": null, "ap": {"4C72401397": 0.98}, "leaf": {}}, "d2:b4:f7:f1:51:d4": {"is_static": "MOBILE", "sounding": null, "ap": {"4C72401397": 0.09}, "leaf": {}}, "60:b4:f7:f1:51:d4": {"is_static": "MOBILE", "sounding": null, "ap": {"4C7240138C": 1, "4C72401397": 0.15}, "leaf": {"vht_capabilities": "0x338379f2", "ht_capabilities": "0x000009ef", "peer_type": "7", "if_name": "bhaul-ap-u50", "hostname": "4C724013AC_Pod_900200600", "mac": "60:b4:f7:f1:51:d4"}}, "68:c6:3a:e6:79:6a": {"is_static": "MOBILE", "sounding": false, "ap": {"4C7240138C": 0.09, "4C72401397": -0.02}, "leaf": {"vht_capabilities": "0x00000000", "ht_capabilities": "0x0000112c", "peer_type": "2", "if_name": "home-ap-24", "hostname": "ESP_E6796A", "mac": "68:c6:3a:e6:79:6a"}}, "d2:b4:f7:f1:51:56": {"is_static": "MOBILE", "sounding": null, "ap": {"4C724013AC": 0.17}, "leaf": {}}, "60:b4:f7:f1:51:d2": {"is_static": "MOBILE", "sounding": null, "ap": {"4C7240138C": 0.97, "4C72401397": 0.09}, "leaf": {}}, "40:4e:36:87:bb:5b": {"is_static": "MOBILE", "sounding": null, "ap": {"4C72401397": 0.1}, "leaf": {}}, "18:65:90:cf:00:33": {"is_static": "MOBILE", "sounding": null, "ap": {"4C724013AC": 0.08, "4C7240138C": 0.09, "4C72401397": 0.08}, "leaf": {"vht_capabilities": "0x0f8259b2", "ht_capabilities": "0x000009ef", "peer_type": "2", "if_name": "home-ap-l50", "hostname": "Marijas-MBP", "mac": "18:65:90:cf:00:33"}}, "24:18:1d:7f:13:97": {"is_static": "MOBILE", "sounding": null, "ap": {"4C724013AC": 0.09, "4C7240138C": 0.08, "4C72401397": 0.09}, "leaf": {"vht_capabilities": "0x0f9179b2", "ht_capabilities": "0x000001ef", "peer_type": "2", "if_name": "home-ap-u50", "hostname": "Galaxy-S9", "mac": "24:18:1d:7f:13:97"}}}, "network_id": 11, "last_motion": 1575048954.86, "version": {"leafblower": "0.3.1-rd2", "LinkEvent": "0.1.2", "BayesianLeafs": "0.1.13", "MotionEvent": "0.5.4", "core": "0.7.0", "context": "0.8.2"}, "motion_tripped": 1, "guardian_id": "5d2e1d18fba27931c16e941d", "ts": 1575049071.84, "motion_enabled": 0, "radars": {"4C724013AC": {"interfaces": [{"routes": [], "name": "eth1", "rx_bytes": "0", "type": "ETHERNET", "tx_bytes": "0", "mac": "60:b4:f7:f1:51:d1", "ip": ""}, {"routes": [], "status": "Connected", "rx_bytes": "173503092", "tx_bytes": "233156", "mac": "36:55:f8:c8:08:ee", "name": "br-home.tx", "ip": "", "type": "ETHERNET"}, {"routes": [], "name": "eth1.4", "rx_bytes": "0", "type": "ETHERNET", "tx_bytes": "0", "mac": "60:b4:f7:f1:51:d1", "ip": ""}, {"routes": [{"gateway": "0.0.0.0", "netmask": "255.255.255.128", "metric": "0", "dst": "169.254.173.128"}], "mac": "d2:b4:f7:f1:51:d4", "rx_bytes": "0", "ip": "169.254.173.129", "name": "bhaul-ap-u50", "wifi_channel": 157, "status": "Connected", "wifi_phy": "wifi2", "motion_enabled": true, "tx_bytes": "0", "type": "WIFI_AP"}, {"routes": [{"gateway": "0.0.0.0", "netmask": "255.255.255.128", "metric": "0", "dst": "169.254.6.0"}], "mac": "f2:b4:f7:f1:51:d2", "rx_bytes": "0", "ip": "169.254.6.1", "name": "onboard-ap-24", "wifi_channel": 1, "status": "Connected", "wifi_phy": "wifi0", "motion_enabled": true, "tx_bytes": "0", "type": "WIFI_AP"}, {"routes": [], "status": "Connected", "rx_bytes": "0", "tx_bytes": "0", "mac": "62:b4:f7:f1:51:d4", "name": "g-bhaul-sta-u50", "ip": "", "type": "ETHERNET"}, {"routes": [], "status": "Connected", "rx_bytes": "173503540", "tx_bytes": "738", "mac": "aa:bb:15:82:7b:4c", "name": "br-home.dpi", "ip": "", "type": "ETHERNET"}, {"routes": [], "name": "ifb0", "rx_bytes": "0", "type": "ETHERNET", "tx_bytes": "0", "mac": "e6:76:eb:17:3e:01", "ip": ""}, {"routes": [], "status": "Connected", "rx_bytes": "344880", "tx_bytes": "808", "mac": "72:6e:a6:54:fa:79", "name": "br-home.dns", "ip": "", "type": "ETHERNET"}, {"routes": [], "status": "Connected", "rx_bytes": "173504000", "tx_bytes": "738", "mac": "9e:66:0e:d3:e1:cd", "name": "br-home.dhcp", "ip": "", "type": "ETHERNET"}, {"routes": [], "status": "Connected", "rx_bytes": "173504202", "tx_bytes": "738", "mac": "a6:5c:d1:a3:10:d7", "name": "br-home.l2uf", "ip": "", "type": "ETHERNET"}, {"routes": [{"gateway": "0.0.0.0", "netmask": "255.255.255.128", "metric": "0", "dst": "169.254.171.128"}], "mac": "60:b4:f7:f1:51:d4", "rx_bytes": "2019264544", "ip": "169.254.171.144", "name": "bhaul-sta-u50", "wifi_channel": 157, "status": "Connected", "wifi_phy": "wifi2", "motion_enabled": true, "tx_bytes": "5060048954", "type": "WIFI_CLIENT"}, {"routes": [], "mac": "e2:b4:f7:f1:51:d2", "rx_bytes": "75105", "ip": "", "name": "home-ap-24", "wifi_channel": 1, "status": "Connected", "wifi_phy": "wifi0", "motion_enabled": true, "tx_bytes": "514987", "type": "WIFI_AP"}, {"routes": [], "name": "br-gre-24", "rx_bytes": "0", "type": "ETHERNET", "tx_bytes": "0", "mac": "7e:7b:fa:11:46:4c", "ip": ""}, {"routes": [], "name": "ifb1", "rx_bytes": "0", "type": "ETHERNET", "tx_bytes": "0", "mac": "ca:09:0b:af:40:3a", "ip": ""}, {"routes": [], "name": "bond0", "rx_bytes": "0", "type": "ETHERNET", "tx_bytes": "0", "mac": "46:46:5a:7a:58:9e", "ip": ""}, {"routes": [{"gateway": "0.0.0.0", "netmask": "255.255.255.128", "metric": "0", "dst": "169.254.7.128"}], "mac": "d2:b4:f7:f1:51:d3", "rx_bytes": "0", "ip": "169.254.7.129", "name": "bhaul-ap-l50", "wifi_channel": 44, "status": "Connected", "wifi_phy": "wifi1", "motion_enabled": true, "tx_bytes": "0", "type": "WIFI_AP"}, {"routes": [], "status": "Connected", "rx_bytes": "4844", "tx_bytes": "738", "mac": "06:3c:af:d2:44:b1", "name": "br-home.http", "ip": "", "type": "ETHERNET"}, {"routes": [], "name": "eth0.4", "rx_bytes": "0", "type": "ETHERNET", "tx_bytes": "0", "mac": "60:b4:f7:f1:51:d0", "ip": ""}, {"routes": [{"gateway": "0.0.0.0", "netmask": "255.255.255.128", "metric": "0", "dst": "169.254.7.0"}], "mac": "f2:b4:f7:f1:51:d3", "rx_bytes": "0", "ip": "169.254.7.1", "name": "onboard-ap-l50", "wifi_channel": 44, "status": "Connected", "wifi_phy": "wifi1", "motion_enabled": true, "tx_bytes": "0", "type": "WIFI_AP"}, {"routes": [{"gateway": "0.0.0.0", "netmask": "255.255.255.128", "metric": "0", "dst": "169.254.173.0"}], "mac": "f2:b4:f7:f1:51:d4", "rx_bytes": "0", "ip": "169.254.173.1", "name": "onboard-ap-u50", "wifi_channel": 157, "status": "Connected", "wifi_phy": "wifi2", "motion_enabled": true, "tx_bytes": "0", "type": "WIFI_AP"}, {"routes": [], "name": "ovs-system", "rx_bytes": "0", "type": "ETHERNET", "tx_bytes": "0", "mac": "2a:52:3f:e6:5c:1f", "ip": ""}, {"routes": [], "status": "Connected", "rx_bytes": "173504064", "tx_bytes": "738", "mac": "62:b4:f7:f1:51:d0", "name": "br-home", "ip": "", "type": "ETHERNET"}, {"routes": [{"gateway": "0.0.0.0", "netmask": "255.255.255.128", "metric": "0", "dst": "169.254.6.128"}], "mac": "d2:b4:f7:f1:51:d2", "rx_bytes": "0", "ip": "169.254.6.129", "name": "bhaul-ap-24", "wifi_channel": 1, "status": "Connected", "wifi_phy": "wifi0", "motion_enabled": true, "tx_bytes": "0", "type": "WIFI_AP"}, {"routes": [{"gateway": "192.168.10.1", "netmask": "0.0.0.0", "metric": "0", "dst": "0.0.0.0"}, {"gateway": "0.0.0.0", "netmask": "255.255.254.0", "metric": "0", "dst": "192.168.10.0"}], "status": "Connected", "rx_bytes": "1087668354", "tx_bytes": "4601868532", "mac": "60:b4:f7:f1:51:d0", "name": "br-wan", "ip": "192.168.11.16", "type": "ETHERNET"}, {"routes": [], "mac": "e2:b4:f7:f1:51:d3", "rx_bytes": "77148859", "ip": "", "name": "home-ap-l50", "wifi_channel": 44, "status": "Connected", "wifi_phy": "wifi1", "motion_enabled": true, "tx_bytes": "761679760", "type": "WIFI_AP"}, {"routes": [], "name": "br-gre-50", "rx_bytes": "0", "type": "ETHERNET", "tx_bytes": "0", "mac": "66:4b:ff:d0:bd:4a", "ip": ""}, {"routes": [], "status": "Connected", "rx_bytes": "173502964", "tx_bytes": "738", "mac": "3a:0b:8c:52:ff:36", "name": "br-home.upnp", "ip": "", "type": "ETHERNET"}, {"routes": [], "name": "eth0", "rx_bytes": "0", "type": "ETHERNET", "tx_bytes": "0", "mac": "60:b4:f7:f1:51:d0", "ip": ""}], "ap_bssid_2ghz": "e2:b4:f7:f1:51:d2", "gateway_bssid": "00:c8:8b:61:b4:49", "p2p_bssid": "", "mesh_bssid": "60:b4:f7:f1:51:d4", "links": [{"vht_supported": "0", "vht_capabilities": "0x338b79f2", "wifi_txpwr": "16.000", "rx_bytes": "804217153", "phy": "wifi2", "implicit_dsss": "0", "rssi": "-25", "rssi_db": "-25", "implicit_legacy_80_80": "0", "uptime": "178417326", "tx_failed": "0", "cv_matrix_report_count": "0", "csi_report_count": "0", "tx_retries": "0", "if_name": "bhaul-sta-u50", "aid": "0", "v_matrix_report_count": "0", "motion_state": "1", "mac": "d2:b4:f7:f1:51:14", "implicit_legacy_80": "1730286", "implicit_legacy_20": "399", "rate_ms": "100", "ht_capabilities": "0x000009ef", "connected_time": "178417315", "implicit_legacy_40": "0", "implicit_error_count": "26016", "implicit_bw_downgrades": "399", "implicit_legacy_160": "0", "max_rx_streams": "4", "tx_bytes": "2136315911", "tx_bitrate": "1300000000", "mconf_zero_count": 25611, "wifi_protocol": "802_11", "ht_supported": "8", "rx_bitrate": "1560000000", "implicit_measurements": "1730685", "implicit_cck": "0", "last_heard": "0", "ip": "169.254.171.129", "peer_type": "7"}, {"wifi_protocol": "WIRED", "motion_type": "MOTION_NONE", "mac": "00:c8:8b:61:b4:49", "if_name": "br-wan", "ip": "192.168.10.1"}], "_age": 0, "ts": 1575049028.99, "node_id": "4C724013AC", "uptime": "178535.66", "fw_version": "221-uv3.4.2-kv3.4.2-15b78b5b3c79653c0fee0b6469c977a5894de54b-qca-wifi-cfr-dev", "deviceId": "csi-p-60b4f7f151d0", "root_mode": 1, "location_id": "5d2e1d18fba27931c16e941d", "version": {"radios": {"wifi2": {"fw_version": "0.0.0.9999", "chipset": "QCA9984"}, "wifi1": {"fw_version": "0.0.0.9999", "chipset": "QCA4019"}, "wifi0": {"fw_version": "0.0.0.9999", "chipset": "QCA4019"}}, "algos": {"omot": "1.9.2"}}, "hw_id": "Qualcomm", "hw_version": "Plume SuperPod B1A", "status_time": 0.41, "mem": {"free": "287368", "avail": "329488", "total": "496180"}, "load": ["0.77", "0.61", "0.51"], "ap_bssid_5ghz": "e2:b4:f7:f1:51:d3"}, "4C7240138C": {"interfaces": [{"routes": [], "status": "Connected", "rx_bytes": "18574081217", "tx_bytes": "55178264312", "mac": "60:b4:f7:f1:51:11", "name": "eth1", "ip": "", "type": "ETHERNET"}, {"routes": [], "status": "Connected", "rx_bytes": "441761522", "tx_bytes": "1026069", "mac": "de:62:19:80:33:ef", "name": "br-home.tx", "ip": "", "type": "ETHERNET"}, {"routes": [], "status": "Connected", "rx_bytes": "0", "tx_bytes": "2739106", "mac": "60:b4:f7:f1:51:11", "name": "eth1.4", "ip": "", "type": "ETHERNET"}, {"routes": [{"gateway": "0.0.0.0", "netmask": "255.255.255.128", "metric": "0", "dst": "169.254.2.0"}], "mac": "f2:b4:f7:f1:51:12", "rx_bytes": "0", "ip": "169.254.2.1", "name": "onboard-ap-24", "wifi_channel": 1, "status": "Connected", "wifi_phy": "wifi0", "motion_enabled": true, "tx_bytes": "0", "type": "WIFI_AP"}, {"routes": [{"gateway": "0.0.0.0", "netmask": "255.255.255.128", "metric": "0", "dst": "169.254.171.0"}], "mac": "f2:b4:f7:f1:51:14", "rx_bytes": "560090", "ip": "169.254.171.1", "name": "onboard-ap-u50", "wifi_channel": 157, "status": "Connected", "wifi_phy": "wifi2", "motion_enabled": true, "tx_bytes": "532603", "type": "WIFI_AP"}, {"routes": [], "name": "ovs-system", "rx_bytes": "0", "type": "ETHERNET", "tx_bytes": "0", "mac": "e2:37:b2:63:f2:3d", "ip": ""}, {"routes": [], "status": "Connected", "rx_bytes": "2157170653", "tx_bytes": "738", "mac": "5e:05:fe:5f:b8:10", "name": "br-home.dpi", "ip": "", "type": "ETHERNET"}, {"routes": [], "name": "ifb0", "rx_bytes": "0", "type": "ETHERNET", "tx_bytes": "0", "mac": "da:f4:79:8a:b5:e1", "ip": ""}, {"routes": [], "mac": "e2:b4:f7:f1:51:14", "rx_bytes": "253907329", "ip": "", "name": "home-ap-u50", "wifi_channel": 157, "status": "Connected", "wifi_phy": "wifi2", "motion_enabled": true, "tx_bytes": "2764718705", "type": "WIFI_AP"}, {"routes": [], "status": "Connected", "rx_bytes": "1430694", "tx_bytes": "738", "mac": "96:d9:b2:75:e1:63", "name": "br-home.dns", "ip": "", "type": "ETHERNET"}, {"routes": [], "name": "ifb1", "rx_bytes": "0", "type": "ETHERNET", "tx_bytes": "0", "mac": "02:ee:25:41:51:aa", "ip": ""}, {"routes": [], "mac": "e2:b4:f7:f1:51:12", "rx_bytes": "37876978", "ip": "", "name": "home-ap-24", "wifi_channel": 1, "status": "Connected", "wifi_phy": "wifi0", "motion_enabled": true, "tx_bytes": "481324793", "type": "WIFI_AP"}, {"routes": [], "status": "Connected", "rx_bytes": "441763354", "tx_bytes": "738", "mac": "d6:41:ab:b3:ac:14", "name": "br-home.l2uf", "ip": "", "type": "ETHERNET"}, {"routes": [], "name": "br-gre-24", "rx_bytes": "0", "type": "ETHERNET", "tx_bytes": "0", "mac": "9e:a0:a3:fe:f1:4d", "ip": ""}, {"routes": [], "status": "Connected", "rx_bytes": "447432317", "tx_bytes": "738", "mac": "82:5e:b5:a1:18:09", "name": "br-home.dhcp", "ip": "", "type": "ETHERNET"}, {"routes": [], "name": "bond0", "rx_bytes": "0", "type": "ETHERNET", "tx_bytes": "0", "mac": "6a:d1:67:5e:c0:7f", "ip": ""}, {"routes": [{"gateway": "0.0.0.0", "netmask": "255.255.255.128", "metric": "0", "dst": "169.254.3.128"}], "mac": "d2:b4:f7:f1:51:13", "rx_bytes": "0", "ip": "169.254.3.129", "name": "bhaul-ap-l50", "wifi_channel": 44, "status": "Connected", "wifi_phy": "wifi1", "motion_enabled": true, "tx_bytes": "0", "type": "WIFI_AP"}, {"routes": [], "status": "Connected", "rx_bytes": "8976", "tx_bytes": "738", "mac": "3a:34:1a:b0:0b:43", "name": "br-home.http", "ip": "", "type": "ETHERNET"}, {"routes": [], "name": "eth0.4", "rx_bytes": "0", "type": "ETHERNET", "tx_bytes": "0", "mac": "60:b4:f7:f1:51:10", "ip": ""}, {"routes": [{"gateway": "0.0.0.0", "netmask": "255.255.255.128", "metric": "0", "dst": "169.254.3.0"}], "mac": "f2:b4:f7:f1:51:13", "rx_bytes": "0", "ip": "169.254.3.1", "name": "onboard-ap-l50", "wifi_channel": 44, "status": "Connected", "wifi_phy": "wifi1", "motion_enabled": true, "tx_bytes": "0", "type": "WIFI_AP"}, {"routes": [], "status": "Connected", "rx_bytes": "0", "tx_bytes": "0", "mac": "de:de:7d:7b:88:e7", "name": "pgd171-143", "ip": "", "type": "ETHERNET"}, {"routes": [], "status": "Connected", "rx_bytes": "0", "tx_bytes": "0", "mac": "f6:67:6a:5b:b4:46", "name": "pgd171-144", "ip": "", "type": "ETHERNET"}, {"routes": [], "status": "Connected", "rx_bytes": "441773318", "tx_bytes": "738", "mac": "62:b4:f7:f1:51:10", "name": "br-home", "ip": "", "type": "ETHERNET"}, {"routes": [{"gateway": "0.0.0.0", "netmask": "255.255.255.128", "metric": "0", "dst": "169.254.2.128"}], "mac": "d2:b4:f7:f1:51:12", "rx_bytes": "0", "ip": "169.254.2.129", "name": "bhaul-ap-24", "wifi_channel": 1, "status": "Connected", "wifi_phy": "wifi0", "motion_enabled": true, "tx_bytes": "0", "type": "WIFI_AP"}, {"routes": [{"gateway": "192.168.10.1", "netmask": "0.0.0.0", "metric": "0", "dst": "0.0.0.0"}, {"gateway": "0.0.0.0", "netmask": "255.255.254.0", "metric": "0", "dst": "192.168.10.0"}], "status": "Connected", "rx_bytes": "30007775255", "tx_bytes": "51566277551", "mac": "60:b4:f7:f1:51:10", "name": "br-wan", "ip": "192.168.11.13", "type": "ETHERNET"}, {"routes": [], "name": "br-gre-50", "rx_bytes": "0", "type": "ETHERNET", "tx_bytes": "0", "mac": "22:67:c9:2e:26:4a", "ip": ""}, {"routes": [{"gateway": "0.0.0.0", "netmask": "255.255.255.128", "metric": "0", "dst": "169.254.171.128"}], "mac": "d2:b4:f7:f1:51:14", "rx_bytes": "25042295682", "ip": "169.254.171.129", "name": "bhaul-ap-u50", "wifi_channel": 157, "status": "Connected", "wifi_phy": "wifi2", "motion_enabled": true, "tx_bytes": "8780783496", "type": "WIFI_AP"}, {"routes": [], "status": "Connected", "rx_bytes": "441761266", "tx_bytes": "738", "mac": "f2:48:9a:db:7b:0c", "name": "br-home.upnp", "ip": "", "type": "ETHERNET"}, {"routes": [], "name": "eth0", "rx_bytes": "0", "type": "ETHERNET", "tx_bytes": "0", "mac": "60:b4:f7:f1:51:10", "ip": ""}], "ap_bssid_2ghz": "e2:b4:f7:f1:51:12", "gateway_bssid": "00:c8:8b:61:b4:49", "p2p_bssid": "", "mesh_bssid": "d2:b4:f7:f1:51:14", "links": [{"dhcp_expire": "", "mac": "24:18:1d:7f:13:97", "wifi_protocol": "dhcp", "if_name": "", "hostname": "Galaxy-S9", "dhcp_id": "1,3,6,15,26,28,51,58,59,43", "motion_type": "MOTION_NONE", "ifname": "dhcp", "ip": "192.168.11.35"}, {"dhcp_expire": "", "mac": "6c:96:cf:d8:d2:c7", "wifi_protocol": "dhcp", "if_name": "", "hostname": "Ivanas-MBP-2", "dhcp_id": "1,121,3,6,15,119,252,95,44,46", "motion_type": "MOTION_NONE", "ifname": "dhcp", "ip": "192.168.11.28"}, {"dhcp_expire": "", "mac": "f4:5c:89:ac:d9:c1", "wifi_protocol": "dhcp", "if_name": "", "hostname": "Rades-MBP-3", "dhcp_id": "1,121,3,6,15,119,252,95,44,46", "motion_type": "MOTION_NONE", "ifname": "dhcp", "ip": "192.168.11.27"}, {"dhcp_expire": "", "mac": "54:99:63:b6:2c:c2", "wifi_protocol": "dhcp", "if_name": "", "hostname": "Marijas-iPhone", "dhcp_id": "1,121,3,6,15,119,252", "motion_type": "MOTION_NONE", "ifname": "dhcp", "ip": "192.168.11.25"}, {"vht_supported": "0", "vht_capabilities": "0x00000000", "wifi_txpwr": "15.000", "rx_bytes": "44856702", "max_rx_streams": "1", "phy": "wifi0", "implicit_dsss": "0", "rssi": "-59", "rssi_db": "-59", "implicit_legacy_80_80": "0", "peer_type": "2", "uptime": "451182518", "last_heard": "0", "cv_matrix_report_count": "0", "csi_report_count": "0", "wifi_protocol": "802_11", "if_name": "home-ap-24", "hostname": "ESP_E6796A", "aid": "49153", "v_matrix_report_count": "0", "motion_state": "1", "mac": "68:c6:3a:e6:79:6a", "implicit_legacy_80": "0", "rate_ms": "100", "tx_failed": "0", "ht_capabilities": "0x0000112c", "connected_time": "451182454", "implicit_legacy_20": "4037390", "implicit_error_count": "253740", "implicit_bw_downgrades": "0", "implicit_legacy_160": "0", "mconf_zero_count": 607435, "tx_bytes": "3880669575", "tx_bitrate": "72000000", "dhcp_expire": "", "ht_supported": "8", "rx_bitrate": "54000000", "implicit_measurements": "4037390", "dhcp_id": "1,3,28,6,15,44,46,47,31,33,121,43", "implicit_cck": "0", "tx_retries": "0", "ip": "192.168.11.14", "implicit_legacy_40": "0"}, {"wifi_protocol": "WIRED", "motion_type": "MOTION_NONE", "mac": "00:c8:8b:61:b4:49", "if_name": "br-wan", "ip": "192.168.10.1"}, {"dhcp_expire": "", "mac": "c0:b6:58:58:fd:b4", "wifi_protocol": "dhcp", "if_name": "", "hostname": "iPhoneXs-iPhone", "dhcp_id": "1,121,3,6,15,119,252", "motion_type": "MOTION_NONE", "ifname": "dhcp", "ip": "192.168.11.37"}, {"dhcp_expire": "", "mac": "60:b4:f7:f1:51:52", "wifi_protocol": "dhcp", "if_name": "", "hostname": "4C72401397_Pod_900200600", "dhcp_id": "1,3,6,12,15,28,43", "motion_type": "MOTION_NONE", "ifname": "dhcp", "ip": "192.168.11.15"}, {"dhcp_expire": "", "mac": "60:b4:f7:f1:51:d0", "wifi_protocol": "dhcp", "if_name": "", "hostname": "4C724013AC_Pod_900200600", "dhcp_id": "1,3,6,12,15,28,43", "motion_type": "MOTION_NONE", "ifname": "dhcp", "ip": "192.168.11.16"}, {"dhcp_expire": "", "mac": "c0:bd:d1:9e:c1:d3", "wifi_protocol": "dhcp", "if_name": "", "hostname": "", "dhcp_id": "1,3,6,15,26,28,51,58,59,43", "motion_type": "MOTION_NONE", "ifname": "dhcp", "ip": "192.168.11.43"}, {"vht_supported": "0", "vht_capabilities": "0x338379f2", "wifi_txpwr": "15.000", "rx_bytes": "3480890467", "max_rx_streams": "4", "phy": "wifi2", "implicit_dsss": "0", "rssi": "-27", "rssi_db": "-27", "implicit_legacy_80_80": "0", "peer_type": "7", "uptime": "451131011", "last_heard": "0", "cv_matrix_report_count": "0", "csi_report_count": "0", "wifi_protocol": "802_11", "if_name": "bhaul-ap-u50", "hostname": "4C72401397_Pod_900200600", "aid": "49153", "v_matrix_report_count": "0", "motion_state": "1", "mac": "60:b4:f7:f1:51:56", "implicit_legacy_80": "4341720", "rate_ms": "100", "tx_failed": "0", "ht_capabilities": "0x000009ef", "connected_time": "451130946", "implicit_legacy_20": "3041", "implicit_error_count": "79091", "implicit_bw_downgrades": "3041", "implicit_legacy_160": "0", "mconf_zero_count": 35830, "tx_bytes": "1960724648", "tx_bitrate": "1733000000", "dhcp_expire": "", "ht_supported": "8", "rx_bitrate": "1733000000", "implicit_measurements": "4344761", "dhcp_id": "1,3,6,12,15,28,43", "implicit_cck": "0", "tx_retries": "0", "ip": "169.254.171.143", "implicit_legacy_40": "0"}, {"dhcp_expire": "", "mac": "18:65:90:cf:00:33", "wifi_protocol": "dhcp", "if_name": "", "hostname": "Marijas-MBP", "dhcp_id": "1,121,3,6,15,119,252,95,44,46", "motion_type": "MOTION_NONE", "ifname": "dhcp", "ip": "192.168.11.26"}, {"vht_supported": "0", "vht_capabilities": "0x338379f2", "wifi_txpwr": "15.000", "rx_bytes": "1407214328", "max_rx_streams": "4", "phy": "wifi2", "implicit_dsss": "0", "rssi": "-23", "rssi_db": "-23", "implicit_legacy_80_80": "0", "peer_type": "7", "uptime": "178399372", "last_heard": "0", "cv_matrix_report_count": "0", "csi_report_count": "0", "wifi_protocol": "802_11", "if_name": "bhaul-ap-u50", "hostname": "4C724013AC_Pod_900200600", "aid": "49154", "v_matrix_report_count": "0", "motion_state": "1", "mac": "60:b4:f7:f1:51:d4", "implicit_legacy_80": "1723675", "rate_ms": "100", "tx_failed": "0", "ht_capabilities": "0x000009ef", "connected_time": "178399308", "implicit_legacy_20": "639", "implicit_error_count": "25928", "implicit_bw_downgrades": "639", "implicit_legacy_160": "0", "mconf_zero_count": 249642, "tx_bytes": "1637755362", "tx_bitrate": "1560000000", "dhcp_expire": "", "ht_supported": "8", "rx_bitrate": "1300000000", "implicit_measurements": "1724314", "dhcp_id": "1,3,6,12,15,28,43", "implicit_cck": "0", "tx_retries": "0", "ip": "169.254.171.16", "implicit_legacy_40": "0"}], "_age": 0, "ts": 1575049011.25, "node_id": "4C7240138C", "uptime": "451300.93", "fw_version": "221-uv3.4.2-kv3.4.2-15b78b5b3c79653c0fee0b6469c977a5894de54b-qca-wifi-cfr-dev", "deviceId": "csi-p-60b4f7f15110", "root_mode": 2, "location_id": "5d2e1d18fba27931c16e941d", "version": {"radios": {"wifi2": {"fw_version": "0.0.0.9999", "chipset": "QCA9984"}, "wifi1": {"fw_version": "0.0.0.9999", "chipset": "QCA4019"}, "wifi0": {"fw_version": "0.0.0.9999", "chipset": "QCA4019"}}, "algos": {"omot": "1.9.2"}}, "hw_id": "Qualcomm", "hw_version": "Plume SuperPod B1A", "status_time": 0.52, "mem": {"free": "276284", "avail": "318828", "total": "496180"}, "load": ["0.96", "1.21", "1.37"], "ap_bssid_5ghz": "e2:b4:f7:f1:51:14"}, "4C72401397": {"interfaces": [{"routes": [], "name": "eth1", "rx_bytes": "0", "type": "ETHERNET", "tx_bytes": "0", "mac": "60:b4:f7:f1:51:53", "ip": ""}, {"routes": [], "status": "Connected", "rx_bytes": "441740240", "tx_bytes": "330174", "mac": "ee:85:63:db:4a:c3", "name": "br-home.tx", "ip": "", "type": "ETHERNET"}, {"routes": [], "name": "eth1.4", "rx_bytes": "0", "type": "ETHERNET", "tx_bytes": "0", "mac": "60:b4:f7:f1:51:53", "ip": ""}, {"routes": [{"gateway": "0.0.0.0", "netmask": "255.255.255.128", "metric": "0", "dst": "169.254.172.128"}], "mac": "d2:b4:f7:f1:51:56", "rx_bytes": "0", "ip": "169.254.172.129", "name": "bhaul-ap-u50", "wifi_channel": 157, "status": "Connected", "wifi_phy": "wifi2", "motion_enabled": true, "tx_bytes": "0", "type": "WIFI_AP"}, {"routes": [{"gateway": "0.0.0.0", "netmask": "255.255.255.128", "metric": "0", "dst": "169.254.4.0"}], "mac": "f2:b4:f7:f1:51:54", "rx_bytes": "0", "ip": "169.254.4.1", "name": "onboard-ap-24", "wifi_channel": 11, "status": "Connected", "wifi_phy": "wifi0", "motion_enabled": true, "tx_bytes": "0", "type": "WIFI_AP"}, {"routes": [], "status": "Connected", "rx_bytes": "0", "tx_bytes": "0", "mac": "62:b4:f7:f1:51:56", "name": "g-bhaul-sta-u50", "ip": "", "type": "ETHERNET"}, {"routes": [], "status": "Connected", "rx_bytes": "441741192", "tx_bytes": "738", "mac": "4e:ce:ff:dd:de:75", "name": "br-home.dpi", "ip": "", "type": "ETHERNET"}, {"routes": [], "name": "ifb0", "rx_bytes": "0", "type": "ETHERNET", "tx_bytes": "0", "mac": "06:51:c8:9f:38:9b", "ip": ""}, {"routes": [], "status": "Connected", "rx_bytes": "471444", "tx_bytes": "738", "mac": "86:4a:36:aa:d8:d4", "name": "br-home.dns", "ip": "", "type": "ETHERNET"}, {"routes": [], "status": "Connected", "rx_bytes": "441741308", "tx_bytes": "738", "mac": "22:c5:23:65:cf:3f", "name": "br-home.dhcp", "ip": "", "type": "ETHERNET"}, {"routes": [], "status": "Connected", "rx_bytes": "441742108", "tx_bytes": "738", "mac": "f6:75:12:94:d2:44", "name": "br-home.l2uf", "ip": "", "type": "ETHERNET"}, {"routes": [{"gateway": "0.0.0.0", "netmask": "255.255.255.128", "metric": "0", "dst": "169.254.171.128"}], "mac": "60:b4:f7:f1:51:56", "rx_bytes": "3437897932", "ip": "169.254.171.143", "name": "bhaul-sta-u50", "wifi_channel": 157, "status": "Connected", "wifi_phy": "wifi2", "motion_enabled": true, "tx_bytes": "12601404375", "type": "WIFI_CLIENT"}, {"routes": [], "mac": "e2:b4:f7:f1:51:54", "rx_bytes": "551517", "ip": "", "name": "home-ap-24", "wifi_channel": 11, "status": "Connected", "wifi_phy": "wifi0", "motion_enabled": true, "tx_bytes": "1473300", "type": "WIFI_AP"}, {"routes": [], "name": "br-gre-24", "rx_bytes": "0", "type": "ETHERNET", "tx_bytes": "0", "mac": "4a:b6:71:00:f2:4d", "ip": ""}, {"routes": [], "name": "ifb1", "rx_bytes": "0", "type": "ETHERNET", "tx_bytes": "0", "mac": "3e:d9:6c:08:b4:14", "ip": ""}, {"routes": [], "name": "bond0", "rx_bytes": "0", "type": "ETHERNET", "tx_bytes": "0", "mac": "ae:1c:bf:1e:ca:6a", "ip": ""}, {"routes": [{"gateway": "0.0.0.0", "netmask": "255.255.255.128", "metric": "0", "dst": "169.254.5.128"}], "mac": "d2:b4:f7:f1:51:55", "rx_bytes": "0", "ip": "169.254.5.129", "name": "bhaul-ap-l50", "wifi_channel": 60, "status": "Connected", "wifi_phy": "wifi1", "motion_enabled": true, "tx_bytes": "0", "type": "WIFI_AP"}, {"routes": [], "status": "Connected", "rx_bytes": "10462", "tx_bytes": "738", "mac": "8a:ed:81:6f:6d:7f", "name": "br-home.http", "ip": "", "type": "ETHERNET"}, {"routes": [], "name": "eth0.4", "rx_bytes": "0", "type": "ETHERNET", "tx_bytes": "0", "mac": "60:b4:f7:f1:51:52", "ip": ""}, {"routes": [{"gateway": "0.0.0.0", "netmask": "255.255.255.128", "metric": "0", "dst": "169.254.5.0"}], "mac": "f2:b4:f7:f1:51:55", "rx_bytes": "0", "ip": "169.254.5.1", "name": "onboard-ap-l50", "wifi_channel": 60, "status": "Connected", "wifi_phy": "wifi1", "motion_enabled": true, "tx_bytes": "0", "type": "WIFI_AP"}, {"routes": [{"gateway": "0.0.0.0", "netmask": "255.255.255.128", "metric": "0", "dst": "169.254.172.0"}], "mac": "f2:b4:f7:f1:51:56", "rx_bytes": "0", "ip": "169.254.172.1", "name": "onboard-ap-u50", "wifi_channel": 157, "status": "Connected", "wifi_phy": "wifi2", "motion_enabled": true, "tx_bytes": "0", "type": "WIFI_AP"}, {"routes": [], "name": "ovs-system", "rx_bytes": "0", "type": "ETHERNET", "tx_bytes": "0", "mac": "22:b2:0a:c1:4b:53", "ip": ""}, {"routes": [], "status": "Connected", "rx_bytes": "441741564", "tx_bytes": "738", "mac": "62:b4:f7:f1:51:52", "name": "br-home", "ip": "", "type": "ETHERNET"}, {"routes": [{"gateway": "0.0.0.0", "netmask": "255.255.255.128", "metric": "0", "dst": "169.254.4.128"}], "mac": "d2:b4:f7:f1:51:54", "rx_bytes": "0", "ip": "169.254.4.129", "name": "bhaul-ap-24", "wifi_channel": 11, "status": "Connected", "wifi_phy": "wifi0", "motion_enabled": true, "tx_bytes": "0", "type": "WIFI_AP"}, {"routes": [{"gateway": "192.168.10.1", "netmask": "0.0.0.0", "metric": "0", "dst": "0.0.0.0"}, {"gateway": "0.0.0.0", "netmask": "255.255.254.0", "metric": "0", "dst": "192.168.10.0"}], "status": "Connected", "rx_bytes": "2476802713", "tx_bytes": "11644910197", "mac": "60:b4:f7:f1:51:52", "name": "br-wan", "ip": "192.168.11.15", "type": "ETHERNET"}, {"routes": [], "mac": "e2:b4:f7:f1:51:55", "rx_bytes": "49542823", "ip": "", "name": "home-ap-l50", "wifi_channel": 60, "status": "Connected", "wifi_phy": "wifi1", "motion_enabled": true, "tx_bytes": "393988310", "type": "WIFI_AP"}, {"routes": [], "name": "br-gre-50", "rx_bytes": "0", "type": "ETHERNET", "tx_bytes": "0", "mac": "62:9f:93:0a:68:42", "ip": ""}, {"routes": [], "status": "Connected", "rx_bytes": "441740208", "tx_bytes": "738", "mac": "46:54:d3:1b:85:c8", "name": "br-home.upnp", "ip": "", "type": "ETHERNET"}, {"routes": [], "name": "eth0", "rx_bytes": "0", "type": "ETHERNET", "tx_bytes": "0", "mac": "60:b4:f7:f1:51:52", "ip": ""}], "ap_bssid_2ghz": "e2:b4:f7:f1:51:54", "gateway_bssid": "00:c8:8b:61:b4:49", "p2p_bssid": "", "mesh_bssid": "60:b4:f7:f1:51:56", "links": [{"vht_supported": "0", "vht_capabilities": "0x338b79f2", "wifi_txpwr": "15.000", "rx_bytes": "1748959776", "phy": "wifi2", "implicit_dsss": "0", "rssi": "-27", "rssi_db": "-27", "implicit_legacy_80_80": "0", "uptime": "451152362", "tx_failed": "0", "cv_matrix_report_count": "0", "csi_report_count": "0", "tx_retries": "0", "if_name": "bhaul-sta-u50", "aid": "0", "v_matrix_report_count": "0", "motion_state": "1", "mac": "d2:b4:f7:f1:51:14", "implicit_legacy_80": "4388656", "implicit_legacy_20": "1196", "rate_ms": "100", "ht_capabilities": "0x000009ef", "connected_time": "451152351", "implicit_legacy_40": "0", "implicit_error_count": "59261", "implicit_bw_downgrades": "1196", "implicit_legacy_160": "0", "max_rx_streams": "4", "tx_bytes": "2866029898", "tx_bitrate": "1733000000", "mconf_zero_count": 53596, "wifi_protocol": "802_11", "ht_supported": "8", "rx_bitrate": "1733000000", "implicit_measurements": "4389852", "implicit_cck": "0", "last_heard": "0", "ip": "169.254.171.129", "peer_type": "7"}, {"wifi_protocol": "WIRED", "motion_type": "MOTION_NONE", "mac": "00:c8:8b:61:b4:49", "if_name": "br-wan", "ip": "192.168.10.1"}], "_age": 0, "ts": 1575049032.09, "node_id": "4C72401397", "uptime": "451602.77", "fw_version": "221-uv3.4.2-kv3.4.2-15b78b5b3c79653c0fee0b6469c977a5894de54b-qca-wifi-cfr-dev", "deviceId": "csi-p-60b4f7f15152", "root_mode": 1, "location_id": "5d2e1d18fba27931c16e941d", "version": {"radios": {"wifi2": {"fw_version": "0.0.0.9999", "chipset": "QCA9984"}, "wifi1": {"fw_version": "0.0.0.9999", "chipset": "QCA4019"}, "wifi0": {"fw_version": "0.0.0.9999", "chipset": "QCA4019"}}, "algos": {"omot": "1.9.2"}}, "hw_id": "Qualcomm", "hw_version": "Plume SuperPod B1A", "status_time": 0.41, "mem": {"free": "285080", "avail": "327968", "total": "496180"}, "load": ["0.52", "0.53", "0.48"], "ap_bssid_5ghz": "e2:b4:f7:f1:51:55"}}}
