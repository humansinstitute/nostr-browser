import Foundation
import NetworkExtension

@main
struct SettingsTests {
    static func main() {
        let address = "fd12:3456::1"
        let settings = FipsTunnelSettings.make(ipv6: address)
        precondition(settings.ipv6Settings?.addresses == [address])
        let v6 = settings.ipv6Settings!.includedRoutes!
        precondition(v6.count == 1 && v6[0].destinationAddress == "fd00::" && v6[0].destinationNetworkPrefixLength == 8)
        let v4 = settings.ipv4Settings!.includedRoutes!
        precondition(v4.count == 1 && v4[0].destinationAddress == "10.1.1.1" && v4[0].destinationSubnetMask == "255.255.255.255")
        precondition(settings.dnsSettings?.servers == ["10.1.1.1"])
        precondition(settings.dnsSettings?.matchDomains == ["fips"])
        precondition(settings.dnsSettings?.matchDomainsNoSearch == true)
        precondition(settings.mtu == 1280)
        print("PASS: mesh IPv6 route, DNS-only IPv4 route, split DNS, no default route, MTU")
    }
}
