# Install Evanto on a Mac

[Overview](../README.md) · [Using Evanto](user-guide.md) · [Release downloads](https://github.com/sambhuiyan/evanto/releases)

## Before you start

You need an Apple silicon Mac (M-series), macOS 26 or later, and a ChatGPT account with Codex access for AI replies. Choose **Apple menu → About This Mac** to check your chip and macOS version. The packaged app includes the native Codex runtime and the Bangla speech model. Allow about 1 GB for the installed app, plus space for the download.

## Install a release

1. Open **GitHub releases** above. Choose a version with an **arm64.dmg** asset. Read its signing and notarization status in the release notes. GitHub’s source archives are for building the app yourself.
2. Download the DMG and its matching **.sha256** file. To verify version 1.5.0, open Terminal and run the commands below from the folder containing both files. Look for **OK**.
3. Open the DMG in Finder. Drag **Evanto** onto **Applications**, eject the disk image, and open **Applications → Evanto**.
4. In **Settings**, choose **Sign in with ChatGPT** and complete the browser sign-in. If the bundled Codex runtime already recognizes your account, your model choices appear immediately.

```sh
cd ~/Downloads
shasum -a 256 -c Evanto-1.5.0-arm64.dmg.sha256
```

Apple’s Gatekeeper assesses downloaded apps on first launch. A development-signed prerelease can trigger a verification warning on another Mac. Follow the signing status for the exact asset you downloaded. The source-build procedure below provides a local installation path. [Apple’s guide to opening downloaded apps](https://support.apple.com/en-us/102445)

## Set up Live

| In Evanto | What macOS asks for | When you need it |
| --- | --- | --- |
| **Start live** | Screen & System Audio Recording | Capture the selected screen or window and audio playing on the Mac. |
| **Microphone** | Microphone | Transcribe nearby speech. The microphone and Mac audio have independent mute controls. |
| **Mac task → Control** | Accessibility | Send cursor and keyboard input to the selected application during a typed task. |

1. In **Settings → Capture**, choose the screen or window and the spoken language. For Bangla, choose **বাংলা (বাংলাদেশ)**. Other languages may need a first-use speech asset download.
2. Click **Start live**, then turn on the input you want. Play a few seconds of speech or speak into the microphone. Look for the source label and text in the floating panel.
3. Press **⌥ ⇧ Space** to toggle the panel. **Show answer panel** in the workspace brings it to the current display. For a meeting, select **Entire Screen → Shared Screen** in the meeting app. [Sharing guide](user-guide.md#share-or-record)

## Build from source

Install Xcode with the macOS 26 SDK or newer and open it once to finish setup. The packaging script uses a native OpenAI-signed Codex executable. On a Mac with npm, the version used to test this release can be installed with the following commands.

```sh
npm install --global @openai/codex@0.169.0
git clone https://github.com/sambhuiyan/evanto.git
cd evanto
git switch --detach v1.5.0
./Scripts/build-app.sh
open Evanto.app
```

If the script cannot locate the **native** Codex executable, set `EVANTO_CODEX_BINARY` to that executable’s absolute path and rerun the build. The npm launcher is a script. The build checks the native binary’s OpenAI signature and downloads the pinned speech framework and model. To choose a Mac signing identity, set `EVANTO_SIGN_IDENTITY` to its full Keychain name. For a local ad-hoc build, use `EVANTO_SIGN_IDENTITY=- ./Scripts/build-app.sh`.

**Run the tests** with `swift test`. Optional tests use installed speech assets (`EVANTO_TEST_SPEECH=1`), a signed-in Codex account (`EVANTO_TEST_CODEX=1`), or an authorized screen-capture test runner (`EVANTO_TEST_CAPTURE=1`). Codex integration tests make model requests.

**Build a DMG** with `./Scripts/build-dmg.sh` after setting `EVANTO_SIGN_IDENTITY`. The script writes the signed image and its checksum to `dist/`. For public Developer ID builds, use the full **Developer ID Application** identity name and set `EVANTO_NOTARY_PROFILE` to an existing notarytool Keychain profile to submit and staple the disk image before the checksum is calculated. [Apple’s distribution guide](https://developer.apple.com/developer-id/)

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| Start Live keeps requesting permission | Open **System Settings → Privacy & Security → Screen & System Audio Recording**. If the entry points to an older copy, replace it with the installed app and follow macOS’s relaunch prompt. |
| The panel is invisible on the built-in screen | In **Settings → Screen sharing → Answer panel**, select **Native panel with Clean Share**, then **Show answer panel**. |
| Bangla speech has English-looking captions | In **Settings → Capture → Spoken language**, select **বাংলা (বাংলাদেশ)**. Check whether the speaker is coming through the input labeled **Mac audio** or **Microphone**. |
| The meeting shows the answer panel | In the meeting picker, share **Shared Screen** (sometimes **Screen 2**). If the added display is unavailable, choose the **Shared Screen** window. |
| The first model response asks for sign-in | Open **Evanto → Settings** and complete **Sign in with ChatGPT** using the account you intend to use for replies. |
