# Linux WM-App build and FIPS activation

WM-App supports Ubuntu and Arch/systemd-based Omarchy on x86_64 and aarch64.
The Linux build bundles the checksum-pinned FIPS v0.5.0 systemd release; users
do not download or install FIPS separately.

## Build

Install Flutter's normal Linux desktop prerequisites, then run:

```bash
./build_linux.sh
```

The Flutter CMake build downloads the matching upstream FIPS archive once,
verifies its release SHA-256, and places it below `data/fips` in the relocatable
application bundle. The cache under `app/linux/.fips-cache` is ignored by Git.

Run the resulting `wingman_app` binary from the generated bundle. Moving the
bundle is supported as long as its `data` and `lib` directories remain beside
the executable.

## First FIPS app

Opening an exact `http://<npub>.fips:<port>/` URL causes WM-App to inspect the
local runtime. If installation or repair is required, the desktop's PolicyKit
agent displays a normal administrator authorization prompt through `pkexec`.
The bundled installer then:

- installs the upstream binaries and systemd units under `/usr/local`,
  `/etc/fips`, and `/etc/systemd/system`;
- preserves an existing `/etc/fips/fips.yaml`, identity, hosts file, firewall
  configuration, and peer list;
- enables persistent identity, `.fips` split DNS, Nostr/LAN discovery, and the
  pinned authenticated bootstrap peer;
- enables and starts `fips.service` and `fips-dns.service` at boot;
- adds the authorizing desktop user to the `fips` diagnostics group.

The app can use the mesh immediately. A logout/login may be needed before
`fipsctl` diagnostics work without administrator access because existing Linux
processes do not acquire newly added supplementary groups.

Ubuntu normally uses the bundled helper's `systemd-resolved` backend. Omarchy
can use systemd-resolved, standalone dnsmasq, or NetworkManager's dnsmasq
plugin. If none is active, the helper logs manual split-DNS instructions and
keeps FIPS itself running.

`pkexec` and an active graphical PolicyKit authentication agent are required
for first activation. Both Ubuntu desktop and normal Omarchy installations
provide this OS authorization boundary.

The current bootstrap is FIPS's public `test-us01` service at pinned IP
`217.77.8.91:2121`. Noise authenticates its npub; production releases must move
to Wingman-operated bootstrap capacity.
