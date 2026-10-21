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
