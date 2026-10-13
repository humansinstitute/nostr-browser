# Desktop FIPS control and diagnosis

Setup → FIPS transport provides a persisted WMapp FIPS on/off control.
Turning it off blocks new WMapp mesh access, cancels app readiness retries,
and revokes active browser transport handles and app-owned Drive resources.
Ordinary HTTPS browsing remains available. FIPS-only destinations require
re-enabling FIPS; a selected mesh service never falls back to public HTTPS.

Desktop FIPS currently runs as a separately installed system daemon. WMapp
configuration attestation does not establish exclusive ownership of that daemon.
The app switch therefore does not stop or uninstall it, remove its identity,
change its configuration, or revoke another application's access. The switch
cannot promise that all system FIPS network activity or battery use stops.
Mobile additionally stops its app-owned VPN runtime through the existing native
channel. Re-enabling permits a fresh readiness check and fresh document grants;
it does not restore old live transport authority.

An already dispatched desktop command may finish before its result is discarded;
off prevents subsequent commands and cancels retry waits. In particular, a
previously approved system installation/repair operation is not forcibly killed
or rolled back. Turning off app access does not undo system administration.

## Bootstrap warning

The warning means the exact authenticated bootstrap peer was not observed
connected before the readiness deadline. It is not proof that a firewall blocks
UDP. A missing route, peer outage, VPN interaction, NAT or daemon state can also
need investigation. The connection retains the configured exact peer pin.

Historically each sequential desktop readiness request could launch twelve
peer-status subprocesses at 500 ms intervals and one connect subprocess.
Concurrent requests were coalesced, but later requests repeated the sequence.
Repeated mesh navigation could therefore repeat both work and warning toasts.
The runtime now bounds repeated failure attempts and cancels retries when off;
Setup is the place to inspect the current state and explicitly retry.

## Validation procedure

Run repository checks without launching or replacing an installed app:

```sh
cd app
flutter test
flutter analyze
flutter build macos --debug
codesign --verify --deep --strict --verbose=2 "build/macos/Build/Products/Debug/Nostr Browser.app"
```

On an authorized test app, approve one exact FIPS endpoint and open a stream or
WebSocket. Turn FIPS off and verify the handle, stream and socket close, stale
replies cannot reconnect, and no readiness retry or Drive mesh timer continues.
Try a fresh FIPS destination and confirm a disabled explanation. Browse an
ordinary HTTPS page. Relaunch and verify off persists. Re-enable, then verify
readiness and fresh consent/handle creation recover without restoring a stale
grant. Check mobile VPN stop/re-enable separately.

For battery diagnosis on the affected laptop, record app version, FIPS switch
state, power source and a fixed observation interval. Compare idle HTTPS use,
failed mesh attempts, and FIPS off under equivalent conditions. Use Activity
Monitor Energy/CPU, process samples, network counters and `pmset -g assertions`.
Inspect only relevant sanitized daemon/app logs and peer status. Separate WMapp,
system FIPS daemon and WebView processes. CPU percentage alone does not measure
battery consumption; compare discharge/energy data on that laptop. Do not infer
laptop measurements from a development host, and do not publish device IDs or
private log contents.

## Release and installation

A local debug build validates source compilation; it does not update an installed
app or constitute a distributable release. Follow [Mac build and install](deploy/mac.md)
for a private `./tools/build_macos_dmg.sh --local` build with a stable signing
identity, or the public Developer ID/notarized `--public` workflow. Verify the
artifact checksum and install through that workflow on the target Mac. Do not
distribute unsigned/ad-hoc staging output as a normal update. No shared-service
restart is required or authorized by this source change.
