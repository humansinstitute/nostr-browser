# Isolated native GRASP probe

This tool runs the production Dart bridge/transport through a separate stock macOS
WKWebView and its production native frame policy. The WebView uses nonpersistent
storage and no signer. The test harness approves only its command-line endpoint;
it does not exercise the product's native consent dialog or establish member UX.
It never connects to the running WMapp profile or keychain.

From the repository root, resolve dependencies in `app/`, then:

```sh
# Choose a Git-ignored evidence directory according to AGENTS.md.
swiftc tools/grasp_bridge/main.swift \
  packages/webview_flutter_wkwebview/darwin/webview_flutter_wkwebview/Sources/webview_flutter_wkwebview/WingmanScriptMessagePolicy.swift \
  -o "$evidence_dir/grasp-wk-probe"
dart --packages=app/.dart_tool/package_config.json \
  tools/grasp_bridge/native_server.dart https://example.com \
  'http://npub1qmc3cvfz0yu2hx96nq3gp55zdan2qclealn7xshgr448d3nh6lks7zel98.fips:8787' --fixture
```

The server prints a private random loopback RPC route for the native test process.
Do not expose it to web content or publish it. The production app has no such listener.
Create a test JavaScript file by prepending this configuration to `probe.js`:

```js
globalThis.graspProbe = {
  endpoint: 'http://npub1qmc3cvfz0yu2hx96nq3gp55zdan2qclealn7xshgr448d3nh6lks7zel98.fips:8787',
  fixture: true
};
```

Run the compiled probe with arguments: printed RPC route, `https://example.com`,
test JavaScript file, optional screenshot output. Stop only the test server you
started after completion. Fixture checks cover native binary HTTP, text/binary WS,
redirect rejection, pending-header abort, iframe-channel denial and disconnect.

For an authorized live private service, omit `--fixture`, use its exact HTTPS
frontend origin and exact FIPS endpoint, set `fixture:false`, and supply
`repositoryRoot`. Live probe expects the frontend CSP to block ordinary HTTP/WS,
then verifies the native bridge still obtains GRASP08 NIP11 and a NIP42 challenge.
It verifies anonymous root/refs remain denied. It performs no signing or publication.
A live pass explicitly reports `memberUX:false`.

The same source also builds a standalone iOS simulator app. Its native handler
uses the production shared Apple frame policy; its Dart transport runs in the host
fixture process. This checks real iOS WebKit channel enforcement and JavaScript
HTTP/WS behavior, but does not prove in-app Flutter integration, iOS FIPS daemon
routing, consent UI, signing, or a member's repository browsing flow.

On an Apple Silicon Mac with the iOS simulator SDK/runtime installed, build with:

```sh
python3 tools/grasp_bridge/build_ios_probe.py "$evidence_dir"
```

Create a fresh simulator using an available device type/runtime from `simctl` and
keep its identifier in a private shell variable. Do not use a member's existing
simulator or a physical device. Boot that simulator, wait for `bootstatus -b`, then:

```sh
xcrun simctl install "$probe_simulator" "$evidence_dir/GraspProbe.app"
xcrun simctl launch --console "$probe_simulator" \
  org.wingman.validation.GraspProbe "$probe_rpc" https://example.com \
  "$evidence_dir/tests.js"
```

`tests.js` is the same configured probe used above; provide its absolute path.
Both Apple harnesses first reject messages from real native main frames loaded
with HTTP and opaque/data origins, then reject subframe and borrowed-subframe
channel messages. Success requires all negative checks and transport checks.
Shutdown and delete only the fresh simulator created for this run when finished.
Keep simulator identifiers and raw simulator output exclusively in ignored local
evidence. The simulator app uses ephemeral WebKit storage, contains no signer,
and requests only local networking for its fixture RPC connection.
