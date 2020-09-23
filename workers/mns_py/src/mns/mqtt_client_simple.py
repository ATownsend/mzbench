#!/usr/bin/env python
#
# Description:  Simple MQTT client specifically for communicating with Halo Core.
#
# Author:       Trevor Pace
# Date Created: 3-1-2019

import json
import paho.mqtt.client as mqtt
import time

class mqtt_client_simple():
    def __init__(self):
        self.cl = None

    def open(self, server, port, client_id, username, password):
        #print("MQTT: Connecting to client @ %s:%s..." % (server, port))
        #print("MQTT: Credentials: client_id='%s', username='%s', password='%s'" % (client_id, username, password))

        self.cl = mqtt.Client(client_id=client_id)
        self.cl.username_pw_set(username=username, password=password)
        self.cl.connect(server, port=port)
        self.cl.loop_start()

    def publish(self, device_type, device_id, event, data):
        # Blocking call to send a report to an MQTT client
        topic = "iot-2/type/%s/id/%s/evt/%s/fmt/json" % (device_type, device_id, event)

        #print("MQTT: Publishing report on topic '%s'..." % topic)
        check=0
        msg_info = self.cl.publish(topic, json.dumps(data))
        if msg_info.is_published() == False:
            while msg_info.is_published() == False:
                if check == 0:
                    check = 0
                else:
                    time.sleep(1)
                check += 1
                if check > 30:
                    return False

            #msg_info.wait_for_publish()

    def close(self):
        #print("MQTT: Closing client connection...")

        self.cl.disconnect()
        self.cl.loop_stop()
        self.cl = None
