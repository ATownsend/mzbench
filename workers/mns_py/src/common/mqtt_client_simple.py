#!/usr/bin/env python
#
# Description:  Simple MQTT client specifically for communicating with Halo Core.
#
# Author:       Trevor Pace
# Date Created: 3-1-2019

import json, time, ssl
import paho.mqtt.client as mqtt

class mqtt_client_simple():
    def __init__(self):
        self.cl = None

    def open(self, server, port, client_id, username, password, ssl=False, ci="none"):
        self.cl = mqtt.Client(client_id=client_id)
        self.cl.username_pw_set(username=username, password=password)
        
        if ssl:
            from run_tests import config
            if ci != "none":
                ca = "%s/certs/DST_Root_CA_X3.pem" % (ci)
                cert = "%s%s" % (ci, config["mqtt"]["cert"])
                key = "%s%s" % (ci, config["mqtt"]["key"])
            else:
                ca = "/etc/ssl/certs/DST_Root_CA_X3.pem" # Local Ubuntu only
                cert = ".%s" % (config["mqtt"]["cert"])
                key = ".%s" % (config["mqtt"]["key"])
        
            self.cl.tls_set(ca, cert, key)
            
        self.cl.connect(server, port)
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
