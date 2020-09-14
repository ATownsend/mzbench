import random
import mzbench
import json
import paho.mqtt.client as mqtt
import os

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

    print("Booya1")
    print(msg)
    print("Booya2")
    print(os.environ)
    print("Booya3")
    print(globals())
    print("Booya4")
    print(locals())
    print("Booya5")
    print(dir())

    mzbench.notify(('dummy', 'histogram'), random.uniform(0, 1000000000)/7)
