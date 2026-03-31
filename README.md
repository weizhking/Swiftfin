<div align="center">
  <img alt="Swiftfin" src="./Resources/primary-wide.svg">

  <h1>Swiftfin</h1>
  <img src="https://img.shields.io/badge/iOS-16+-red"/>
  <img src="https://img.shields.io/badge/tvOS-17+-red"/>
  <img src="https://img.shields.io/badge/Jellyfin-10.11-9962be"/>
  
  <a href="https://translate.jellyfin.org/engage/swiftfin/">
    <img src="https://translate.jellyfin.org/widgets/swiftfin/-/svg-badge.svg"/>
  </a>
  <a href="https://matrix.to/#/#jellyfin:matrix.org">
    <img src="https://img.shields.io/matrix/jellyfin:matrix.org">
  </a>
  <a href="https://discord.gg/zHBxVSXdBV">
    <img src="https://img.shields.io/badge/Talk%20on-Discord-brightgreen">
  </a>
</div>

<p align="center">
  <b>Swiftfin-HTTPS</b> is a Swiftfin fork for <a href="https://github.com/jellyfin/jellyfin">Jellyfin</a> servers that use <b>self-signed</b> or <b>untrusted HTTPS certificates</b>. It is intended for self-hosted environments where the official client may fail with certificate errors such as <b>certificate invalid</b>, <b>server certificate untrusted</b>, or playback failures caused by custom HTTPS setups.
</p>

## Fork Focus

This fork is currently based on the upstream `1.4` tag.

It specifically targets these scenarios:

- Jellyfin servers behind self-signed HTTPS
- Jellyfin servers using untrusted HTTPS certificates
- reverse proxy / custom HTTPS setups where official iOS playback may fail

The main changes in this fork are:

- API requests accept self-signed or untrusted HTTPS certificates
- media playback is routed through a local `127.0.0.1` proxy so playback can work even when the remote server certificate is not trusted by iOS/tvOS
- GitHub Releases publish unsigned iOS and tvOS build assets

See [Documentation/custom-release.md](./Documentation/custom-release.md) for the custom release workflow and fork-specific notes.

## ⚡️ Download

<a href="https://apps.apple.com/us/app/swiftfin/id1604098728">
  <img height=75 alt="Download on the Apple App Store" src="./Resources/Download_on_the_App_Store_Badge_US-UK_RGB_blk_092917.svg"/>
</a>

## 🛠️ TestFlight

Use the TestFlight version to test new features and bug fixes before being published to the App Store. We are grateful for your time and resources for reporting new bugs.

> [!NOTE]
> Only iOS has a TestFlight version. See [this discussion](https://github.com/jellyfin/Swiftfin/discussions/1294) for tvOS updates.

<a href="https://testflight.apple.com/join/SqNPfdxq">
  <img height=75 alt="Get the beta on TestFlight" src="./Resources/testflight.svg"/>
</a>

## 📖 Documentation

Swiftfin provides detailed documentation to help you understand key aspects of the app and its development approach:

- [🎞️ Library Support](https://github.com/jellyfin/Swiftfin/blob/main/Documentation/libraries.md) — Information on **library compatibility** and supported media types in Swiftin.
- [🎬 Media Playback](https://github.com/jellyfin/Swiftfin/blob/main/Documentation/players.md) — Learn about Swiftfin's **Native** and **Swiftfin** players and how their features vary.
- [🧩 OS Version Support](https://github.com/jellyfin/Swiftfin/blob/main/Documentation/version.md) — Read about how we determine the **minimum supported OS** and which versions of iOS & tvOS are supported.
- [💜 Supporting Development](https://jellyfin.org/docs/general/contributing/direct-donations) — Learn how you can **support the project developers** and help keep Swiftfin improving.

## ⚙️ Development

Thank you for your interest in Swiftfin! Please check out the [Contribution Guidelines](https://github.com/jellyfin/Swiftfin/blob/main/Documentation/contributing.md) to get started.

## 📚 Translations

**Don't see Swiftfin in your language?**

Check out our [Weblate instance](https://translate.jellyfin.org/projects/swiftfin/) to help translate Swiftfin and other Jellyfin projects.

<a href="https://translate.jellyfin.org/engage/swiftfin/">
<img src="https://translate.jellyfin.org/widgets/swiftfin/-/multi-auto.svg"/>
</a>
