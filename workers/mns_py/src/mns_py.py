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

def initial_state():
    pass


def metrics():
    return [
        [
            ('print', 'counter'),
            ('print_2', 'counter')
        ],
        ('dummy', 'histogram')
    ]


def run_baseline(server):
    mzbench.notify(('print', 'counter'), 1)
    mzbench.notify(('print_2', 'counter'), 2)

    mac=mac_address(random.randint(0, 999999999)*256)
    time_stamp = time.time() - 31,536,000
    network = core_network_mock( mac=mac, time=time_stamp, server=server, ssl=True)
    network.core_populate_network(time_stamp, interval, count_per_report)
    print("Booya0")
    print(random_number)
    print(mac.address())
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


    mzbench.notify(('dummy', 'histogram'), random.uniform(0, 1000000000)/7)





