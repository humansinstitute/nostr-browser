# NStack display and identity validation

1. Add a reachable NStack with the unlocked native identity. Rename it to a
   friendly local name, select a backup workspace and save a browser link and
   preference. Restart the app; confirm the name and associations remain.
2. Refresh workspace discovery and confirm it preserves the local name.
3. Edit the address to an endpoint advertising the same complete Tower service
   npub. Confirm there is one saved NStack, the selected workspace remains and
   browser settings and backup selection persist. Endpoint metadata is refreshed.
4. Try an endpoint advertising another Tower identity or omitting identity.
   Confirm rejection leaves saved data unchanged. Add a separate connection if
   that identity is intentional. Legacy connections may need a successful refresh
   at the old endpoint before an identity-preserving move is possible.
5. Review cards, workspace rows, active identity introduction, service status,
   backup summaries, selector labels and routine failure messages. URLs,
   hostnames, full public keys and UUIDs should appear only after deliberate
   reveal/edit actions. Neutral legacy names and unavailable identities are
   expected when discovery has not supplied identity metadata.
6. Open connection details, copy the full identities and inspect/edit the URL.
   Close the details and confirm ordinary displays hide those values again.
   Give two NStacks the same name; their abbreviated public identities should
   distinguish them. Abbreviations must never be used for identity matching.

Automated checks: run Flutter analysis, then Flutter tests sequentially. The
identity edit tests reload a new preferences-backed store to simulate restart;
widget tests cover hidden default values, explicit reveal and rename. These do
not establish real remote discovery, device restart or TestFlight availability.

## Multiple saved connections

Use a disposable test profile, never an existing personal registry. Add two
addresses, including endpoints that advertise the same Tower service identity.
Both cards must remain in insertion order. Re-add a canonical spelling of the
second address (case/trailing slash); it refreshes the same card. Add a third
address and confirm all three remain. Select, rename, refresh and explicitly
edit one connection; the others must retain their names, workspace aliases,
links, background, preferences, host and backup selections. Close and reopen the
app and verify the complete list and selections again. An address edit to an
already saved address must fail without changing either connection.

`flutter test test/nstack_multi_stack_test.dart` exercises these persistence and
concurrent-write cases with synthetic discovery and in-memory preferences; a
new store instance reads the saved data to simulate reopen. It does not establish
physical-device installation or a real OS-process restart.
