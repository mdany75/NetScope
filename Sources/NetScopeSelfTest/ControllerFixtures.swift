import Foundation

// Note 77 : réponses de démonstration des API UniFi Network, Omada et Meraki, recopiées de la forme
// donnée par leur documentation publique (exemples de réponses, noms de champs) puis adaptées
// (adresses privées, noms fictifs). Aucune n'a été relevée sur un vrai contrôleur : elles fixent
// la forme lue par NetScope, à confronter au premier essai réel.

enum UniFiFixtures {
    static let sites = """
    {"meta":{"rc":"ok"},"data":[
      {"_id":"5f1a2b3c4d5e6f7a8b9c0d01","name":"default","desc":"Default","role":"admin"},
      {"_id":"5f1a2b3c4d5e6f7a8b9c0d02","name":"ab12cd34","desc":"Clinique","role":"admin"}]}
    """

    static let sysinfo = """
    {"meta":{"rc":"ok"},"data":[{"timezone":"America/Toronto","version":"9.0.114","build":"atag_9.0.114_27077",
      "name":"UDM-Pro-Clinique","hostname":"UDM-Pro-Clinique","update_available":false}]}
    """

    static let networks = """
    {"meta":{"rc":"ok"},"data":[
      {"_id":"60aa0000000000000000a001","name":"Default","purpose":"corporate","vlan_enabled":false,"ip_subnet":"192.168.1.1/24"},
      {"_id":"60aa0000000000000000a020","name":"Imagerie","purpose":"corporate","vlan_enabled":true,"vlan":20},
      {"_id":"60aa0000000000000000a0ff","name":"Internet","purpose":"wan"}]}
    """

    static let devices = """
    {"meta":{"rc":"ok"},"data":[
      {"_id":"61bb01","type":"usw","model":"US24PRO","name":"USW-Pro-Clinique","mac":"74:ac:b9:10:20:30","ip":"192.168.1.2",
       "version":"6.6.61.15220","serial":"74ACB9102030","state":1,"adopted":true,"uptime":864000,"total_max_power":400,
       "port_table":[
         {"port_idx":1,"name":"Port 1","media":"GE","up":true,"enable":true,"speed":1000,"full_duplex":true,"is_uplink":true,
          "port_poe":true,"poe_enable":false,"poe_mode":"off","rx_bytes":91234567890,"tx_bytes":12345678901,"rx_errors":0,
          "native_networkconf_id":"60aa0000000000000000a001"},
         {"port_idx":2,"name":"Imprimante","media":"GE","up":true,"enable":true,"speed":100,"full_duplex":true,
          "port_poe":true,"poe_enable":false,"poe_mode":"off","native_networkconf_id":"60aa0000000000000000a020",
          "rx_errors":12},
         {"port_idx":3,"name":"Port 3","media":"GE","up":true,"enable":true,"speed":1000,"full_duplex":true,
          "port_poe":true,"poe_enable":true,"poe_mode":"auto","poe_power":"8.42","poe_class":"Class 4",
          "native_networkconf_id":"60aa0000000000000000a001"},
         {"port_idx":4,"name":"Port 4","media":"GE","up":false,"enable":true,"speed":0,"port_poe":true,"poe_enable":true,"poe_power":"0.00"},
         {"port_idx":5,"name":"Poste réception","media":"GE","up":true,"enable":true,"speed":1000,"full_duplex":true,
          "port_poe":false,"native_networkconf_id":"60aa0000000000000000a001"}],
       "lldp_table":[{"chassis_id":"d8:b3:70:aa:bb:01","port_id":"eth0","local_port_idx":3,"local_port_name":"Port 3","is_wired":true}],
       "uplink":{"type":"wire","uplink_mac":"24:5a:4c:00:00:01","uplink_remote_port":9}},
      {"_id":"61bb02","type":"uap","model":"UAL6","name":"U6-Accueil","mac":"d8:b3:70:aa:bb:01","ip":"192.168.1.21",
       "version":"6.6.77.15402","serial":"D8B370AABB01","state":1,"uptime":432000,"num_sta":2,
       "radio_table":[{"name":"wifi0","radio":"ng","channel":6,"ht":"20","max_txpower":23},
                      {"name":"wifi1","radio":"na","channel":44,"ht":"80","max_txpower":26}],
       "radio_table_stats":[{"name":"wifi0","radio":"ng","channel":6,"tx_power":17,"num_sta":0,"cu_total":31},
                            {"name":"wifi1","radio":"na","channel":44,"tx_power":20,"num_sta":2,"cu_total":12}],
       "vap_table":[{"essid":"Clinique-Personnel","radio":"na","num_sta":2},{"essid":"Clinique-Invites","radio":"ng","num_sta":0}],
       "uplink":{"type":"wire","uplink_mac":"74:ac:b9:10:20:30","uplink_remote_port":3}},
      {"_id":"61bb03","type":"udm","model":"UDMPRO","name":"UDM-Pro-Clinique","mac":"24:5a:4c:00:00:01","ip":"192.168.1.1",
       "version":"4.1.13","state":1,"port_table":[{"port_idx":9,"name":"Port 9","up":true,"speed":1000}]}]}
    """

    static let clients = """
    {"meta":{"rc":"ok"},"data":[
      {"mac":"00:1b:a9:5e:70:01","ip":"192.168.20.30","hostname":"BRN001BA95E7001","name":"Imprimante accueil","oui":"Brother",
       "is_wired":true,"sw_mac":"74:ac:b9:10:20:30","sw_port":2,"sw_depth":1,"vlan":20,"last_seen":1730811600},
      {"mac":"3c:22:fb:7e:05:b2","ip":"192.168.1.50","hostname":"Poste-Reception","oui":"Apple","is_wired":true,
       "sw_mac":"74:ac:b9:10:20:30","sw_port":5,"last_seen":1730811600},
      {"mac":"f2:6a:19:c4:0e:58","ip":"192.168.1.61","hostname":"iPhone-Dre-Roy","oui":"","is_wired":false,
       "essid":"Clinique-Personnel","ap_mac":"d8:b3:70:aa:bb:01","channel":44,"radio":"na","radio_proto":"ax",
       "rssi":38,"signal":-58,"noise":-96,"tx_rate":573500,"rx_rate":480400,"last_seen":1730811600},
      {"mac":"a4:83:e7:11:22:33","ip":"192.168.1.62","hostname":"MacBook-Accueil","oui":"Apple","is_wired":false,
       "essid":"Clinique-Personnel","ap_mac":"d8:b3:70:aa:bb:01","channel":44,"radio":"na","signal":-74,"last_seen":1730811600}]}
    """

    static let noSite = #"{"meta":{"rc":"error","msg":"api.err.NoSiteContext"},"data":[]}"#
}

enum OmadaFixtures {
    static let info = """
    {"errorCode":0,"msg":"Success.","result":{"controllerVer":"5.14.26.1","apiVer":"3","configured":true,"type":1,
      "supportApp":true,"omadacId":"c4b2f1e0a9d84c7b8e2d1f0a9b8c7d6e"}}
    """

    static let token = """
    {"errorCode":0,"msg":"Open API Get Access Token successfully.","result":{"accessToken":"AT-RCio7GffTkt4sJDpNZkeeKF7ow7MnYv0",
      "tokenType":"bearer","expiresIn":7200,"refreshToken":"RT-bN5oB4lXkxqWV0gEqIr8DkkTWZIBH0Zf"}}
    """

    static let badToken = #"{"errorCode":-44106,"msg":"The client id or client secret is invalid."}"#

    static let sites = """
    {"errorCode":0,"msg":"Success.","result":{"totalRows":2,"currentPage":1,"currentSize":2,"data":[
      {"siteId":"6450a1b2c3d4e5f600000001","name":"Siège social","region":"Canada","timeZone":"America/Toronto","scenario":"Office"},
      {"siteId":"6450a1b2c3d4e5f600000002","name":"Bureau Québec","region":"Canada","timeZone":"America/Toronto","scenario":"Office"}]}}
    """

    static let devices = """
    {"errorCode":0,"msg":"Success.","result":{"totalRows":3,"currentPage":1,"currentSize":3,"data":[
      {"mac":"50-91-E3-00-10-01","name":"SW-QC-01","type":"switch","model":"TL-SG3428MP(UN) v2.0","ip":"10.30.0.2",
       "status":14,"statusCategory":1,"firmwareVersion":"2.0.12 Build 20230811 Rel.40285","uptimeLong":1209600,"sn":"2231A0000101"},
      {"mac":"50-91-E3-00-20-01","name":"EAP-QC-Accueil","type":"ap","model":"EAP650(US) v1.0","ip":"10.30.0.21",
       "status":14,"statusCategory":1,"firmwareVersion":"1.0.4 Build 20230315 Rel. 39021","uptimeLong":604800,"clientNum":2,
       "clientNum2g":0,"clientNum5g":2,"sn":"2231B0000201"},
      {"mac":"50-91-E3-00-30-01","name":"ER605-QC","type":"gateway","model":"ER605 v2.0","ip":"10.30.0.1","statusCategory":1}]}}
    """

    static let ports = """
    {"errorCode":0,"msg":"Success.","result":{"totalRows":4,"currentPage":1,"currentSize":4,"data":[
      {"port":1,"name":"Port1","disable":false,"profileName":"All","supportPoe":true,"poe":true,
       "portStatus":{"linkStatus":1,"linkSpeed":3,"duplex":2,"poePower":12.6}},
      {"port":2,"name":"Poste QC","disable":false,"supportPoe":true,"poe":true,"nativeVlanId":10,
       "portStatus":{"linkStatus":1,"linkSpeed":2,"duplex":2,"poePower":0}},
      {"port":3,"name":"Port3","disable":true,"supportPoe":true,"poe":false,"portStatus":{"linkStatus":0}},
      {"port":28,"name":"SFP 28","disable":false,"uplink":true,"portStatus":{"linkStatus":1,"linkSpeed":5,"duplex":2}}]}}
    """

    static let apDetail = """
    {"errorCode":0,"msg":"Success.","result":{"mac":"50-91-E3-00-20-01","name":"EAP-QC-Accueil",
      "wp2g":{"actualChannel":"6 / 2437MHz","bandWidth":"20MHz","txPower":17},
      "wp5g":{"actualChannel":"44 / 5220MHz","bandWidth":"80MHz","txPower":22,"clientNum":2},
      "wiredUplink":{"uplinkMac":"50-91-E3-00-10-01","uplinkDeviceName":"SW-QC-01","uplinkPort":1}}}
    """

    static let clients = """
    {"errorCode":0,"msg":"Success.","result":{"totalRows":3,"currentPage":1,"currentSize":3,"data":[
      {"mac":"3C-22-FB-7E-05-C1","name":"POSTE-QC-01","hostName":"POSTE-QC-01","ip":"10.30.0.50","wireless":false,
       "switchMac":"50-91-E3-00-10-01","switchName":"SW-QC-01","port":2,"vid":10,"lastSeen":1730811600000,"vendor":"Apple"},
      {"mac":"F2-6A-19-C4-0E-77","name":"Galaxy-S23","ip":"10.30.0.61","wireless":true,"ssid":"QC-Bureau",
       "apName":"EAP-QC-Accueil","apMac":"50-91-E3-00-20-01","radioId":1,"channel":44,"rssi":-61,"signalLevel":72,
       "rxRate":866000,"vid":1,"lastSeen":1730811600000},
      {"mac":"A4-83-E7-44-55-66","name":"MacBook-QC","ip":"10.30.0.62","wireless":true,"ssid":"QC-Bureau",
       "apMac":"50-91-E3-00-20-01","radioId":1,"channel":44,"rssi":-78,"signalLevel":31,"lastSeen":1730811600000}]}}
    """
}

enum MerakiFixtures {
    static let organizations = #"[{"id":"549236","name":"Groupe Exemple","url":"https://n149.meraki.com/o/-t35Mb/manage/organization/overview"}]"#

    static let networks = """
    [{"id":"L_646829496481105433","organizationId":"549236","name":"Usine Drummondville","productTypes":["appliance","switch","wireless"],
      "timeZone":"America/Toronto","tags":[]},
     {"id":"L_646829496481105434","organizationId":"549236","name":"Entrepôt","productTypes":["wireless"],"timeZone":"America/Toronto"}]
    """

    static let devices = """
    [{"name":"MS120-Production","serial":"Q2HP-AAAA-0001","model":"MS120-8LP","mac":"e0:55:3d:10:00:01","lanIp":"10.40.0.2",
      "firmware":"switch-16-7","networkId":"L_646829496481105433","productType":"switch"},
     {"name":"MR46-Atelier","serial":"Q2KD-BBBB-0002","model":"MR46","mac":"e0:55:3d:20:00:02","lanIp":"10.40.0.21",
      "firmware":"wireless-29-7","networkId":"L_646829496481105433","productType":"wireless"},
     {"name":"MX68-Usine","serial":"Q2KN-CCCC-0003","model":"MX68","mac":"e0:55:3d:30:00:03","firmware":"wired-18-107",
      "networkId":"L_646829496481105433","productType":"appliance"}]
    """

    static let statuses = """
    [{"name":"MS120-Production","serial":"Q2HP-AAAA-0001","status":"online","productType":"switch"},
     {"name":"MR46-Atelier","serial":"Q2KD-BBBB-0002","status":"alerting","productType":"wireless"},
     {"name":"MX68-Usine","serial":"Q2KN-CCCC-0003","status":"online","productType":"appliance"}]
    """

    static let portConfigs = """
    [{"portId":"1","name":"MR46 atelier","enabled":true,"poeEnabled":true,"type":"trunk","vlan":1,"allowedVlans":"1,12,20-21"},
     {"portId":"2","name":"Automate ligne 1","enabled":true,"poeEnabled":false,"type":"access","vlan":12},
     {"portId":"3","name":"","enabled":false,"poeEnabled":true,"type":"access","vlan":1},
     {"portId":"9","name":"Uplink MX","enabled":true,"poeEnabled":false,"type":"trunk","vlan":1,"allowedVlans":"all"}]
    """

    static let portStatuses = """
    [{"portId":"1","enabled":true,"status":"Connected","isUplink":false,"errors":[],"warnings":[],"speed":"1 Gbps","duplex":"full",
      "usageInKb":{"total":40960,"sent":20480,"recv":20480},"clientCount":1,"powerUsageInWh":1.05,
      "lldp":{"systemName":"MR46-Atelier","systemDescription":"Meraki MR46 Cloud Managed AP","portId":"Port 0","managementAddress":"10.40.0.21"},
      "poe":{"isAllocated":true}},
     {"portId":"2","enabled":true,"status":"Connected","isUplink":false,"errors":["CRC align errors"],"warnings":[],"speed":"100 Mbps",
      "duplex":"full","clientCount":1,"powerUsageInWh":0},
     {"portId":"3","enabled":false,"status":"Disabled","isUplink":false,"errors":[],"warnings":[],"speed":"","duplex":""},
     {"portId":"9","enabled":true,"status":"Connected","isUplink":true,"errors":[],"warnings":[],"speed":"1 Gbps","duplex":"full",
      "cdp":{"deviceId":"e0553d300003","portId":"Port 3","platform":"Meraki MX68 Cloud Managed Security Appliance"}}]
    """

    static let wirelessStatus = """
    {"basicServiceSets":[
      {"ssidName":"Usine-Interne","ssidNumber":0,"enabled":true,"band":"2.4 GHz","bssid":"E0:55:3D:20:00:10","channel":11,
       "channelWidth":"20 MHz","power":"18 dBm","visible":true,"broadcasting":true},
      {"ssidName":"Usine-Interne","ssidNumber":0,"enabled":true,"band":"5 GHz","bssid":"E0:55:3D:20:00:11","channel":36,
       "channelWidth":"40 MHz","power":"20 dBm","visible":true,"broadcasting":true},
      {"ssidName":"Unconfigured SSID 2","ssidNumber":1,"enabled":false,"band":"5 GHz","channel":36}]}
    """

    static let clientsPage1 = """
    [{"id":"k74272e","mac":"00:30:de:40:12:01","ip":"10.40.12.41","description":"Automate-L1","manufacturer":"WAGO",
      "vlan":"12","switchport":"2","recentDeviceSerial":"Q2HP-AAAA-0001","recentDeviceName":"MS120-Production",
      "recentDeviceMac":"e0:55:3d:10:00:01","recentDeviceConnection":"Wired","status":"Online","lastSeen":"2026-11-05T13:00:00Z"}]
    """

    static let clientsPage2 = """
    [{"id":"k74272f","mac":"f2:6a:19:c4:0e:99","ip":"10.40.0.77","description":"Tablette-Atelier","manufacturer":"Samsung",
      "os":"Android","vlan":"1","ssid":"Usine-Interne","wirelessCapabilities":"802.11ac - 2.4 and 5 GHz",
      "recentDeviceSerial":"Q2KD-BBBB-0002","recentDeviceName":"MR46-Atelier","recentDeviceConnection":"Wireless",
      "status":"Online","lastSeen":"2026-11-05T13:00:00Z","switchport":null}]
    """
}
