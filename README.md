<div align="center">
  <img alt="Swiftfin-HTTPS" src="./Resources/primary-wide.svg">

  <h1>Swiftfin-HTTPS</h1>
  <img src="https://img.shields.io/badge/Base-Upstream%201.4-9962be"/>
  <img src="https://img.shields.io/badge/iOS-Unsigned%20IPA-red"/>
  <img src="https://img.shields.io/badge/tvOS-Unsigned%20ZIP-red"/>
</div>

<p align="center">
  <b>Swiftfin-HTTPS</b> is a public fork of <a href="https://github.com/jellyfin/Swiftfin">jellyfin/Swiftfin</a> for self-hosted Jellyfin servers that use <b>self-signed</b> or <b>untrusted HTTPS certificates</b>.
</p>

## Why This Fork Exists

This fork is for environments where the official client may fail because the Jellyfin server is behind:

- self-signed HTTPS
- untrusted HTTPS certificates
- reverse proxy or custom HTTPS setups that trigger certificate validation failures

Typical search terms this fork is meant to address include:

- `swiftfin self signed https`
- `swiftfin untrusted certificate`
- `swiftfin certificate invalid`
- `jellyfin ios self signed https`

## What Is Different

Compared with upstream Swiftfin, this fork adds:

- HTTPS compatibility for API requests against self-signed or untrusted certificates
- a local `127.0.0.1` playback proxy so media playback can work even when the remote server certificate is not trusted by iOS/tvOS
- GitHub Releases that publish unsigned iOS and tvOS build artifacts

## Releases

GitHub Releases for this fork publish:

- unsigned iOS `.ipa`
- unsigned tvOS `.zip`

Additional fork-specific release notes are documented in [Documentation/custom-release.md](./Documentation/custom-release.md).

## Upstream

This repository is a fork, not a replacement for the official project.

- upstream repository: <https://github.com/jellyfin/Swiftfin>
- upstream documentation: <https://github.com/jellyfin/Swiftfin/tree/main/Documentation>

For general Swiftfin usage, player behavior, supported libraries, contribution guidance, and broader project information, refer to the upstream project.

## Issues

Please use this fork's issue tracker for problems specifically related to:

- self-signed HTTPS
- untrusted certificates
- certificate validation failures
- playback behavior unique to this fork's HTTPS compatibility changes

For issues unrelated to these fork-specific changes, prefer the upstream Swiftfin repository.
