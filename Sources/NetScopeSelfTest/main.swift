import Foundation

// Tests du moteur NetScopeCore. Usage : swift build && ./.build/debug/NetScopeSelfTest
// Code de sortie : 0 si tout passe, 1 sinon.

setvbuf(stdout, nil, _IOLBF, 0)

let suite = TestSuite()
registerAddressingTests(suite)
registerHardwareTests(suite)
registerOUITests(suite)
registerModelTests(suite)
registerScanTests(suite)
registerPingTests(suite)
registerPingPauseTests(suite)
registerPingProtocolTests(suite)
registerPathMTUTests(suite)
registerToolsTests(suite)
registerUpdateTests(suite)
registerSpeedRemoteTests(suite)
registerSNMPTests(suite)
registerSNMPDiscoveryTests(suite)
registerSNMPv3WalkTests(suite)
registerInventoryTests(suite)
registerInventoryPhase3Tests(suite)
registerNamesTests(suite)
registerAutoScanTests(suite)
registerVoIPTests(suite)
registerAutoScanReviewTests(suite)
registerRemoteDisplayTests(suite)
registerWifiLocationTests(suite)
registerMonitorTests(suite)
registerMonPlanningTests(suite)
registerCaptureTests(suite)
registerPacketCaptureTests(suite)
registerPacketFindingsTests(suite)
registerPoETests(suite)
registerReportTests(suite)
registerReportFollowUpTests(suite)
registerReportDocxTests(suite)
registerRelevanceTests(suite)
registerTableTests(suite)
registerResourceTests(suite)
registerSpeedServerTests(suite)
registerServiceStatusTests(suite)
registerSocialAIServiceTests(suite)
registerMailDNSTests(suite)
registerMailDiagnosticTests(suite)
registerMailHeaderTests(suite)
registerMailReviewTests(suite)
registerDNSExtendedTests(suite)
registerDiskTests(suite)
registerDiskShareTests(suite)
registerNotificationShortcutTests(suite)
registerCredentialTests(suite)
registerBackupMethodsTests(suite)
registerBackupCryptoTests(suite)
registerConfigSyncTests(suite)
registerConfigSyncFullTests(suite)
registerConfigSyncReviewTests(suite)
registerAlertTests(suite)
registerSafeNumberTests(suite)
registerFortinetTests(suite)
registerFortiControllerTests(suite)
registerSearchTests(suite)
registerFortiWifiTests(suite)
registerFortiJSONRepairTests(suite)
registerFortiWifiClientTests(suite)
registerDHCPScopeTests(suite)
registerWANTests(suite)
registerFirmwareTests(suite)
registerTrafficTests(suite)
registerWifiDiagnosisTests(suite)
registerWifiClientDetailsBridgeTests(suite)
registerWifiBeaconTests(suite)
registerSiteTests(suite)
registerSiteScopeTests(suite)
registerSiteBrowseTests(suite)
registerNavigationTests(suite)
registerTopoSearchTests(suite)
registerPerformanceTests(suite)
registerLoadTests(suite)
registerQuickLoginTests(suite)
registerAutoRefreshTests(suite)
registerFileTransferTests(suite)
registerTFTPTests(suite)
registerLogTests(suite)
registerLogTCPTests(suite)
registerDiagnosticsTests(suite)
registerTerminalTests(suite)
registerVNCTests(suite)
registerHardwareDetectTests(suite)
registerPortHistoryTests(suite)
registerPortActionTests(suite)
registerLighteningTests(suite)
registerLinkCheckTests(suite)
registerSSHTunnelTests(suite)
registerSSHTunnelDiagnosisTests(suite)
registerSSHTunnelProcessTests(suite)
// Note 78 (0.26.0) : Ping continu, Inventaire, Wake-on-LAN et Alertes.
registerAlertDedicatedTests(suite)
registerPingSessionTests(suite)
registerInventoryExportTests(suite)
registerWakePlanTests(suite)
// Note 6 (0.26.1) : RustDesk.
registerRustDeskTests(suite)
// Note 6 (0.26.1) : ports RustDesk dans les ports ouverts.
registerRustDeskPortTests(suite)
// Note 6 (0.26.2) : tableau de bord du serveur RustDesk.
registerRustDeskServerTests(suite)
registerRustDeskServerWatchTests(suite)
// Correctif 0.27.3 : onglet « Assistance RustDesk » d'Accès distant.
registerRustDeskAssistanceTests(suite)
// Écran Appareil : ouvrir une fiche par IP, nom ou MAC, appareils saisis à la main.
registerDeviceLookupTests(suite)
// Note 78 (0.27.0) : Wi-Fi de ce Mac (meilleur canal, historique d'une heure, relevé par pièce).
registerWifiLocalTests(suite)
// Note 83 (0.27.0) : Switchs et ports en onglets.
registerSwitchPageTests(suite)
// Note 81 (0.27.0) : mise à jour automatique de la base des fabricants.
registerOUIAutoUpdateTests(suite)
// Note 78 (0.27.0) : débit Internet planifié par site.
registerSpeedScheduleTests(suite)
// Note 82 (0.27.0) : plages exclues d'un site.
registerSiteExclusionTests(suite)
// Note 78 (0.27.0) : Historique et adressage, plan d'adressage.
registerAddressPlanTests(suite)
// Note 78 (0.27.0) : Carte du réseau (liens LLDP, filtre VLAN, disposition par site).
registerTopoLinksTests(suite)
registerTopoExportTests(suite)
// Note 78 (0.27.0) : serveur et client iperf3 intégrés, Vitesse des disques en FTP et SFTP, XMODEM et YMODEM.
registerIperfServerTests(suite)
registerDiskTransferTests(suite)
registerSerialFileTransferTests(suite)
// Note 84 (0.27.1) : appareils Wi-Fi (itinérance sans alerte) et repères Wi-Fi / filaire / DHCP.
registerWirelessRoamingTests(suite)
// Note 72 (0.28.0) : partages SMB d'un hôte (sorties de smbutil recopiées, aucun smbutil lancé).
registerSMBSharesTests(suite)
registerFingerprintTests(suite)
// Note 75 (0.28.0) : collecteur NetFlow, sFlow et IPFIX.
registerFlowTests(suite)
// Note 76 (0.28.0) : alertes sur téléphone par ntfy et Pushover.
registerAlertPhoneTests(suite)
// Note 69 (0.30.0) : scan de ports UDP ciblé (sondes par protocole, 127.0.0.1 seulement).
registerUDPScanTests(suite)
// Note 70 (0.30.0) : vérificateur de certificat TLS (certificats recopiés, aucun réseau).
registerTLSCertificateTests(suite)
// Note 77 (0.30.0) : contrôleurs UniFi, Omada et Meraki (réponses fixes, aucun réseau).
registerControllerTests(suite)
// Note 40 (0.31.0) : sauvegarde des configurations (diff, secrets masqués, réponses fixes, aucun ssh lancé).
registerConfigBackupTests(suite)
// Notes 63 et 64 (0.31.0) : scans planifiés par site et agent en arrière-plan (aucun réseau).
registerAutomationTests(suite)
// IPv6 (0.31.0) : adresses, préfixes, EUI-64, table NDP sur octets fixes, ICMPv6 (rien n’est envoyé).
registerIPv6Tests(suite)

let failures = await suite.run()
exit(failures == 0 ? 0 : 1)
