####################################
# Imports
####################################
import json
import paho.mqtt.client as mqtt
import gevent

####################################
# MqttClient Class Definition
####################################

class MqttClient:
    def __init__(self):
        self.cl = None
        
    def on_connect(self, client, *args):
        print('MQTT connected', self.client_id, args)

    def on_disconnect(self, client, *args):
        print('MQTT disconnected', self.client_id, args)
               
    def open(self, server, port, client_id, username, password):
        self.client_id = client_id
        
        self.cl = mqtt.Client(client_id=client_id)
        self.cl.username_pw_set(username=username, password=password)
        self.cl.connect(server, port=port)
        self.cl.on_connect = self.on_connect
        self.cl.on_disconnect = self.on_disconnect
                
        self.glet = gevent.spawn(self.cl.loop_forever)

    def publish(self, device_type, device_id, event, data):
        # Blocking call to send a report to an MQTT client
        topic = "iot-2/type/%s/id/%s/evt/%s/fmt/json" % (device_type, device_id, event)

        check = 0
        msg_info = self.cl.publish(topic, json.dumps(data), qos=1)
        if not msg_info.is_published():
            while not msg_info.is_published():
                gevent.sleep(0.1)
                check += 1
                if check > 300:
                    print("Failed to publish to MQTT")
                    return False
                    
        print("MQTT published ",event,"to", self.client_id)

    def close(self):
        print("MQTT disconnect in progress", self.client_id)
        self.cl.disconnect()
        gevent.joinall([self.glet])
        self.cl = None
