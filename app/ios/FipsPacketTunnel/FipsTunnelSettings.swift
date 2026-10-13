import NetworkExtension

// Kept independent of the Rust boundary for configuration regression tests.
enum FipsTunnelSettings {
    static func make(ipv6: String) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "217.77.8.91")
        let v6 = NEIPv6Settings(addresses: [ipv6], networkPrefixLengths: [128])
        v6.includedRoutes = [NEIPv6Route(destinationAddress: "fd00::", networkPrefixLength: 8)]
        settings.ipv6Settings = v6
        let v4 = NEIPv4Settings(addresses: ["10.1.1.2"], subnetMasks: ["255.255.255.255"])
        v4.includedRoutes = [NEIPv4Route(destinationAddress: "10.1.1.1", subnetMask: "255.255.255.255")]
        settings.ipv4Settings = v4
        let dns = NEDNSSettings(servers: ["10.1.1.1"])
        dns.matchDomains = ["fips"]
        dns.matchDomainsNoSearch = true
        settings.dnsSettings = dns
        settings.mtu = 1280
        return settings
    }
}
