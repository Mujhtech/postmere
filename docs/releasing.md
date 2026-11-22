# Releasing Postmere

Postmere updates itself with [Sparkle](https://sparkle-project.org). The app
reads `appcast.xml` from this repository's `main` branch, and downloads each
release from GitHub Releases. Sparkle installs an update only if its signature
matches the public key built into the app.

## What lives where

| Item | Where | Public? |
| --- | --- | --- |
| Public key (`SUPublicEDKey`) | `postmere/Info.plist` | Yes |
| Feed (`appcast.xml`) | repository root | Yes |
| Release script | `script/release.sh`, `script/ExportOptions.plist` | Yes |
| **Private signing key** | login keychain, account `postmere` | **Never** |
| Notarization credentials | keychain profile `postmere-notary` | Never |

Anyone with the private key can publish an "update" every Postmere user will
install. Keep it out of the repository, issues, chat and CI logs. `.gitignore`
refuses common file names for an exported key, but do not rely on that.

## One-time setup

1. **Back up the signing key.** It was generated with
   `generate_keys --account postmere`. Export it once, store it in a password
   manager, then delete the file:

   ```sh
   build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account postmere -x ~/Desktop/postmere-signing-key
   ```

   If it is lost, existing installs can no longer be updated. If it leaks,
   publish a release signed with a new key and rotate `SUPublicEDKey`.
   (Sparkle supports key rotation when the update is also code-signed with the
   same Developer ID.)

2. **Store notarization credentials:**

   ```sh
   xcrun notarytool store-credentials postmere-notary --apple-id <you> --team-id 6JR3ZGLPD6
   ```

3. **Sign in to GitHub CLI:** `gh auth login`.

## Each release

```sh
script/release.sh 1.1.0
git add appcast.xml && git commit -m "release: Postmere 1.1.0" && git push
```

The script archives a Release build, exports it with Developer ID, notarizes and
staples it, signs the zip with the private key, adds it to `appcast.xml`, and
creates the GitHub release. Users see the update after `appcast.xml` reaches
`main`: within a day automatically, or right away with **Postmere → Check for
Updates…**.

Build numbers come from the commit count, so each release is newer than the last.

## Building in CI later

Store the exported key as a secret and pass it to `generate_appcast` with
`--ed-key-file -` on standard input. Never echo it, and never write it into the
workspace.
