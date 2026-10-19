# Quiet Timer

A silent countdown timer for macOS. It floats in a corner of your screen so you always see how much time is left, and when time is up it shows a popup instead of ringing an alarm. Built for open offices and shared desks, where a beeping timer would annoy everyone around you.

English and Simplified Chinese versions are both included. 中文说明见 [README.zh-CN.md](README.zh-CN.md)。

## Features

- **Always-visible countdown.** A small translucent pill that stays on top of every window, including full-screen apps. Drag it to any corner; it remembers where you put it.
- **Urgency without noise.** The pill goes from green to orange to red as time runs out, with a progress bar along its bottom edge. Three sizes and adjustable opacity.
- **Silent time-up popup.** A large popup appears in the middle of the screen. No sound at all. It stays until you deal with it and keeps counting the overtime.
- **Hide it when you need to.** Press **Control + Option + T** in any app to hide or show the pill (the countdown keeps running), or choose "Hide for a while, then show again" (5 to 60 minutes) from the menu.
- **Fast set-up.** One-click presets (10 minutes to 2 hours), or type your own: `25`, `45m`, `1.5h`, `1h30m`, `90s`, `25:00`.
- **Daily goal tracking.** When a countdown ends, tick *Goal completed* or *Goal not completed*. The menu always shows today's score, and **Call it a day** shows your completion rate and resets the counters for a fresh day.
- **Light and private.** Uses about 25 MB of memory, makes no network connections, has no analytics or accounts, and needs no special permissions. Settings are stored locally. The whole app is one Swift file with no dependencies.

## Install

Quiet Timer is distributed as source code and compiled on your own Mac. There is no prebuilt binary: distributing one would require an Apple Developer certificate and notarization, and without them macOS blocks downloaded apps.

**Requirements:** macOS 11 or later, and the Xcode Command Line Tools. If the tools are missing, the installer triggers the system dialog that offers to install them. The "Launch at login" option needs macOS 13 or later.

1. Download this repository (**Code > Download ZIP**, then unzip it) or `git clone` it.
2. Open Terminal, `cd` into the folder, and run one of:

   ```bash
   bash install.sh en     # English version
   bash install.sh zh     # Chinese version (简体中文)
   ```

3. The script compiles the app (20 to 60 seconds), installs it into `~/Applications`, and launches it.

Installing one language replaces the other if it is already installed. To rebuild after pulling updates, just run the same command again; your settings are kept.

To compile by hand instead: `swiftc -O -swift-version 5 -o QuietTimer src/en/main.swift`.

## Using it

**Start a countdown.** Click the pill (it says "Click to set" at first) and pick a duration, or choose "Custom...". The same menu is available from the small timer icon in the menu bar, which also lets you bring the pill back if you hid it.

**Duration formats** for "Custom...":

| You type | Meaning |
| --- | --- |
| `25` | 25 minutes (minutes are the default unit) |
| `45m`, `1.5h`, `90s` | 45 minutes, 1.5 hours, 90 seconds |
| `1h30m` | 1 hour 30 minutes |
| `25:00` | 25 minutes 0 seconds (min:sec) |
| `1:30:00` | 1 hour 30 minutes (h:min:sec) |

**While counting down.** Pause, resume, add 5 minutes, restart with the last duration, or stop from the menu. The pill's color and progress bar show how much time is left.

**When time is up.** A popup appears with the overtime counting up. Tick one of the two boxes, *Goal completed* or *Goal not completed*, and then choose:

- **Dismiss** closes the popup.
- **Restart** starts the same duration again.
- **5 more minutes** extends the same goal. It works without ticking a box and does not count as a new countdown.

**Daily stats.** Every countdown that ends counts toward today's total, and ticking *Goal completed* counts toward today's completed number. The menu shows a line such as "Today: 3 / 5 goals completed (60%)". Choose **Call it a day** to see the summary (completed, not completed, rate, and when the stats started) and confirm to reset everything and start a new day. Countdowns you stop manually before they end are not counted. The counters do not reset by themselves at midnight; they reset only when you call it a day.

**Hide and show.** Press **Control + Option + T** anywhere, or use the menu. If another app already uses that shortcut, the hotkey silently does nothing and the menu still works.

## Uninstall

If you turned on "Launch at login" in the app's menu, turn it off first. Then run:

```bash
bash uninstall.sh
```

This quits the app, deletes it from `~/Applications`, and removes its saved settings.

## Troubleshooting

- **The installer says the command line tools are missing.** Click Install in the dialog that appears, wait for it to finish, then run the installer again. You can also run `xcode-select --install` yourself.
- **Compile errors.** Please open an issue and include the full output together with the result of `sw_vers` and `swiftc --version`.
- **I can't see the pill.** Press Control + Option + T in case it is hidden, then use the menu bar icon and choose "Move pill back to top-right".
- **The app is not in /Applications.** It is installed for your user only, in `~/Applications` (in Finder: Go > Home > Applications). You can also find it with Spotlight, or move it to `/Applications` yourself.
- **"Launch at login" fails.** Add the app manually under System Settings > General > Login Items.

## Notes and limitations

- Quitting the app discards a countdown that is currently running. Settings and daily stats are kept.
- The pill lives on every desktop and above full-screen apps, but it is a normal window: it will appear in screen recordings and screen shares. Hide it with Control + Option + T before sharing your screen.
- `src/en/main.swift` and `src/zh/main.swift` contain the same code and differ only in the interface text. If you change one, change the other.

## Built with Claude

Quiet Timer was designed and written together with [Claude](https://claude.ai), Anthropic's AI assistant.

## Contributing

Issues and pull requests are welcome.

## License

[MIT](LICENSE)
