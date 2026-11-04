import Foundation
import NetScopeCore

// Réponses fixes réalistes de l'API REST de FortiOS (aucun réseau), en plusieurs variantes de
// version : 7.4 (adresse managed-switch/status, noms en « _ »), 6.4 (ancienne adresse, dictionnaire
// indexé par numéro de série, vitesse « 1000full », noms en « - »), réponse sans enveloppe et
// champs absents.

/// Transport de test : chemin → (code HTTP, corps). Note les requêtes reçues.
final class FortiFakeTransport: FortiTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String: (Int, String)]
    private(set) var requested: [String] = []

    init(_ responses: [String: (Int, String)]) {
        self.responses = responses
    }

    private func take(_ path: String) -> (Int, String)? {
        lock.lock()
        defer { lock.unlock() }
        requested.append(path)
        return responses[path]
    }

    func get(_ path: String, query: [URLQueryItem]) async throws -> FortiHTTPResponse {
        let response = take(path)
        guard let (status, body) = response else {
            return FortiHTTPResponse(status: 404, body: Data(#"{"http_method":"GET","status":"error","http_status":404}"#.utf8))
        }
        return FortiHTTPResponse(status: status, body: Data(body.utf8))
    }
}

enum FortiFixtures {
    static let token = "q8wNz3fG5hY1kd0pXr7mT2bLc4vS9e"

    // MARK: FortiOS 7.4

    static let status74 = """
    {"http_method":"GET","results":{"model_name":"FortiGate","model_number":"100F","model":"FGT100F","hostname":"FGT-SIEGE","log_disk_status":"available"},
     "vdom":"root","path":"system","name":"status","action":"","status":"success","serial":"FG100FTK22004711","version":"v7.4.4","build":2662}
    """

    static let switches74 = """
    {"http_method":"GET","results":[
      {"name":"FSW-ENTREPOT","serial":"S248EPTF21000123","switch-id":"FSW-ENTREPOT","fgt_peer_intf_name":"fortilink",
       "status":"Connected","state":"Authorized","os_version":"S248EP-v7.2.5-build0453,230920 (GA)","connecting_from":"10.255.1.2",
       "join_time":"Fri Oct 30 08:12:44 2026","max_poe_budget":370,
       "ports":[
         {"interface":"port1","status":"up","duplex":"full","speed":1000,"vlan":"vlan40","poe_capable":true,"port_power":6.4,"power_status":"Delivering Power","poe_class":2},
         {"interface":"port2","status":"down","duplex":"full","speed":1000,"vlan":"_default","poe_capable":true,"port_power":0},
         {"interface":"port3","status":"up","duplex":"full","speed":1000,"vlan":"vlan100","poe_capable":true,"port_power":0},
         {"interface":"port47","status":"up","duplex":"full","speed":10000,"vlan":"_default","isl_peer_device_name":"FSW-QUAI","isl_peer_port_name":"port25"},
         {"interface":"port49","status":"up","duplex":"full","speed":10000,"vlan":"_default","fortilink_port":true,"fgt_peer_port_name":"port1","fgt_peer_device_name":"FGT-SIEGE"}
       ]},
      {"name":"FSW-QUAI","serial":"S124FPTF22000456","switch-id":"FSW-QUAI","status":"Connected","state":"Authorized",
       "os_version":"S124FP-v7.2.5-build0453,230920 (GA)","connecting_from":"10.255.1.3","max_poe_budget":185,
       "ports":[
         {"interface":"port3","status":"up","speed":1000,"vlan":"vlan40","poe_capable":true,"port_power":5.1,"power_status":"Delivering Power"},
         {"interface":"port4","status":"up","speed":100,"vlan":"vlan40","poe_capable":true,"port_power":4.2,"power_status":"Delivering Power"},
         {"interface":"port5","status":"down","speed":1000,"vlan":"vlan40","poe_capable":true,"port_power":0,"power_status":"Searching"},
         {"interface":"port25","status":"up","speed":10000,"vlan":"_default","isl_peer_device_name":"FSW-ENTREPOT"}
       ]}
    ],"vdom":"root","path":"switch-controller","name":"managed-switch","action":"status","status":"success","serial":"FG100FTK22004711","version":"v7.4.4","build":2662}
    """

    static let config74 = """
    {"http_method":"GET","revision":"a1b2","results":[
      {"switch-id":"FSW-ENTREPOT","sn":"S248EPTF21000123","name":"FSW-ENTREPOT","description":"Entrepôt · baie A",
       "ports":[{"port-name":"port1","description":"Caméra quai","vlan":"vlan40","status":"up","poe-status":"enable"},
                {"port-name":"port2","description":"Prise E-02","vlan":"_default","status":"down","poe-status":"enable"},
                {"port-name":"port3","description":"Serveur AD","vlan":"vlan100","status":"up","poe-status":"disable"},
                {"port-name":"port47","description":"ISL vers FSW-QUAI","vlan":"_default","isl-local-trunk-name":"8DN4K16000000-0"},
                {"port-name":"port49","description":"FortiLink","vlan":"_default","fortilink-port":1}]},
      {"switch-id":"FSW-QUAI","sn":"S124FPTF22000456","name":"FSW-QUAI","ports":[{"port-name":"port3","description":"Caméra cour"}]}
    ],"vdom":"root","path":"switch-controller","name":"managed-switch","status":"success","http_status":200,"version":"v7.4.4","build":2662}
    """

    static let portStats74 = """
    {"http_method":"GET","results":[
      {"serial":"S248EPTF21000123","switch-id":"FSW-ENTREPOT","ports":{"port1":{"tx-bytes":120000,"rx-bytes":3400000,"rx-errors":0,"crc-alignments":0},
                                                                     "port3":{"tx-bytes":98000000,"rx-bytes":45000000,"rx-errors":12,"crc-alignments":3}}}
    ],"status":"success"}
    """

    static let detected74 = """
    {"http_method":"GET","results":[
      {"mac":"bc:ad:28:6f:01:5a","switch_id":"FSW-QUAI","port_name":"port3","port_id":3,"vlan_id":40,"last_seen":12,"vdom":"root"},
      {"mac":"b8:a4:4f:2c:19:e0","switch_id":"FSW-QUAI","port_name":"port4","port_id":4,"vlan_id":40,"last_seen":30,"vdom":"root"},
      {"mac":"f4:ee:08:3c:72:a1","switch_id":"FSW-ENTREPOT","port_name":"port3","port_id":3,"vlan_id":100,"last_seen":4,"vdom":"root"},
      {"mac":"94:dd:f8:18:15:7d","switch_id":"FSW-ENTREPOT","port_name":"port49","port_id":49,"vlan_id":30,"last_seen":2,"vdom":"root"}
    ],"vdom":"root","status":"success"}
    """

    static let arp74 = """
    {"http_method":"GET","results":[
      {"ip":"192.168.50.21","age":3,"mac":"bc:ad:28:6f:01:5a","interface":"vlan40"},
      {"ip":"192.168.50.22","age":8,"mac":"b8:a4:4f:2c:19:e0","interface":"vlan40"},
      {"ip":"10.10.0.10","age":1,"mac":"f4:ee:08:3c:72:a1","interface":"vlan100"},
      {"ip":"10.10.0.31","age":1,"mac":"00:50:56:aa:10:31","interface":"vlan100"}
    ],"status":"success"}
    """

    static let dhcp74 = """
    {"http_method":"GET","results":[
      {"ip":"192.168.50.22","reserved":false,"mac":"b8:a4:4f:2c:19:e0","vci":"","hostname":"axis-cour","expire_time":1793790000,"status":"leased","interface":"vlan40","type":"ipv4"},
      {"ip":"10.10.0.31","reserved":true,"mac":"00:50:56:aa:10:31","hostname":"SRV-BACKUP","expire_time":1793790000,"status":"leased","interface":"vlan100","type":"ipv4"}
    ],"status":"success"}
    """

    static let users74 = """
    {"http_method":"GET","results":[
      {"ipv4_address":"192.168.50.21","mac":"bc:ad:28:6f:01:5a","hardware_vendor":"Hikvision","os_name":"Linux","hostname":"CAM-QUAI-01","last_seen":1793700000,
       "is_online":true,"detected_interface":"vlan40","fortiswitch_id":"FSW-QUAI","fortiswitch_port_name":"port3"},
      {"ipv4_address":"10.10.0.31","mac":"00:50:56:aa:10:31","hardware_vendor":"VMware","hostname":"SRV-BACKUP","is_online":true,"detected_interface":"vlan100"}
    ],"vdom":"root","query_type":"latest","count":2,"total":2,"status":"success","serial":"FG100FTK22004711","version":"v7.4.4","build":2662}
    """

    static func v74() -> [String: (Int, String)] {
        [FortiPaths.systemStatus: (200, status74), FortiPaths.switchStatus: (200, switches74), FortiPaths.switchConfig: (200, config74),
         FortiPaths.portStats: (200, portStats74), FortiPaths.detectedDevice: (200, detected74), FortiPaths.arp: (200, arp74),
         FortiPaths.dhcp: (200, dhcp74), FortiPaths.userDevices: (200, users74)]
    }

    // MARK: FortiOS 6.4

    static let status64 = """
    {"http_method":"GET","results":{"model_name":"FortiGate","model_number":"60F","model":"FGT60F","hostname":"FGT-ANNEXE"},
     "vdom":"root","path":"system","name":"status","status":"success","serial":"FGT60FTK20001234","version":"v6.4.12","build":2060}
    """

    /// 6.4 : dictionnaire indexé par numéro de série, vitesse texte, PoE « poe_status », adresse « fsw_ip ».
    static let legacy64 = """
    {"http_method":"GET","results":{
      "S108FFTV21000789":{"switch-id":"S108FFTV21000789","serial":"S108FFTV21000789","status":"Connected","state":"Authorized",
        "os_version":"S108FF-v6.4.11-build0518,230124 (GA)","fsw_ip":"10.255.1.4",
        "ports":[{"interface":"port1","status":"up","speed":"1000full","vlan":"vlan100"},
                 {"interface":"port2","status":"up","speed":"100half","vlan":"vlan20"},
                 {"interface":"port8","status":"up","speed":"1000full","vlan":"_default","fortilink_port":true}]}
    },"vdom":"root","status":"success","serial":"FGT60FTK20001234","version":"v6.4.12","build":2060}
    """

    /// 6.4 : noms en « - », port sans « _name », VLAN sous « vlan ».
    static let detected64 = """
    {"http_method":"GET","results":[
      {"mac":"F4-EE-08-3C-72-A1","switch-id":"S108FFTV21000789","port":"port1","vlan":100,"last-seen":1793699000},
      {"mac":"70:4C:A5:1E:22:9A","switch-id":"S108FFTV21000789","port":"port2","vlan":20}
    ],"status":"success"}
    """

    /// DHCP en dictionnaire de listes par interface.
    static let dhcp64 = """
    {"http_method":"GET","results":{"vlan100":[{"ip":"10.10.0.10","mac":"f4:ee:08:3c:72:a1","hostname":"SRV-AD-01"}],
                                     "vlan20":[{"ip":"10.182.122.102","mac":"70:4c:a5:1e:22:9a"}]},"status":"success"}
    """

    static func v64() -> [String: (Int, String)] {
        [FortiPaths.systemStatus: (200, status64), FortiPaths.switchLegacy: (200, legacy64),
         FortiPaths.detectedDevice: (200, detected64), FortiPaths.dhcp: (200, dhcp64),
         FortiPaths.arp: (403, #"{"http_method":"GET","status":"error","http_status":403}"#)]
    }

    // MARK: Variante sans enveloppe, champs absents

    static let bareStatus = #"{"hostname":"FGT-NU","model":"FGT40F","version":"v7.6.0"}"#
    static let bareSwitches = """
    [{"serial":"S124FFTF23000999","connecting_from":"10.255.1.9","ports":[{"name":"port1","status":"up"},{"name":"port2"}]}]
    """
}
