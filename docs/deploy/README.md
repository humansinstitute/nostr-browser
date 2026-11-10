# WMApp Deploy Notes

These notes cover the easiest current ways to build and run Wingman App on personal devices.

- [Mac](mac.md)
- [Linux (Ubuntu and Omarchy)](linux.md)
- [Android Tablet](android.md)
- [iPhone](iphone.md)

Root build helpers package the Nostr Browser shell and its native dependencies.
They do not fetch or bundle Flight Deck or Ambulando. See [source selection and
prerequisites](../../README.md#repository-checkout).

Apple production distribution has additional requirements beyond a successful
private TestFlight build. See [App Store readiness](app-store.md) before selecting
an upload or submission workflow.

The current Flutter app is usable as a browser/signer shell on mobile. Desktop-only features that shell out to `wmapp-core`, such as the local Drive mount and some core-backed operations, are expected to report unavailable on mobile until those paths are made native.
