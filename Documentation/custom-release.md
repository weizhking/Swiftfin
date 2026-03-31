# Custom Release Notes

This repository is a personal fork of `jellyfin/Swiftfin`, currently based on the upstream `1.4` tag.

## Purpose

This fork exists to support a Jellyfin server that:

- is exposed over `HTTPS`
- uses an untrusted or self-signed certificate
- cannot be accessed over plain `HTTP`

To make that work on iOS, this fork includes two custom changes:

- API requests accept the server's HTTPS certificate even when iOS would normally reject it
- media playback is routed through a local `127.0.0.1` proxy inside the app, so AVPlayer/VLC no longer connects directly to the remote self-signed HTTPS stream

## Release Output

GitHub Actions builds and publishes:

- an unsigned iOS `.ipa`
- an unsigned tvOS `.app` bundle packaged as `.zip`

The release workflow is defined in [release.yml](../.github/workflows/release.yml).

## Installation

The generated `.ipa` is unsigned for distribution purposes.

Typical usage is:

1. Download the `.ipa` from GitHub Releases.
2. Re-sign it with your own certificate, signing service, or local signing tool.
3. Install it on your iPhone or iPad.

For Apple TV / tvOS:

1. Download the tvOS `.zip` asset from GitHub Releases.
2. Extract the contained `Swiftfin tvOS.app`.
3. Re-sign it with your own tooling if needed for your deployment flow.

## Versioning

This fork uses release tags like:

- `v1.4.0-nas.1`
- `v1.4.0-nas.2`
- `v1.4.0-nas.3`

The intent is to preserve the upstream `1.4` base while making custom fork builds easy to identify.

## Notes

- This fork is intended for personal/self-hosted use.
- The custom HTTPS handling is less secure than using a certificate trusted by iOS.
- If you can move the server to a certificate chain that iOS already trusts, that remains the cleaner long-term solution.
