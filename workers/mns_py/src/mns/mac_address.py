class mac_address:
    def __init__(self, header = 0, start = 1):
        self.setNewMac(header, start)

    def __init__(self, mac = 0):
        self.setMac(mac)
    
    def setNewMac(self, header = 0, start = 1):
        header = int(str(header), 16)
        start = int(str(start), 16)
        self.number = int((header * (16 ** 10)) + (start * (16 ** 6)))
    
    def setMac(self, mac):
        if isinstance(mac, str):
            self.number = self.mac_address_to_number(mac)
        else:
            self.number = mac

    def address(self):
        return self.convert_int_to_mac(self.number)

    def address_without_colon(self):
        return "{:012x}".format(self.number)

    def __repr__(self):
        return self.convert_int_to_mac(self.number)

    def number(self):
        return self.number

    def increment(self, step = 1):
        self.number += step

    def offset(self, step):
        return self.convert_int_to_mac(self.add_to_mac_address(self.number, step))

    def increment_mac_section(self, section_to_increment = 1, step = 1):
        ##Increments a section of a mac address (string or number)
        ## Sections:
        ##    6  5  4  3  2  1
        ##   de:e1:48:49:8b:ca
        ##
        self.number += 1 * 16 ** ((section_to_increment * 2) - 2)

    @staticmethod
    def add_to_mac_address(mac, step):
        if isinstance(step, str):
            step = mac_address.mac_address_to_number(step)
        if isinstance(mac, str):
            return mac_address.convert_int_to_mac(mac_address.mac_address_to_number(mac) + step)
        else:
            return (mac + step)

    @staticmethod
    def mac_address_to_number(mac):
        mac = mac.replace(":", "")
        return int(str(mac), 16)

    @staticmethod
    def convert_int_to_mac(mac):
        return "%02X:%02X:%02X:%02X:%02X:%02X" % (  (mac >> 40) & 0xFF,
                                                    (mac >> 32) & 0xFF,
                                                    (mac >> 24) & 0xFF,
                                                    (mac >> 16) & 0xFF,
                                                    (mac >> 8)  & 0xFF,
                                                    (mac >> 0)  & 0xFF)

#01:00:00:00:00:01
#00:00:00:00:00:01