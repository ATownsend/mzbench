import random
import mzbench
import json
import time
import paho.mqtt.client as mqtt
import os
import socket
import mns.core_network_mock
import mns.mac_address as mac_address
import random

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


def my_print(msg):
    mzbench.notify(('print', 'counter'), 1)
    mzbench.notify(('print_2', 'counter'), 2)

    mac=mac_address.address(random.randint(0, 999999999))
    print("Booya0")
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





