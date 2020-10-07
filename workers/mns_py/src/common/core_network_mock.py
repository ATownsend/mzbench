####################################
# Imports
####################################
import requests
import random
import uuid
import time
import sys

from .MqttClient import MqttClient
from .MacAddress import MacAddress

class CoreNetworkSimple:
    def __init__(
        self,
        mac=None,
        gk_url=None
    ):
        if gk_url is None:
           raise Exception('full gk_url must be provided')
           
        self.macAddress = MacAddress(mac=mac if mac is not None else random.randint(0, 10000000000))
        self.location_id = "location-id-%s" % (uuid.uuid4())
        self.network = self._core_create_dummy_network_model()
        self.gk_url = gk_url
        
    def populate_network(self, mqtt_status = True, mqtt_history = True):
        runtime_start = time.time()

        # Register
        results = self._gatekeeper_register_network()
        runtime_gatekeeper_registration = time.time()
        self.network_id = self.guardian_mqtt['network_id']
        self.guardian_type = self.guardian_mqtt["mqType"]

        # Initialize history
        if mqtt_status or mqtt_history:
            self._mqtt_connect()
            
            guardianReport = self._create_guardian_status_report()
            motionReport = self._create_motionmatrix_report()
            
            if mqtt_status:
              self.mqtt_publish("guardian-status", guardianReport)
            if mqtt_history:
              self.mqtt_publish("motion-matrix", motionReport)

        # Return stats
        runtime_end_mqtt = time.time()
        runtimes = {
            "total": runtime_end_mqtt - runtime_start,
            "gatekeeper": runtime_gatekeeper_registration - runtime_start,
            "mqtt": runtime_end_mqtt - runtime_gatekeeper_registration,
        }
        return {'results': results, 'runtimes': runtimes}
            
    def mqtt_publish(self, event, data):
        self.mqtt_connection.publish(self.guardian_type, self.location_id, event, data)
    
    def send_guardian_status_report(self, timestamp = time.time()):
        guardianReport = self._create_guardian_status_report(timestamp)
        self.mqtt_publish("guardian-status", guardianReport)

    def send_heartbeat(self, timestamp = time.time()):
        guardianReport = self._create_guardian_status_report(timestamp, heartbeat = True)
        self.mqtt_publish("guardian-status", guardianReport)

    def send_motion(self, timestamp = time.time()):
        motionReport = self._create_motionmatrix_report(timestamp = timestamp)
        self.mqtt_publish("motion-matrix", motionReport)

    #--- Internal API past this point
    
    def __del__(self):
        if hasattr(self, "mqtt_connection"):
            self._mqtt_disconnect()

    @property
    def guardian_mqtt(self):
        return self.network['nodes'][0]['gk_reply']['local_config']['guardian_mqtt']
    
    def _mqtt_connect(self):
        conninfo = self.guardian_mqtt
        self.mqtt_connection = MqttClient()
        self.mqtt_connection.open(
            conninfo['mqServer'], conninfo['mqPort'], self.location_id, 'device', conninfo['mqToken']
        )

    def _mqtt_disconnect(self):
        self.mqtt_connection.close()
        delattr(self, "mqtt_connection")

    def _core_create_dummy_network_model(self):
        mac_address = self.macAddress
        
        # Define a 3-node mesh network, where one acts as the gateway.
        network = {
            # External IP assigned to the master wan0 ethernet
            # interface.
            "ip": "10.0.0.0",
            # Gateway mac and IP address
            "gateway": {"mac": "ff:00:00:00:00:00", "ip": "10.0.0.0"},
            "nodes": [
                {
                    # Master node
                    "role": "master",
                    "mesh_mac": mac_address.address(),
                    "eth_mac": mac_address.offset(1),
                    "wlan_2ghz_mac": mac_address.offset(2),
                    "wlan_5ghz_mac": mac_address.offset(3),
                    "peers": [1, 2, 3],
                },
                {
                    # Peer node 1
                    "role": "peer",
                    "mesh_mac": mac_address.offset("10"),
                    "eth_mac": mac_address.offset("11"),
                    "wlan_2ghz_mac": mac_address.offset("12"),
                    "wlan_5ghz_mac": mac_address.offset("13"),
                    "peers": [0, 2, 4],
                },
                {
                    # Peer node 2
                    "role": "peer",
                    "mesh_mac": mac_address.offset("20"),
                    "eth_mac": mac_address.offset("21"),
                    "wlan_2ghz_mac": mac_address.offset("22"),
                    "wlan_5ghz_mac": mac_address.offset("23"),
                    "peers": [0, 1, 5],
                },
                {
                    # Leaf node 1 (connected to Master)
                    "role": "leaf",
                    "mesh_mac": mac_address.offset("30"),
                    "peers": [0],
                },
                {
                    # Leaf node 2 (connected to Peer node 1)
                    "role": "leaf",
                    "mesh_mac": mac_address.offset("40"),
                    "peers": [1],
                },
                {
                    # Leaf node 3 (connected to Peer node 2)
                    "role": "leaf",
                    "mesh_mac": mac_address.offset("50"),
                    "peers": [2],
                },
            ],
        }
        return network

    def _gatekeeper_register_network(self):
        # Register a new (or existing) network by publishing radar status
        # reports to gatekeeper.
        # print("Registering network with gatekeeper @ %s..." % gatekeeper_url)
        results = []
        for node in self.network["nodes"]:
            counter = 2
            if node["role"] not in ["master", "peer"]:
                    continue

            status = self._create_radar_status_report(node)
            payload = {
                "radar_status": status,
                "factory_reset": False,
                "master_failed": False,
                "location_id": self.location_id,
            }
                
            while True:
                root = requests.post(self.gk_url, json=payload)
                if counter == 0:
                    print(root.__dict__)
                    raise Exception("Failed to register %s with gatekeeper, after 3 tries." % node)
                elif root.status_code == 200:
                    node['gk_reply'] = root.json()
                    results.append(root)
                    break
                else:
                    rand_number = random.randint(10, 30)
                    print("Retrying in %i" % rand_number)
                    time.sleep(rand_number)
                    counter -= 1
                    
        return results

    def _create_motionmatrix_report(self, timestamp = time.time(), interval = 500, count = 1, report_type="matrix"):
        # Create a dummy motion matrix report
        def mac_to_linkstr(mac):
            return mac.replace(":", "")[-6:]

        data_key = "data" if report_type == "matrix" else "motion"

        report = {
            "ts": timestamp,
            "interval": interval,
            "count": count,
            data_key: {"mkai": [], "throughput": []},
            "links": [],
        }

        # Generate link list combinations (using the mesh macs in the
        # network).
        for i in range(len(self.network["nodes"]) - 1):
            for j in range(i + 1, len(self.network["nodes"])):
                src_mac = self.network["nodes"][i]["mesh_mac"]
                dest_mac = self.network["nodes"][j]["mesh_mac"]
                report["links"].append( mac_to_linkstr(src_mac) + "-" + mac_to_linkstr(dest_mac) )

        for l in range(len(report["links"])):
            # Omit the outer arrays when count=1
            if count == 1:
              mkai = random.random()
              throughput = 1.0
            else:
              mkai = [random.random() for x in range(report["count"])]
              throughput = [1.0]*report["count"]
            report[data_key]["mkai"].append(mkai)
            report[data_key]["throughput"].append(throughput)
        
        return report




    def _create_guardian_status_report(self, timestamp = time.time(), heartbeat = False):
        report = {
            "ts": timestamp if timestamp is not None else time.time(),
            "guardian_id": self.location_id,
            "network_id": self.network_id,
            "last_motion": time.time(),
            "motion_enabled": 1,
            "motion_tripped": 0
        }

        if heartbeat == False:
            radar_reports = {}
            for node in self.network["nodes"]:
                if node["role"] not in ["master", "peer"]:
                    continue
                radar_reports["test-" + node["eth_mac"].replace(":", "")] = self._create_radar_status_report(node)
            report["radars"] = radar_reports

        return report

    def _create_radar_status_report(self, node, timestamp = time.time()):
        # Create a dummy-status block for a given network node,
        # such that we can get a valid response from gatekeeper
        # with it.

        # Master node must be first one
        master_node = self.network["nodes"][0]
        timestamp = time.time()

        # Create empty status report
        status = {
            "location_id": self.location_id,
            "deviceId": "test-" + node["eth_mac"].replace(":", ""),
            "ts": timestamp,
            "interfaces": [],
            "links": [],
            "ap_bssid_2ghz": node["wlan_2ghz_mac"],
            "ap_bssid_5ghz": node["wlan_5ghz_mac"],
            "mesh_bssid": node["mesh_mac"],
            "gateway_bssid": master_node["mesh_mac"],
            "root_mode": 1,
        }

        # Override gateway bssid for master node:
        if node == master_node:
            status["gateway_bssid"] = self.network["gateway"]["mac"]
            status["root_mode"] = 2

        # Add wan0 ethernet interface with default gateway,
        # but only set its' type to ETHERNET if this is the master.
        if node == master_node:
            if_type = "ETHERNET"
        else:
            if_type = "BRIDGE"

        interface = {
            "name": "wan0",
            "type": if_type,
            "mac": node["eth_mac"],
            "ip": "10.22.22.1",
            "routes": [{"dst": "0.0.0.0"}],
        }
        status["interfaces"].append(interface)

        # Populate link list for all local peers
        # This is what is actually used to form the network.
        for peer_id in node["peers"]:
            peer_node = self.network["nodes"][peer_id]

            link_entry = {"mac": peer_node["mesh_mac"], "peer_type": "7"}

            if peer_node["role"] == "leaf":
                link_entry["peer_type"] = "2"

            status["links"].append(link_entry)
            
        return status
 
