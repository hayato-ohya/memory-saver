**English** | [日本語](README.ja.md)

# MemorySaver

A macOS menu bar app for Macs that stay up for days. It watches memory, finds the apps that have grown the most since they launched, and relaunches them when you click.

Memory that macOS can reclaim on its own, such as file cache, is left alone. What actually comes back is memory held by apps that have bloated over time, and the usual way to recover it is to relaunch them. MemorySaver tells you which ones are worth it.

## Features

- **Memory overview.** Shows used memory, memory pressure, swap, and WindowServer's memory.
- **Per-app memory.** Each app's helper processes are counted toward the app, the same way Activity Monitor groups them. For example, every Brave renderer counts toward Brave. Click a row to see its processes.
- **Relaunch suggestions.** Suggests relaunching an app when it uses at least 2 GB and has grown to at least 1.5 times its size shortly after launch. Both thresholds can be changed in Settings.
- **WindowServer.** Shows how much WindowServer has grown since login, and which apps' windows are the likely cause.
- **Relaunch on a click only.**
  - It quits the app normally, so the app can ask to save unsaved work, then opens it again.
  - It never force quits, and never acts on its own.
  - System processes such as Finder, the Dock and loginwindow are shown but cannot be relaunched.
- **Notifications.** Notifies you when memory pressure is high and there is something to relaunch.
- **Languages.** Japanese and English, following your macOS language setting.

## Requirements

- macOS 14 or later
- Xcode with Swift 6, or a Swift 6 toolchain (to build)

## Download

Download the zip file from the [latest release](https://github.com/hayato-ohya/memory-saver/releases/latest), unzip it, and move `MemorySaver.app` to the Applications folder. The build is for Apple silicon Macs.

The app is not notarized by Apple, so macOS blocks it the first time you open it. To allow it:

1. Open `MemorySaver.app`. When macOS says it cannot verify the app, click **Done**.
2. In **System Settings > Privacy & Security**, find the message about MemorySaver and click **Open Anyway**, then confirm.

You can also build it yourself, as described below.

## Build and run

```sh
./scripts/make-signing-cert.sh   # once; macOS asks for your password
./scripts/bundle.sh install
```

`bundle.sh` builds a release binary and wraps it into `dist/MemorySaver.app`. With `install`, it also quits the running copy, replaces `/Applications/MemorySaver.app`, and opens it. The app appears in the menu bar with no Dock icon.

`make-signing-cert.sh` creates a self-signed certificate, "MemorySaver Dev", in your login keychain. `bundle.sh` signs with it when it exists, which keeps **Open at login** working across rebuilds. Without it, the app is signed ad hoc, and Open at login stops working each time you rebuild.

Run the tests with:

```sh
swift test
```

## How it works

- **Sampling.** Every minute it reads system memory and each process's memory footprint (the figure Activity Monitor shows as "Memory").
  - WindowServer runs as another user, so its memory is read through `/usr/bin/top`. This is the most expensive step, so it runs every 5 minutes.
- **Baselines.** History is stored for 7 days. An app's baseline is its typical size 5 to 20 minutes after launch; WindowServer's is its size shortly after login.
  - For apps already running when MemorySaver started, the size when first seen is used until the app is relaunched.
- **WindowServer suspects.** These are an estimate from window sizes. macOS has no public way to break WindowServer's memory down by app.

## Privacy

- MemorySaver makes no network connections.
- Everything it records stays on your Mac, in `~/Library/Application Support/MemorySaver/history.sqlite`: memory sizes per app and when they were measured.
- It reads process names and memory figures. It does not read window titles or contents, and needs no Screen Recording permission.

## Limitations

- **WindowServer.** Its memory cannot be released directly. Relaunching the suspected apps may help; logging out always brings it back to its starting size.
- **Reading WindowServer through `top`.** This depends on `top`'s output format, so a future macOS may break that one figure. The rest of the app keeps working.
- **Open at login.** macOS ties it to the app's location and signature. Keep the app in the Applications folder. If you build it yourself, sign it with the certificate from `make-signing-cert.sh`. Settings warns you when the app is outside Applications or when the login item is switched off in System Settings.

## Adding a language

UI text lives in `Sources/MemorySaverCore/Resources/<language>.lproj/`. Copy `en.lproj` to a folder named after the language code, for example `fr.lproj`, and translate the values in both files. No code changes are needed.

`swift test` checks that every language has every string and the same placeholders.

## License

[MIT](LICENSE)
