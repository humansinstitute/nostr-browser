# WM-App Android FIPS bridge

This crate is WM-App's JNI bridge to the official FIPS embedded API. Its Cargo
dependency is pinned to the peeled source commit for the annotated `v0.5.0`
tag (`80f8f965aa872296edbce84ade9949ece2596602`); `Cargo.lock` records the same
Git source. The annotated tag object is
`62999c7dbdca53cfd199b062a025af4c00c23a2e`.

Gradle runs `cargo ndk` and copies the generated ARM64 shared library to
`app/android/app/src/main/jniLibs/arm64-v8a`. That directory is an ignored
build output: it is regenerated from the pinned source and is never committed.
Cargo's normal source/target caches are also ignored. The Kotlin JNI declarations
are hand-maintained source rather than generated output.

No identity is part of this crate or its artifacts. On-device Rust creates
`files/fips/fips.machine.key` with mode `0600` using create-new semantics and
reuses it on later starts. Only its public npub and derived IPv6 address cross
JNI; the key never enters Flutter.
