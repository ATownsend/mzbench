import random
import mzbench
import json
import time
import paho.mqtt.client as mqtt
import os
import socket
from mns.core_network_mock import core_network_mock
from mns.mac_address import mac_address
import random
import math
import sys

def initial_state():
    pass


def metrics():
    return [
        [
            ('Active',  'counter'),
            ('Failure', 'counter')
        ],
        ('MQTT Connections', 'histogram')
    ],
    [
        [
            ('Success', 'counter'),
            ('Retry',   'counter'),
            ('HTTPFail', 'counter')
        ],
        ('Guardian', 'histogram')
        ]


def run_baseline(server):
    mzbench.notify(('print', 'counter'), 1)
    mzbench.notify(('print_2', 'counter'), 2)
    print(sys.version)
    mac=mac_address(random.randint(0, 999999999)*256)
    time_stamp = time.time() - 31536000
    print(mac.address())
    print(mac.number())
    network = core_network_mock( mac=mac.number(), time=time_stamp, server=server, ssl=True)
    mzbench.notify(('Active', 'counter'), 1)
    network.core_populate_network(time_stamp, 30, 60)
    #network.core_run_mqtt_status(time_stamp, interval, count_per_report)
    #print(mzbench.get_worker_id())
    #print("Booya1")
    #print(msg)
    #print("Booya2")
    #print(os.environ)
    #print("Booya3")
    #print(globals())
    #print("Booya4")
    #print(locals())
    #print("Booya5")
    #print(dir())
    #print("Booya6")
    #print(socket.gethostname())
    #print("Booya7")
    #print(os.getusername())


    





