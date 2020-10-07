from gevent import monkey
monkey.patch_all()

import random
import mzbench
import json
import time
import paho.mqtt.client as mqtt
import os
import socket
from common.core_network_mock import CoreNetworkSimple
from common.MacAddress import MacAddress
import random
import math
import sys
import threading

booya = "test1"

def initial_state():
    pass


def metrics():
    return [
        [
            ('MQTT_Active',  'counter'),
            ('MQTT_Failure', 'counter')
        ],
        ('MQTT_Connections', 'counter'),
        [
            ('HTTP_Success', 'counter'),
            ('HTTP_Retry',   'counter'),
            ('HTTP_Fail', 'counter')
        ],
        ('Guardian', 'histogram'),
        [
            ('MQTT_Packets',  'counter'),
            ('MQTT_Heartbeat',  'counter'),
            ('MQTT_Status',  'counter'),
            ('MQTT_Motion',  'counter')
        ]
        ]



def run_registration(server):
    global mac
    global network 
    global gk_url
    #print(sys.version)
    mac=MacAddress(random.randint(0, 999999999)*256)
    time_stamp = time.time() - 31536000
    #print(mac.number())
    #print(threading.active_count())
    gk_url = "https://mns." + server + "/gatekeeper"
    network = CoreNetworkSimple( mac=mac.number(), gk_url=gk_url)
    registration = network.populate_network()
    print(registration)
    mzbench.notify(('HTTP_Success', 'counter'), 1)
    mzbench.notify(('MQTT_Connections','counter'),1)
    mzbench.notify(('MQTT_Active', 'counter'), 1)

def run_network():
    network.send_guardian_status_report()
    mzbench.notify(('MQTT_Packets', 'counter'), 1)
    mzbench.notify(('MQTT_Status', 'counter'), 1)
    for i in range(1,4):
        time.sleep(59)
        network.send_heartbeat()
        mzbench.notify(('MQTT_Packets', 'counter'), 1)
        mzbench.notify(('MQTT_Heartbeat', 'counter'), 1)


def run_heartbeat():
    network.send_heartbeat()
    mzbench.notify(('MQTT_Packets', 'counter'), 1)
    mzbench.notify(('MQTT_Heartbeat', 'counter'), 1)

def run_motion():
    network.send_motion()
    mzbench.notify(('MQTT_Packets', 'counter'), 1)
    mzbench.notify(('MQTT_Motion', 'counter'), 1)


    





