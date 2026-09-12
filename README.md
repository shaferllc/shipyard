# Shipyard

Keeps every Shafer LLC Mac app in one place: versions, git, releases and updates.

## Build

```sh
./make-app.sh          # builds for this Mac, installs to /Applications, launches it
./make-app.sh --dist   # a universal dist/Shipyard.app plus a .zip and .dmg
swift test
```

macOS 14+, Swift 6. No third-party dependencies; registration comes from
Shafer LLC's own [swift-licensing](https://github.com/shaferllc/swift-licensing).

## Releasing

Bump `VERSION` in a commit on `main`. The release workflow (the shared
[shaferllc/.github mac-release](https://github.com/shaferllc/.github)) builds
the universal app, signs it with the Developer ID, notarizes and staples it,
and publishes `Shipyard-<version>.dmg`, a `.zip`, and a stable-named
`Shipyard.dmg`. Run the workflow by hand for a dry run.

If Shipyard starts using Apple Events, the camera, the microphone, calendars,
contacts, photos or location, add `Shipyard.entitlements` at the repo root —
the hardened runtime denies them otherwise.

## Registration

Optional and free — nothing is gated on it. **Account… → Register…** opens
shafer.llc; after sign-in the site hands the key back through
`shipyard://activate`, and Shipyard checks it and keeps it in the keychain.
Help and Contact Support are in the Help menu.

## License

MIT — see [LICENSE](LICENSE).
