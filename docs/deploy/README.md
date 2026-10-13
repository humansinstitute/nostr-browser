# WMApp Deploy Notes

These notes cover the easiest current ways to build and run Wingman App on personal devices.

- [Mac](mac.md)
- [Linux (Ubuntu and Omarchy)](linux.md)
- [Android Tablet](android.md)
- [iPhone](iphone.md)

All root `build_*.sh` helpers first download, build and bundle the latest Flight
Deck `main` from GitHub, then remove the temporary checkout and dependencies. See [source selection and prerequisites](../../README.md#repository-checkout).
A separate Flight Deck build and WMApp commit/push are no longer prerequisites.
Manual `flutter build` commands do not refresh the bundle.

The current Flutter app is usable as a browser/signer shell on mobile. Desktop-only features that shell out to `wmapp-core`, such as the local Drive mount and some core-backed operations, are expected to report unavailable on mobile until those paths are made native.
