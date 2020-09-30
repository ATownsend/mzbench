#!/usr/bin/env python
#
# Description:  This module populates core with one ficticious
#               network with core, according to the following steps:
#
#               1. Submit status report to gatekeeper (one for each node)
#                  to form network entry and gain MQTT credentials.
#
#               2. Connect to MQTT and publish a defined number
#                  of MotionMatrixReport's.
#
import requests
import json
import time
import random

import paho.mqtt.client as mqtt
from mns.mqtt_client_simple import *
from mns.mac_address import mac_address

class core_network_mock:

    def __init__(self, mac, time, server, url = None, mqtt = None, mqtt_port = 1883, client_id = None, ssl = None, user = None, password = None):
        self.macAddress = mac_address(mac)
        #self.macAddress.setMac(mac)
        self.time = time
        self.server = server
        self.errors = 0
        self.user = user
        self.password = password
        if url is None and ssl is None:
            self.url = "http://mns." + server + "/gatekeeper"
        elif url is None and ssl is not None:
            self.url = "https://mns." + server + "/gatekeeper"
        else:
            self.url = url
        if mqtt is None:
            self.mqtt = "mqtt." + server
        self.mqtt_port = mqtt_port
        if client_id is None:
            self.client_id = "sys-" + self.macAddress.address_without_colon()
        else:
            self.client_id = client_id

    def __del__(self):
        if hasattr(self, 'mqtt_connection'):
            self.mqtt_disconnect()

    def mqtt_connect(self):
        self.mqtt_connection = mqtt_client_simple()
        self.mqtt_connection.open(self.mqtt, self.mqtt_port, self.client_id, self.user, self.password)
      
    def mqtt_disconnect(self):
        self.mqtt_connection.close()

    def gatekeeper_send_status_report(self, status):
        # Send a status report to gatekeeper.
        # This returns the request result.
        # status = create_radar_status_report(network, node)
        payload = {
            'radar_status'  : status,
            'factory_reset' : False,
            'master_failed' : False,
            'location_id'   : self.macAddress.address()
        }
        r = requests.post(self.url, json=payload)
        return r

    def gatekeeper_register_network(self, network):
        # Register a new (or existing) network by publishing radar status
        # reports to gatekeeper.
        #print("Registering network with gatekeeper @ %s..." % gatekeeper_url)
        results = []
        for node in network['nodes']:
            if node['role'] not in ['master', 'peer']:
                continue
            status = self.create_radar_status_report(network, node)
            root = self.gatekeeper_send_status_report(status)
            results.append(root)
            if root.status_code != requests.codes.ok:
                print(root.__dict__)
                raise Exception("Failed to register Root node with gatekeeper.")
            #print(self.macAddress.address())
        return results

    def core_run_mqtt_status(self,  time_stamp, interval = 5, count = 1): 
        if self.network_id is None:
            self.core_populate_network( time_stamp,1,0)
        if not hasattr(self, 'mqtt_connection'):
            self.mqtt_connect()

        network = self.core_create_dummy_network_model(self.macAddress)
        last_motion = time_stamp + (interval * (count - 1))
        report = self.create_guardian_status_report(network, time_stamp, self.client_id, self.network_id, last_motion)
        runtime_start = time.time()
        self.mqtt_connection.publish('guardian', self.client_id, 'guardian-status', report)


    def core_run_mqtt_motion(self, time_stamp, interval = 5, count = 1):
        if not hasattr(self, 'mqtt_connection'):
            self.mqtt_connect()
        if self.network_id is None:
            self.core_populate_network( time_stamp,1,0)
        
        network = self.core_create_dummy_network_model(self.macAddress)
        # Generate a dummy motion report and publish via MQTT
        report = self.create_motionmatrix_report(network, time_stamp, interval, count)

        runtime_start = time.time()
        results = self.mqtt_connection.publish('guardian', self.client_id, 'motion-matrix', report)
        if results == False:
            self.errors += 1
            print("Errors for " + self.macAddress.address()  + " : " + str(self.errors))
            self.mqtt_disconnect()
            self.mqtt_connect()
            print("Reconnected " + self.macAddress.address() )
            results = None

        #print("Run Motion " + self.macAddress.address() + " In " + str(time.time() - runtime_start) + " Time")

    def mac_address(self):
        return self.macAddress.address()

    def core_populate_network(self, time_stamp, interval, count):
        interval = int(interval)
        count = int(count)
        # Create a dummy network model using the given mac prefix string
        network = self.core_create_dummy_network_model(self.macAddress)
        runtime_start = time.time()
        # Register the network with gatekeeper
        results = self.gatekeeper_register_network(network)
        runtime_gatekeeper_registration = time.time()
        master_cred = results[0].json()
        #print(master_cred)
        self.network_id  = master_cred['local_config']['guardian_mqtt']['network_id']
        guardian_config = master_cred['local_config']['guardian_mqtt']
        radar_config    = master_cred['local_config']['radar_mqtt']
        #############################################################################if count > 0
        # Extract MQTT client connection information from the gatekeeper
        # result for the master.
        self.client_id = guardian_config['guardian_id']
        self.user  = "device"
        self.password  = guardian_config['mqToken']
        self.mqtt      = guardian_config['mqServer']
        self.mqtt_port = guardian_config['mqPort']
        self.guardian_id = guardian_config['guardian_id']
        self.guardian_type = guardian_config['mqType']
        # Generate a dummy motion report and publish via MQTT
        # Create guardian status report
        # This allows us to access the last_motion metric, and update radar statuses.
        runtime_start_mqtt = 0
        runtime_end_mqtt = 0

        if count > 0:
            if not hasattr(self, 'mqtt_connection'):
                self.mqtt_connect()
            last_motion = time_stamp + (interval * (count - 1))
            guardianReport = self.create_guardian_status_report(network, time_stamp, self.guardian_id, self.network_id, last_motion)
            motionReport = self.create_motionmatrix_report(network, time_stamp, interval, count)
            runtime_start_mqtt = time.time()
            self.mqtt_connection.publish('guardian', self.client_id, 'motion-matrix', motionReport)
            self.mqtt_connection.publish('guardian', self.client_id, 'guardian-status', guardianReport)
            runtime_end_mqtt = time.time()

        runtimes = {"total": time.time() - runtime_start, "gatekeeper": runtime_gatekeeper_registration - runtime_start, "mqtt": runtime_end_mqtt - runtime_start_mqtt }
        response_code = results[0].status_code
        full_resp = results[0].json()
        results = {"runtimes": runtimes, "network_id":self.network_id, "guardian_id":self.guardian_id, "guardian_type":self.guardian_type, "response_code":response_code, "full_results": full_resp, "network": network, "mqtt_token": guardian_config["mqToken"]}
        return results

    @staticmethod
    def mac_to_linkstr(mac):
        return mac.replace(":", "")[-6:]

    @staticmethod
    def core_create_dummy_network_model(mac_address):
        # Define a 3-node mesh network, where one acts as the gateway.
        network = {
            # External IP assigned to the master wan0 ethernet
            # interface.
            "ip": "10.0.0.0",
            
            # Gateway mac and IP address
            "gateway": {
                "mac": "ff:00:00:00:00:00",
                "ip":  "10.0.0.0"
            },

            "nodes": [
                {
                # Master node
                    "role":          "master",
                    "mesh_mac":      mac_address.address(),
                    "eth_mac":       mac_address.offset(1),
                    "wlan_2ghz_mac": mac_address.offset(2),
                    "wlan_5ghz_mac": mac_address.offset(3),
                    "peers": [ 1, 2, 3 ]
                },

                {
                # Peer node 1
                    "role":          "peer",
                    "mesh_mac":      mac_address.offset("10"),
                    "eth_mac":       mac_address.offset("11"),
                    "wlan_2ghz_mac": mac_address.offset("12"),
                    "wlan_5ghz_mac": mac_address.offset("13"),
                    "peers": [ 0, 2, 4 ]
                },

                {
                # Peer node 2
                    "role":          "peer",
                    "mesh_mac":      mac_address.offset("20"),
                    "eth_mac":       mac_address.offset("21"),
                    "wlan_2ghz_mac": mac_address.offset("22"),
                    "wlan_5ghz_mac": mac_address.offset("23"),
                    "peers": [ 0, 1, 5 ]
                },

                {
                # Leaf node 1 (connected to Master)
                    "role":     "leaf",
                    "mesh_mac": mac_address.offset("30"),
                    "peers":    [ 0 ]
                },

                {
                # Leaf node 2 (connected to Peer node 1)
                    "role":     "leaf",
                    "mesh_mac": mac_address.offset("40"),
                    "peers":    [ 1 ]
                },

                {
                # Leaf node 3 (connected to Peer node 2)
                    "role":     "leaf",
                    "mesh_mac": mac_address.offset("50"),
                    "peers":    [ 2 ]
                },
            ]
        }
        return network

    @staticmethod
    def create_motionmatrix_report(network, time_stamp, interval, count, report_type = "motion"):
        # Create a dummy motion matrix report

        if report_type == "matrix":
            data_key = "data"
        else:
            data_key = "motion"

        report = {
            "ts":       time_stamp,
            "interval": interval * 100,
            "count":    count,
            data_key: {
                "mkai":[],
                "throughput":[]
                },
            "links": []
        }
        # Generate link list combinations (using the mesh macs in the
        # network).
        for i in range(len(network['nodes'])-1):
            for j in range(i+1, len(network['nodes'])):
                src_mac = network['nodes'][i]['mesh_mac']
                dest_mac = network['nodes'][j]['mesh_mac']
                report['links'].append(core_network_mock.mac_to_linkstr(src_mac) + "-" + core_network_mock.mac_to_linkstr(dest_mac))

        for l in range(len(report['links'])):
            mkai = []
            throughput = []
            for x in range(report['count']):
                mkai.extend([random.random()])
                throughput.extend([random.random()])
            report[data_key]['mkai'].append(mkai)
            report[data_key]['throughput'].append(throughput)
        return report


    @staticmethod
    def create_guardian_status_report(network, time_stamp, guardian_id, network_id, last_motion):
        radar_reports = []
        for node in network['nodes']:
            if node['role'] not in ['master', 'peer']:
                continue
            radar_reports.append(core_network_mock.create_radar_status_report(network, node))

        report = {
            'ts':          time_stamp,
            'guardian_id': guardian_id,
            'network_id':  network_id,
            'radars':      radar_reports,
            'last_motion': last_motion
        }
        return report

    @staticmethod
    def create_radar_status_report(network, node):
        # Create a dummy-status block for a given network node,
        # such that we can get a valid response from gatekeeper
        # with it.

        # Master node must be first one
        master_node = network['nodes'][0]

        # Create empty status report
        status = {
            'deviceId':      "test-" + node['eth_mac'].replace(":", ""),
            'ts':            0.0,
            'interfaces':    [],
            'links':         [],
            'ap_bssid_2ghz': node['wlan_2ghz_mac'],
            'ap_bssid_5ghz': node['wlan_5ghz_mac'],
            'mesh_bssid':    node['mesh_mac'],
            'gateway_bssid': master_node['mesh_mac'],
            'root_mode':    1

        }

        # Override gateway bssid for master node:
        if node == master_node:
            status['gateway_bssid'] = network['gateway']['mac']
            status['root_mode'] = 2


        # Add wan0 ethernet interface with default gateway,
        # but only set its' type to ETHERNET if this is the master.
        if node == master_node:
            if_type = 'ETHERNET'
        else:
            if_type = 'BRIDGE'

        interface = {
            'name': "wan0",
            'type': if_type,
            'mac':  node['eth_mac'],
            'ip': "10.22.22.1",
            'routes': [
                {
                    "dst": "0.0.0.0"
                }
            ]
        }    
        status['interfaces'].append(interface)

        # Populate link list for all local peers
        # This is what is actually used to form the network.
        for peer_id in node['peers']:
            peer_node = network['nodes'][peer_id]

            link_entry = {
                "mac":       peer_node['mesh_mac'],
                "peer_type": "7"
            }

            if peer_node['role'] == "leaf":
                link_entry['peer_type'] = "2"

            status['links'].append(link_entry)
        return status