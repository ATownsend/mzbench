#!/usr/bin/env python3 
#
# Description:  This module populates core with num_networks of ficticious
#               network with core.
import threading
import requests
import json
import time
import random
import traceback
import queue
from common.mac_address import mac_address
from common.core_network_mock import core_network_mock
import sys


def core_create_networks(server, num_networks, time_stamp, interval, count_per_report, number_of_threads, mac_address, user=None, password=None):
    networks = {}
    if num_networks < number_of_threads:
        number_of_threads = num_networks
    for i in range(number_of_threads):
        networks[i] = []
    network = 0
    while network < num_networks:
        for i in range(number_of_threads):
            network += 1
            mac_address.increment_mac_section(2,1)
            if network > num_networks:
                break
            networks[i].append(core_network_mock(   mac=mac_address.address(),  time=time_stamp,     server=server, ssl=True))
            #                  core_network_mock(   mac,                    time,   server, url = None, mqtt = None, mqtt_port = 1883, client_id = None):
    for i in range(number_of_threads):
        t=threading.Thread(target=create_network, args=[networks[i], time_stamp, interval, count_per_report])
        t.setDaemon(True)
        t.start()
    for t in threading.enumerate():
        if t.daemon:
            t.join()
    #for i in range(number_of_threads)
    returnValue = []
    for i in networks:
        returnValue.extend(networks[i])
    return(returnValue)
    
def create_network(networks, time_stamp, interval, count_per_report):
    trace = ""
    for network in networks:
        runtime_start = time.time()
        networkFail = True
        while networkFail == True:
            try:
                results = network.core_populate_network(time_stamp, interval, count_per_report)
                print("Created Network " + str(results["network_id"]) + " " + str(results["guardian_id"]) + " In " + str(time.time() - runtime_start) + " Time")
                networkFail = False
            except:
                trace = traceback.format_exc()
                e = sys.exc_info()[0]
                print("Error Time: " + str(time.time() - runtime_start) )
                print("System " + network.mac_address())
                print("Error: " + str(e) )
            finally:
                print(trace)
                trace = ""



def core_run_motion(server, num_networks, time_stamp, interval, count_per_report, number_of_threads, mac_address, loopTime = 300, user=None, password=None):
    networks = core_create_networks(server, num_networks, time_stamp, interval, 0, 100, mac_address)
    print("Networks Created")
    networksCollection = {}
    for i in range(number_of_threads):
        networksCollection[i] = []
    network = 0
    while network < num_networks:
        for i in range(number_of_threads):
            network += 1
            networksCollection[i].append(networks.pop())
            #                  core_network_mock(   mac,                    time,   server, url = None, mqtt = None, mqtt_port = 1883, client_id = None):
    for i in range(number_of_threads):
        t=threading.Thread(target=run_motion, args=[networksCollection[i], time_stamp, interval, count_per_report, loopTime])
        t.setDaemon(True)
        t.start()
    for t in threading.enumerate():
        if t.daemon:
            t.join()

def run_motion(networks, time_stamp, interval, count_per_report, loopTime = None):
    sleep_interval = loopTime / len(networks)
    sleep_interval = sleep_interval / 10
    print(sleep_interval)
    random_start = random.randint(0,60)
    time.sleep(random_start)
    while True:
        time_stamp = time_stamp + (interval + count_per_report)
        thread_start = time.time()
        for network in networks:
            trace = ""
            runtime_start = time.time()
            #network.core_run_mqtt_motion(time_stamp, interval, count_per_report)
            try:
                network.core_run_mqtt_motion(time_stamp, interval, count_per_report)
                # def core_run_mqtt_motion(time_stamp, interval = 5, count = 1):
                print("Run Motion " + network.mac_address() + " For Timestamp:" + str(time_stamp) + " In " + str(time.time() - runtime_start) + " Time  at " + str(time.time()) )
            except:
                e = sys.exc_info()[0]
                print("Error Time: " + str(time.time() - runtime_start) )
                print("Error: " + str(e) )
                trace = traceback.format_exc()
                network.mqtt_disconnect()
            finally:
                print(trace)
                trace = ""
            time.sleep(sleep_interval)
        print("Loop of Systems time: " + str(time.time() - thread_start))
        print(time.strftime("%H:%M:%S"))
        if loopTime is not None:
            sleepTime = int(loopTime - (time.time() - thread_start))
            if sleepTime < 0:
                sleepTime = 0
            print("SleepTime: " + str(sleepTime))
            time.sleep(sleepTime)


def core_run_status(server, num_networks, time_stamp, interval, count_per_report, number_of_threads, mac_address, user=None, password=None):
    networks = core_create_networks(server, num_networks, time_stamp, interval, 0, 50, mac_address)
    print("Networks Created")
    if number_of_threads > 1:
        networksCollection = [networks[i:i + int(number_of_threads)] for i in range(0, (number_of_threads - 1) * int(number_of_threads), int(number_of_threads))]
        for collection in networksCollection:
            t=threading.Thread(target=run_status, args=[collection, time_stamp, interval, count_per_report])
            t.setDaemon(True)
            t.start()
        for t in threading.enumerate():
            if t.daemon:
                t.join()
    else:
        run_status(networks, time_stamp, interval, count_per_report)
    
def run_status(networks, time_stamp, interval, count_per_report):
    while True:
        time_stamp = time_stamp + (interval + count_per_report)
        thread_start = time.time()
        for network in networks:
            trace = ""
            runtime_start = time.time()
            #network.core_run_mqtt_motion(time_stamp, interval, count_per_report)
            try:
                network.core_run_mqtt_status(time_stamp, interval, count_per_report)
                # def core_run_mqtt_motion(time_stamp, interval = 5, count = 1):
                print("Run Status " + network.mac_address() + " In " + str(time.time() - runtime_start) + " Time")
            except:
                e = sys.exc_info()[0]
                print("Error Time: " + str(time.time() - runtime_start) )
                print("Error: " + str(e) )
                trace = traceback.format_exc()
            finally:
                print(trace)
                trace = ""
        print ("Loop of Systems time: " + str(time.time() - thread_start))



if __name__ == '__main__':
    #core_create_networks("corelt.cloudops.wifimotion.ca",   100,            946684800,  5,          60,     10,                 mac_address("D", 0))
    #core_create_networks(server,                           num_networks,   time_stamp, interval,   count_per_report,  number_of_threads,  mac_address)

    core_run_motion("corelt.cloudops.wifimotion.ca",    1000,            946684800,  5,          60,                 10,                 mac_address("D", 0))
    #def core_run_motion(server,                        num_networks,   time_stamp, interval,   count_per_report,   number_of_threads,  mac_address):

    #core_run_status("corelt.cloudops.wifimotion.ca",    100,            946684800,  5,          60,                 10,                 mac_address("D", 0))













    #mac = mac_address("D", 0)
    #results = core_network_mock(mac.address(), 0, "corelt.cloudops.wifimotion.ca")
    #results.core_populate_network(1,1,1)
    #print(results)