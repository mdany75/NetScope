import Foundation

// Note 70 : certificats recopiés pour les tests du lecteur X.509 (DER en Base64). Les quatre
// premiers ont été produits localement avec openssl (aucun réseau) ; ISRG Root X2 vient du
// trousseau des racines de macOS. Aucune clé privée n'est conservée.

enum TLSFixtures {
    /// FortiGate 60F, auto-signé (RSA 2048, SHA-256, sans SAN), 2022-03-15 → 2032-03-12.
    static let fortigate = der([
        "MIIDoDCCAoigAwIBAgIEWjyeATANBgkqhkiG9w0BAQsFADB4MQswCQYDVQQGEwJVUzETMBEGA1UECAwKQ2FsaWZvcm5pYTESMBAG",
        "A1UEBwwJU3Vubnl2YWxlMREwDwYDVQQKDAhGb3J0aW5ldDESMBAGA1UECwwJRm9ydGlHYXRlMRkwFwYDVQQDDBBGR1Q2MEZUSzIy",
        "MDlBMUIyMB4XDTIyMDMxNTEyMDAwMFoXDTMyMDMxMjEyMDAwMFoweDELMAkGA1UEBhMCVVMxEzARBgNVBAgMCkNhbGlmb3JuaWEx",
        "EjAQBgNVBAcMCVN1bm55dmFsZTERMA8GA1UECgwIRm9ydGluZXQxEjAQBgNVBAsMCUZvcnRpR2F0ZTEZMBcGA1UEAwwQRkdUNjBG",
        "VEsyMjA5QTFCMjCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAIuZEfzobhKnqUWqIqlBObHsrR/e3yz47RsV6NkMAIRF",
        "EslBvg/x2iu5nYziYACQT839p03TubrSa1oiuseGBRVkwA//y3wHEvWgxx8Rtz2iHWFTS1jCY0oseQUDbCCoiTrmE8YeOqjxLSt8",
        "yOtzp2CGlDymDA9sIEgHTTWX5b79bAW+gqAIRUuF/6mbGXTaUbh582uDhAVopnKA9x3ZOJWZ3D/nLWZIMbpOy7ywLvwkxKXsAHMU",
        "AuND8ybj5E+7Eg8NcT9ajSTRFUA/2iENpASu6eNY+aUvkgJY0OUjUeMCsbX//nlQwIuLTFNZdrh6v5tLnny9XD7z80v07a6L8ncC",
        "AwEAAaMyMDAwHQYDVR0OBBYEFKggEkGNEJhUL2j2iDdZmkLSRtX4MA8GA1UdEwEB/wQFMAMBAf8wDQYJKoZIhvcNAQELBQADggEB",
        "AEnDLkynBt5UG+bX3mipSqxcEGxFIE5O5rAjV8dQdljcgshLeK4l37Xx1aOneKdZfWsXO6+aANJPWYPWgGS67LX+2LIfE8a7gFd7",
        "wBn/hQin6bjtc4XKHWg0J+sGq2YjbJgPv+gN54uDmxBGsjYbQAwzsCAvhu6yGieuMo/IOy1sa2zdgwd8V2DdmhQpCGQjMfYQsTTu",
        "Hjz67batkD+S7zIwSHl+41ClkfyB5gxFxyHA0ctp1aAcMVM/YmiQGgW1DQrEP/7zHqV8lmsFdfVkK1/sND1zcQQgoM2p+6KsN0sg",
        "jopUtkMf07sFArgELJY0wqGYnpJRtXGZhaItDRrfXp4=",
    ])

    /// NAS : nas.exemple.ca, *.exemple.ca, IP 10.182.122.154 (ECDSA P-256), émis par « Exemple CA interne », 2025-10-01 → 2051-01-01 (GeneralizedTime).
    static let nas = der([
        "MIIBnTCCAUKgAwIBAgICEjQwCgYIKoZIzj0EAwIwQDELMAkGA1UEBhMCQ0ExFDASBgNVBAoMC0V4ZW1wbGUgSW5jMRswGQYDVQQD",
        "DBJFeGVtcGxlIENBIGludGVybmUwIBcNMjUxMDAxMDAwMDAwWhgPMjA1MTAxMDEwMDAwMDBaMBkxFzAVBgNVBAMMDm5hcy5leGVt",
        "cGxlLmNhMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEHNJX9Qxq/RMX06hgGbGMszyABCb7lXT+6Sl+i0JEHgnCvWERH4S9g2od",
        "aP1ioV78Qf+u04wMa0WsiqDZNxeft6NRME8wLQYDVR0RBCYwJIIObmFzLmV4ZW1wbGUuY2GCDCouZXhlbXBsZS5jYYcECrZ6mjAT",
        "BgNVHSUEDDAKBggrBgEFBQcDATAJBgNVHRMEAjAAMAoGCCqGSM49BAMCA0kAMEYCIQC0tY4Z0br6ziZOEOGyNX7orSQLZTkrTI5y",
        "OSGYbnKBBQIhAJwnW0FJYYNCjWdUQStpnVK6LqIG/wFhkb1jjGZyp1hX",
    ])

    /// Autorité interne « Exemple CA interne » (ECDSA P-256, signée en SHA-384), CA:TRUE.
    static let internalCA = der([
        "MIIBtDCCAVqgAwIBAgIUNOk0G4h+pWJONv0TXtvwsn8gg04wCgYIKoZIzj0EAwMwQDELMAkGA1UEBhMCQ0ExFDASBgNVBAoMC0V4",
        "ZW1wbGUgSW5jMRswGQYDVQQDDBJFeGVtcGxlIENBIGludGVybmUwHhcNMjYxMTA2MDAwNzI3WhcNMzYxMTAzMDAwNzI3WjBAMQsw",
        "CQYDVQQGEwJDQTEUMBIGA1UECgwLRXhlbXBsZSBJbmMxGzAZBgNVBAMMEkV4ZW1wbGUgQ0EgaW50ZXJuZTBZMBMGByqGSM49AgEG",
        "CCqGSM49AwEHA0IABLKj4pycyEVVm4oLVzceestG1ALLYg8+MgPl6c3uH2WJjzvZN2XTIxwVYo3TOLgj9/MQTIqeBaCKCu8n/USr",
        "d6OjMjAwMB0GA1UdDgQWBBShTqf+Is16DLypvizg4+0qVvU7oTAPBgNVHRMBAf8EBTADAQH/MAoGCCqGSM49BAMDA0gAMEUCIFYs",
        "ei5luAI1MIiEpELb+gt79SV7IAQgTzS7C/90l11gAiEAojHOZSpvleL9rKS0NwY0l9DnOLQHoQB2yfoaTj05cmM=",
    ])

    /// Imprimante Brother, auto-signée, expirée (RSA 1024, SHA-1), SAN IP 10.182.122.111, 2020-01-01 → 2023-01-01.
    static let printer = der([
        "MIICADCCAWmgAwIBAgIUX7JuZKMUE56AcgA0gMesh0YBzqswDQYJKoZIhvcNAQEFBQAwGjEYMBYGA1UEAwwPQlJOOTREREY4MTgx",
        "NTdEMB4XDTIwMDEwMTAwMDAwMFoXDTIzMDEwMTAwMDAwMFowGjEYMBYGA1UEAwwPQlJOOTREREY4MTgxNTdEMIGfMA0GCSqGSIb3",
        "DQEBAQUAA4GNADCBiQKBgQDtsqN5B1ng2V0lKxtBr1f6EugPZi0vfidbQINw5uCJv6vRHInBd2IdWoEJtiJyGDjF/vkoCvquy60g",
        "CCvTi34kT8vAz2+whCd0G2fxME/Wfr/4uoLHDT8bAsaYRU9CyVSQIjmUMqvby0jWG7vb/HdHWg1XlaeRXB3k5gzd2atH1QIDAQAB",
        "o0MwQTAdBgNVHQ4EFgQUHmTl3TPk1SMYWuRrmp3yWVvAqEcwDwYDVR0TAQH/BAUwAwEB/zAPBgNVHREECDAGhwQKtnpvMA0GCSqG",
        "SIb3DQEBBQUAA4GBAErXNEte/4Ro65ov9ZDW43Ai+TtCMwzCG/hxER1b8xUfMwnzcE3AVnB9962k+WQuUkm+kG7jLqbmTXDYQiWZ",
        "M8YTclAiWjPqjALODd+5Re/t+7C/aKQAjBhEl0zYy8qRlSaMitKKIOCWAltr6C/sn1snVvN94Z3tWN++zTUiQdCV",
    ])

    /// ISRG Root X2 (Let’s Encrypt), recopiée du trousseau des racines de macOS (ECDSA P-384).
    static let isrgRootX2 = der([
        "MIICGzCCAaGgAwIBAgIQQdKd0XLq7qeAwSxs6S+HUjAKBggqhkjOPQQDAzBPMQswCQYDVQQGEwJVUzEpMCcGA1UEChMgSW50ZXJu",
        "ZXQgU2VjdXJpdHkgUmVzZWFyY2ggR3JvdXAxFTATBgNVBAMTDElTUkcgUm9vdCBYMjAeFw0yMDA5MDQwMDAwMDBaFw00MDA5MTcx",
        "NjAwMDBaME8xCzAJBgNVBAYTAlVTMSkwJwYDVQQKEyBJbnRlcm5ldCBTZWN1cml0eSBSZXNlYXJjaCBHcm91cDEVMBMGA1UEAxMM",
        "SVNSRyBSb290IFgyMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAEzZvVn4CDCuwJSvMWSj5cz3es3mcFDR0HttwW+1qLFNvicWDEukWV",
        "EYmO6gbf9yoWHKS5xcUy4APgHoIYOIvXRdgKam7mAHf7AlF9ItgKbppbd9/w+kHsOdx1ymgHDB/qo0IwQDAOBgNVHQ8BAf8EBAMC",
        "AQYwDwYDVR0TAQH/BAUwAwEB/zAdBgNVHQ4EFgQUfEKWrt5LSDv6kviejM9ti6lyN5UwCgYIKoZIzj0EAwMDaAAwZQIwe3lORlCE",
        "wkSHRhtFcP9Ymd70/aTSVaYgLXTWNLxBo1BfASdWtL4ndQavEi51mI38AjEAi/V3bNTIZargCyzuFJ0nN6T5U6VR5CmD1/iQMVtC",
        "nwr1/q4AaOeMSQ+2b1tbFfLn",
    ])

    private static func der(_ lines: [String]) -> Data { Data(base64Encoded: lines.joined())! }
}
