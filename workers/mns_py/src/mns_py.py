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

    print(msg)
    print(os.environ)
    print(globals())
    print(locals())
    print(worker_id)

    mzbench.notify(('dummy', 'histogram'), random.uniform(0, 1000000000)/7)
