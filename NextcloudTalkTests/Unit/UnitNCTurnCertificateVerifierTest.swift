//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CryptoKit
import XCTest
@testable import NextcloudTalk

final class UnitNCTurnCertificateVerifierTest: XCTestCase {

    // All certificates are evaluated at this date (2026-10-10 12:00 UTC), so that the tests do not depend on the
    // expiration of the certificates of the public sites. The network is not used.
    private let verifyDate = Date(timeIntervalSince1970: 1_791_633_600)

    private func makeVerifier(hosts: [String]) -> NCTurnCertificateVerifier {
        return NCTurnCertificateVerifier(hosts: hosts, verifyDate: verifyDate, allowsNetworkFetch: false)
    }

    // MARK: - Host extraction

    func testTurnsHostsFromUrls() {
        let urls = [
            "turns:turn.example.com:443?transport=tcp",
            "turns:turn.example.com",
            "TURNS:Other.Example.com:5349",
            "turns:[2001:db8::1]:443",
            "turns:[2001:db8::2]",
            "turns:turn.example.com:443?transport=udp"
        ]

        XCTAssertEqual(
            NCTurnCertificateVerifier.turnsHosts(from: urls),
            ["turn.example.com", "other.example.com", "2001:db8::1", "2001:db8::2"]
        )
    }

    func testTurnsHostsIgnoresOtherSchemesAndGarbage() {
        let urls = [
            "turn:turn.example.com:3478",
            "stun:stun.example.com:3478",
            "stuns:stun.example.com:5349",
            "",
            "turns:",
            "turns::443",
            "turns:[2001:db8::1",
            "https://example.com",
            "garbage"
        ]

        XCTAssertEqual(NCTurnCertificateVerifier.turnsHosts(from: urls), [])
    }

    func testInitWithIceServers() {
        let servers = [
            RTCIceServer(urlStrings: ["stun:stun.example.com:3478"]),
            RTCIceServer(urlStrings: ["turn:turn.example.com:3478", "turns:turn.example.com:443?transport=tcp"], username: "user", credential: "secret")
        ]

        XCTAssertEqual(NCTurnCertificateVerifier(iceServers: servers)?.hosts, ["turn.example.com"])
        XCTAssertNil(NCTurnCertificateVerifier(iceServers: [RTCIceServer(urlStrings: ["stun:stun.example.com:3478"])]))
        XCTAssertNil(NCTurnCertificateVerifier(iceServers: []))
    }

    // MARK: - Real Let's Encrypt certificates

    // Leaf of letsencrypt.org (ECDSA, issued by "YE2"), sent alone: the chain is built via the built-in intermediates.
    // Taken on 2026-10-06 with `openssl s_client -showcerts`, valid from 2026-09-04 to 2026-12-03.
    func testLetsEncryptEcdsaLeafIsTrustedForItsHost() {
        let verifier = makeVerifier(hosts: ["letsencrypt.org"])

        XCTAssertTrue(verifier.verify(Self.letsencryptOrgLeaf))
        // From the cache
        XCTAssertTrue(verifier.verify(Self.letsencryptOrgLeaf))
    }

    func testLetsEncryptEcdsaLeafIsTrustedIfOneHostMatches() {
        XCTAssertTrue(makeVerifier(hosts: ["turn.example.com", "www.letsencrypt.org"]).verify(Self.letsencryptOrgLeaf))
    }

    func testLetsEncryptEcdsaLeafIsNotTrustedForOtherHost() {
        let verifier = makeVerifier(hosts: ["turn.example.com"])

        XCTAssertFalse(verifier.verify(Self.letsencryptOrgLeaf))
        // From the cache
        XCTAssertFalse(verifier.verify(Self.letsencryptOrgLeaf))
    }

    // Leaf of certbot.eff.org (RSA, issued by "YR2"), valid from 2026-08-23 to 2026-11-21.
    func testLetsEncryptRsaLeafIsTrustedOnlyForItsHost() {
        XCTAssertTrue(makeVerifier(hosts: ["certbot.eff.org"]).verify(Self.certbotLeaf))
        XCTAssertFalse(makeVerifier(hosts: ["letsencrypt.org"]).verify(Self.certbotLeaf))
    }

    func testLetsEncryptLeafIsNotTrustedAfterExpiration() {
        let expiredDate = Date(timeIntervalSince1970: 1_798_000_000) // 2026-12-23
        let verifier = NCTurnCertificateVerifier(hosts: ["letsencrypt.org"], verifyDate: expiredDate, allowsNetworkFetch: false)

        XCTAssertFalse(verifier.verify(Self.letsencryptOrgLeaf))
    }

    // MARK: - Certificates that must not be trusted

    // The leaf is signed by a certificate with basicConstraints CA:FALSE
    func testLeafSignedByNonCaIsNotTrusted() {
        XCTAssertFalse(makeVerifier(hosts: ["turn.fixture.test"]).verify(Self.nonCaSignedLeaf))
    }

    // The issuer name is the one of the Let's Encrypt intermediate "YE2", but the leaf is signed by another key
    func testLeafWithLetsEncryptIssuerNameSignedByForeignKeyIsNotTrusted() {
        XCTAssertFalse(makeVerifier(hosts: ["turn.fixture.test"]).verify(Self.fakeLetsEncryptIssuerLeaf))
    }

    func testSelfSignedLeafIsNotTrusted() {
        XCTAssertFalse(makeVerifier(hosts: ["turn.fixture.test"]).verify(Self.selfSignedLeaf))
    }

    func testNoHostsIsNotTrusted() {
        XCTAssertFalse(makeVerifier(hosts: []).verify(Self.letsencryptOrgLeaf))
    }

    func testGarbageIsNotTrusted() {
        let verifier = makeVerifier(hosts: ["letsencrypt.org"])

        XCTAssertFalse(verifier.verify(Data()))
        XCTAssertFalse(verifier.verify(Data([0x00, 0x01, 0x02, 0x03])))
        XCTAssertFalse(verifier.verify(Data("-----BEGIN CERTIFICATE-----".utf8)))
        XCTAssertFalse(verifier.verify(Self.letsencryptOrgLeaf.prefix(100)))
    }

    // MARK: - Built-in intermediates

    func testBuiltInIntermediatesAreValidCertificates() {
        for item in NCTurnIntermediateCertificates.all {
            let data = Data(base64Encoded: item.base64)

            XCTAssertNotNil(data, item.name)
            XCTAssertEqual(data.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }, item.sha256, item.name)
            XCTAssertNotNil(data.flatMap { SecCertificateCreateWithData(nil, $0 as CFData) }, item.name)
        }
    }

    // MARK: - Fixtures (certificates only, no private keys)

    // letsencrypt.org, issued by Let's Encrypt YE2 (ECDSA)
    private static let letsencryptOrgLeaf = Data(base64Encoded: [
        "MIIERjCCA8ygAwIBAgISBUOTO+OGs6KzrdU08hA7yLZfMAoGCCqGSM49BAMDMDMxCzAJBgNVBAYT",
        "AlVTMRYwFAYDVQQKEw1MZXQncyBFbmNyeXB0MQwwCgYDVQQDEwNZRTIwHhcNMjYwOTA0MTQzNDMy",
        "WhcNMjYxMjAzMTQzNDMxWjAaMRgwFgYDVQQDEw9sZXRzZW5jcnlwdC5vcmcwWTATBgcqhkjOPQIB",
        "BggqhkjOPQMBBwNCAATp5UB7Qx5GuY5F5KrLQKvmP5knuLeB4zJW5xR0X/pDW1LGprVmxVYOByFW",
        "40z+NVVP8JIv6yJK8Xo5UTkEwrMNo4IC1zCCAtMwDgYDVR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoG",
        "CCsGAQUFBwMBMAwGA1UdEwEB/wQCMAAwHQYDVR0OBBYEFBZojR4qMkiMtfEQChYINwg7nTAjMB8G",
        "A1UdIwQYMBaAFLlZ8o7PIvCG0zdI/3YUGLqC2FWHMDMGCCsGAQUFBwEBBCcwJTAjBggrBgEFBQcw",
        "AoYXaHR0cDovL3llMi5pLmxlbmNyLm9yZy8wgdMGA1UdEQSByzCByIISY3AubGV0c2VuY3J5cHQu",
        "b3JnghpjcC5yb290LXgxLmxldHNlbmNyeXB0Lm9yZ4ITY3BzLmxldHNlbmNyeXB0Lm9yZ4IbY3Bz",
        "LnJvb3QteDEubGV0c2VuY3J5cHQub3JngglsZW5jci5vcmeCD2xldHNlbmNyeXB0LmNvbYIPbGV0",
        "c2VuY3J5cHQub3Jngg13d3cubGVuY3Iub3JnghN3d3cubGV0c2VuY3J5cHQuY29tghN3d3cubGV0",
        "c2VuY3J5cHQub3JnMBMGA1UdIAQMMAowCAYGZ4EMAQIBMC4GA1UdHwQnMCUwI6AhoB+GHWh0dHA6",
        "Ly95ZTIuYy5sZW5jci5vcmcvOTYuY3JsMIIBDAYKKwYBBAHWeQIEAgSB/QSB+gD4AHcA2AlVO5RP",
        "ev/IFhlvlE+Fq7D4/F6HVSYPFdEucrtFSxQAAAGgbQ1JKQAABAMASDBGAiEA0C4lpJ1/yBjWe16/",
        "I137doODEVKvcSJFXJ8ioiZGaQECIQDWQjeqdmhAM4eaHWB0wUKMtjmH1bHdcSEUbkdN0T8fFQB9",
        "AEavhj07PuWfpXfeqCRdNrDZ7SKiI/Rhd0EilFLulVBfAAABoG0NSdgACAAABQAk39sMBAMARjBE",
        "AiAxL4PWQmUmDVjX3cOZtq28GdU5lq3195NQuF+2RYfCjQIgC4OZ2HT0Bv0blVhHn8petcUkgzhw",
        "S/2HeZopg+hLsJowCgYIKoZIzj0EAwMDaAAwZQIxAO4dsHw1iJgVV7iIcyOSqb9Av+iuAkjm9Hot",
        "GPxDUtOAmv/O4CoNSinmgKKU9U8U2QIwNQiZO7yJWyOg72Qk4rKzuMLY1ZVF3vMD6OeCeKWewh+t",
        "6xT8OVHH4RjpFrSlSN4J"
    ].joined())!

    // certbot.eff.org, issued by Let's Encrypt YR2 (RSA)
    private static let certbotLeaf = Data(base64Encoded: [
        "MIIFizCCBHOgAwIBAgISBXnoOKlHqpxeWbWWFwcZhvjOMA0GCSqGSIb3DQEBCwUAMDMxCzAJBgNV",
        "BAYTAlVTMRYwFAYDVQQKEw1MZXQncyBFbmNyeXB0MQwwCgYDVQQDEwNZUjIwHhcNMjYwODIzMjA1",
        "MzUxWhcNMjYxMTIxMjA1MzUwWjAaMRgwFgYDVQQDEw9jZXJ0Ym90LmVmZi5vcmcwggEiMA0GCSqG",
        "SIb3DQEBAQUAA4IBDwAwggEKAoIBAQDba+0+GAFdmB5VSvUjhkPmKKnUH9870LmJscOZ33Z8Ts71",
        "v7j9UABsiPwEDPzlG/HF1OnLwBqd55e/UwjDJFmx1C5BC4YKGrROQSbqjU34fpNgBTHcrjoN3Rcf",
        "g7KlsXGp50KoZnEhQdaqfp0HbS++j32U88HOSN1M1jn2scOhU4RntPG6XHigawgGaAKEjOEEIeW0",
        "oZPwDfMaIg/YtT5FmMRGI72ar1Wg9fFV79jUsL0K+olW8OWcjWhPr9+HEp1VJzl8vSqeX53yJk6I",
        "uI3WWszf8cy2+kz5GTmBAgmFHhw2kAX88MM+hsnxghYXNAtIXUz1NElnMHTpsdUg33k/AgMBAAGj",
        "ggKwMIICrDAOBgNVHQ8BAf8EBAMCBaAwEwYDVR0lBAwwCgYIKwYBBQUHAwEwDAYDVR0TAQH/BAIw",
        "ADAdBgNVHQ4EFgQUGv5NSfh8bkvzbhjifmwfExZP4U0wHwYDVR0jBBgwFoAUQBUtJnntMiCe35py",
        "HdYyH4EMgQwwMwYIKwYBBQUHAQEEJzAlMCMGCCsGAQUFBzAChhdodHRwOi8veXIyLmkubGVuY3Iu",
        "b3JnLzCBrAYDVR0RBIGkMIGhghRjZXJ0Ym90LXByb2QuZWZmLm9yZ4ILY2VydGJvdC5jb22CD2Nl",
        "cnRib3QuZWZmLm9yZ4IMY2VydGJvdC5pbmZvggtjZXJ0Ym90Lm5ldIILY2VydGJvdC5vcmeCD3d3",
        "dy5jZXJ0Ym90LmNvbYIQd3d3LmNlcnRib3QuaW5mb4IPd3d3LmNlcnRib3QubmV0gg93d3cuY2Vy",
        "dGJvdC5vcmcwEwYDVR0gBAwwCjAIBgZngQwBAgEwLgYDVR0fBCcwJTAjoCGgH4YdaHR0cDovL3ly",
        "Mi5jLmxlbmNyLm9yZy83OS5jcmwwggEMBgorBgEEAdZ5AgQCBIH9BIH6APgAdgDXbX0Q0af1d8LH",
        "6V/XAL/5gskzWmXh0LMBcxfAyMVpdwAAAaAwnD81AAAEAwBHMEUCIGmHMglKk49Tbkc3u1Z61kDK",
        "Glf9iqKRyPHEUQNc8LMXAiEAj0tftHGjcdHhezq0xV3v6Z99ES+mWGC2RhTIaLCls00AfgCoJsvj",
        "CsY1EkZTP+Bl8U8Z2W4ZCBPEHdlteQCzEjxVJwAAAaAwnEC8AAgAAAUAIyUppgQDAEcwRQIhAL3m",
        "UFvJJ2m50L3btU0IYs/FGFnKuLhbN/lmT5E4mp+DAiAv5GbQ55cUiQwoyyxelf6yH1AcEw7FgVi4",
        "4NwiyIxuozANBgkqhkiG9w0BAQsFAAOCAQEAr2zxIT/oSxcKCE69a1EPPp/CbkxENbXjpYmkpcGZ",
        "/Zbf6eS+Q9W2kbhxSkccdOSMRP1ATrLnMXj3ignHZWnSBraCPGyACNE6bQD/FgdjYhOR/ZlLsUFP",
        "noYfJORyQY7IVzwBgXQV2kg986MYLBRnqucJ6DMZqWk7B3PdrEVmewlwRV4fRwUVWygGoSsvUNmd",
        "StbQB2kP9ZSqnErjCVVKQ52BZ/Xe+3lnaUzdSULYgk05ixlNsY1TQUBfglcV/rpip2klBrrXvJ06",
        "7sadraEmZo5NgaC74iQtdBOlSQyfzBq6wAtMdVtQnu5ifdpl1JgPY1pkvhPjWNAk/yUUUN6ZQQ=="
    ].joined())!

    // turn.fixture.test, signed by a self-signed certificate with CA:FALSE
    private static let nonCaSignedLeaf = Data(base64Encoded: [
        "MIIBwDCCAWWgAwIBAgIUIJYU9S0FE0KeAImKHowwC9DfU5MwCgYIKoZIzj0EAwIwIDEeMBwGA1UE",
        "AwwVRml4dHVyZSBOb24tQ0EgU2lnbmVyMB4XDTI2MTAwNjIwMzg0NVoXDTM2MTAwMzIwMzg0NVow",
        "HDEaMBgGA1UEAwwRdHVybi5maXh0dXJlLnRlc3QwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAASZ",
        "9zXZKN90gj6ifq5YLC+2pQtuTsvNdo0sOzLOdoHoY6eJ52E9t/ERCNgGVBqg/Ri+JAu9MnnBt8D/",
        "hheOiQYuo4GAMH4wHAYDVR0RBBUwE4IRdHVybi5maXh0dXJlLnRlc3QwCQYDVR0TBAIwADATBgNV",
        "HSUEDDAKBggrBgEFBQcDATAdBgNVHQ4EFgQUb2qPKHZ63SC9J280kdx0ubell8swHwYDVR0jBBgw",
        "FoAUVzX50R2i/Az03EkpjhTkjSjisE8wCgYIKoZIzj0EAwIDSQAwRgIhAJl/D6I516AklKl7Ltu3",
        "xqbufCQ6cnj9Uevx2ZDQZmIHAiEA7bECEi15TWPNZ+SK3t+Krod80FWcIKYPlQdh28nOh6c="
    ].joined())!

    // turn.fixture.test, issuer name "C=US, O=Let's Encrypt, CN=YE2", signed by a foreign key
    private static let fakeLetsEncryptIssuerLeaf = Data(base64Encoded: [
        "MIIB0jCCAXigAwIBAgIUR9iO++gRL+bRBK8n2ITt0e9+wCMwCgYIKoZIzj0EAwIwMzELMAkGA1UE",
        "BhMCVVMxFjAUBgNVBAoMDUxldCdzIEVuY3J5cHQxDDAKBgNVBAMMA1lFMjAeFw0yNjEwMDYyMDM4",
        "NDVaFw0zNjEwMDMyMDM4NDVaMBwxGjAYBgNVBAMMEXR1cm4uZml4dHVyZS50ZXN0MFkwEwYHKoZI",
        "zj0CAQYIKoZIzj0DAQcDQgAEmfc12SjfdII+on6uWCwvtqULbk7LzXaNLDsyznaB6GOniedhPbfx",
        "EQjYBlQaoP0YviQLvTJ5wbfA/4YXjokGLqOBgDB+MBwGA1UdEQQVMBOCEXR1cm4uZml4dHVyZS50",
        "ZXN0MAkGA1UdEwQCMAAwEwYDVR0lBAwwCgYIKwYBBQUHAwEwHQYDVR0OBBYEFG9qjyh2et0gvSdv",
        "NJHcdLm3pZfLMB8GA1UdIwQYMBaAFCVnWC2RQAmzNDdxq0b4fXCfDRAKMAoGCCqGSM49BAMCA0gA",
        "MEUCIEhnq0POi+O/SWereY2Rhp6jhyrTOkYgFL/1utqhOARuAiEAl65NgHaVj6d59On1hgLTi+sp",
        "2ky1lDZ53tJ+JfPGdvc="
    ].joined())!

    // turn.fixture.test, self-signed
    private static let selfSignedLeaf = Data(base64Encoded: [
        "MIIBqjCCAVGgAwIBAgIUBGMPOsv05g9cW4SBBDvZU6BDaT0wCgYIKoZIzj0EAwIwHDEaMBgGA1UE",
        "AwwRdHVybi5maXh0dXJlLnRlc3QwHhcNMjYxMDA2MjAzODQ1WhcNMzYxMDAzMjAzODQ1WjAcMRow",
        "GAYDVQQDDBF0dXJuLmZpeHR1cmUudGVzdDBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABNduobMj",
        "5btviT3MO7FG2MFJqFSAJgRRZBJEgzqFxhMDZt5JLvU5ih6Xz5QB4soGJJXaxlkMktA6BXfgJwWi",
        "QhyjcTBvMB0GA1UdDgQWBBT5vLxxzohW/8Yn6Xmp5Ra1KIg4mDAfBgNVHSMEGDAWgBT5vLxxzohW",
        "/8Yn6Xmp5Ra1KIg4mDAPBgNVHRMBAf8EBTADAQH/MBwGA1UdEQQVMBOCEXR1cm4uZml4dHVyZS50",
        "ZXN0MAoGCCqGSM49BAMCA0cAMEQCIGwNqEpsaT4SwI8BQVKFqu3cRJL5Ur8thNCvW3IkuIk/AiAq",
        "FGaSmBSwx5nNbhcQb5w9IRJvE9r4mKx7hq5Llpawcg=="
    ].joined())!
}
