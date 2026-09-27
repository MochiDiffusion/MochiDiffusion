# Releasing Mochi Diffusion

This document lists the steps to release a new version of Mochi Diffusion. Beads holds the
release epic for each version. The epic records the scope, and its acceptance criteria list
what must be true before the release.

## Before the release build

1. Make sure that every child of the release epic is closed or explicitly dropped.
2. Make sure that the build, the full test suite and `swift format lint -s -p -r ./` pass on
   `develop`.
3. Record a code health snapshot. See [Code health snapshot](#code-health-snapshot).
4. Set `MARKETING_VERSION` in `Mochi Diffusion.xcodeproj` to the new version. The app target
   has one value for Debug and one for Release. Change both values in one
   `build: bump app version to <version>` commit.
5. Add a section for the new version at the top of `CHANGELOG.md`.

You do not set the build number. `scripts/set_build_version.sh` runs during the build and sets
`CFBundleVersion` to the commit count of `HEAD`.

## Tools and one-time setup

The release needs these tools:

- Xcode, signed in with the Developer ID team.
- `create-dmg` from npm (`npm install --global create-dmg`).
- `sign_update` and `generate_keys` from the `bin` folder of a Sparkle release.

Keep both signing secrets in the login keychain. Never put a secret in this repository, in
release notes or in a shell command.

1. Store the notarization credentials under the profile name that the notarize step uses:

   ```sh
   xcrun notarytool store-credentials "notarytool-password"
   ```

2. Import the Sparkle private key. The key signs every update, and installed copies accept
   only updates that it signed. Put the key in a file, import it, then delete the file:

   ```sh
   generate_keys -f <private-key-file>
   ```

3. Make sure that the keychain holds the right key. This command prints the public key, which
   must be equal to `SUPublicEDKey` in `MochiDiffusionInfo.plist`:

   ```sh
   generate_keys -p
   ```

Keep a backup of the Sparkle private key in a password manager. If you lose the key, you
cannot ship updates to installed copies. To make a backup file, use `generate_keys -x <file>`.

## Release

1. Bring `main` up to date with `develop`.
2. Build and notarize the app from `main`:
   1. In Xcode, select Product > Archive.
   2. In the Organizer, select Distribute App > Direct Distribution. Xcode signs the app and
      sends it for notarization.
   3. When notarization is complete, export `Mochi Diffusion.app`.
3. Make the DMG in the folder that holds the exported app. `create-dmg` names it
   `MochiDiffusion_<version>.dmg`.

   ```sh
   create-dmg "./Mochi Diffusion.app"
   ```

4. Notarize the DMG, then staple the ticket to it:

   ```sh
   xcrun notarytool submit "./MochiDiffusion_<version>.dmg" \
       --keychain-profile "notarytool-password" --wait
   xcrun stapler staple "./MochiDiffusion_<version>.dmg"
   ```

5. Tag the release commit `v<version>`. On GitHub, draft a new release for the tag, attach the
   DMG and publish the release.
6. Sign the DMG for Sparkle. `sign_update` reads the private key from the keychain, and prints
   the `sparkle:edSignature` and `length` attributes:

   ```sh
   sign_update "./MochiDiffusion_<version>.dmg"
   ```

7. Add an item for the new version at the top of `.sparkle/appcast.xml` on `main`. Copy the
   format of the previous item. Sparkle reads the feed from `main`, so the update reaches
   users when this commit lands. The item needs these values:
   - `sparkle:version`: the `CFBundleVersion` of the exported app. Read it with
     `/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "Mochi Diffusion.app/Contents/Info.plist"`.
   - `sparkle:shortVersionString`: the new version.
   - The DMG URL from the GitHub release.
   - `sparkle:edSignature` and `length` from step 6.
   - `pubDate`: the time that GitHub published the release, in the same form as the other
     items. `gh release view v<version> --json publishedAt` prints it.
   - A short description of the changes.

## Code health snapshot

The snapshot records the state of the code at each release, so that you can compare
releases. It does not block a release. A finding in the snapshot does not require a fix
before the release. If a finding needs work, create a bead for it.

The script needs Xcode, `periphery` and `swiftlint` from Homebrew, and `uv`. Do not install
the Homebrew formula named `lizard`, because it is an unrelated compression tool. The script
runs the Lizard complexity analyzer from PyPI through `uvx`.

1. Run the script from the repository root:

   ```sh
   scripts/code_health.sh
   ```

   The script runs the tests two times, once with code coverage and once under Thread
   Sanitizer. It writes its output to a folder in `$TMPDIR` and prints a summary at the end.

2. Append the summary to the notes of the release epic:

   ```sh
   bd update <release-epic> --append-notes "$(cat <output-folder>/summary.txt)"
   ```

3. Compare the summary with the one from the previous release. If a number changed by a large
   amount, read the detailed output in the output folder.

The summary contains these values:

- Test totals and the line coverage of the app target. The test bundle runs inside the app,
  so view coverage comes mostly from the app launch.
- Unused declarations from Periphery, and declarations that only the tests use. The count
  includes the preserved OpenAI and engine-picker code.
- Unused imports and force unwraps from SwiftLint.
- The number of functions, their average cyclomatic complexity and the functions above 15.
  Cyclomatic complexity is the number of independent paths through a function.
- Data race reports from the Thread Sanitizer test run.
