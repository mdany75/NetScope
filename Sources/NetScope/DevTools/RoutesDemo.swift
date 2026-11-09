/// Table de routage en démonstration (note 119) : sortie de netstat fictive, lue par le vrai
/// analyseur. Captures : NETSCOPE_OUTIL_DEMO=routes ouvre l'outil.
enum RoutesDemo {
    static let netstat = """
    Routing tables

    Internet:
    Destination        Gateway            Flags               Netif Expire
    default            10.182.122.1       UGScg                 en0
    default            10.182.122.1       UGScIg                en7
    default            link#20            UCSIg               utun3
    10.8/16            10.8.0.1           UGSc                utun3
    10.8.0.1           10.8.0.2           UH                  utun3
    10.182.122/24      link#8             UCS                   en0      !
    10.182.122.1       e0:23:ff:12:4a:90  UHLWIir               en0   1183
    10.182.122.111     94:dd:f8:18:15:7d  UHLWI                 en0    742
    10.182.122.255     ff:ff:ff:ff:ff:ff  UHLWbI                en0      !
    127                127.0.0.1          UCS                   lo0
    127.0.0.1          127.0.0.1          UH                    lo0
    169.254            link#8             UCS                   en0      !
    224.0.0/4          link#8             UmCS                  en0      !
    224.0.0.251        1:0:5e:0:0:fb      UHmLWI                en0
    255.255.255.255/32 link#8             UCS                   en0      !

    Internet6:
    Destination                             Gateway                                 Flags               Netif Expire
    default                                 fe80::e223:ffff:fe12:4a90%en0           UGcg                  en0
    default                                 fe80::%utun3                            UGcIg               utun3
    ::1                                     ::1                                     UHL                   lo0
    2001:db8:122::/64                       link#8                                  UC                    en0
    2001:db8:122:0:4a1:9fff:fe33:7a10       4a:1:9f:33:7a:10                        UHLWI                 en0    316
    fe80::%lo0/64                           fe80::1%lo0                             UcI                   lo0
    fe80::%en0/64                           link#8                                  UCI                   en0
    ff02::%en0/32                           link#8                                  UmCI                  en0
    """
}
