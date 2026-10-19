# TBDisplay

Use an Apple silicon iMac as an extended display for a MacBook, over a direct Thunderbolt cable.

## Why I made this

I have an M1 24-inch iMac and a MacBook Pro. Older iMacs could act as a monitor for another Mac through Target Display Mode, but Apple dropped it for iMacs with Apple silicon, so the iMac screen sat unused beside my MacBook.

AirPlay to Mac was the built-in way round it. It worked, but the picture was poor, and it got worse over several hours of use. That was the minor, constant annoyance this project fixes for me.

So I wrote two small macOS apps. The server runs on the MacBook, creates a virtual display and streams it as hardware HEVC. The client runs on the iMac and shows the stream full screen. It solves one small problem for one pair of machines. I am sharing it in case it helps someone with the same problem.

## What it does

- Streams at the iMac's full native resolution (4480 x 2520 on the 24-inch iMac), shown as a 2240 x 1260 Retina desktop.
- Keeps the picture steady over long sessions: at most two frames are in flight, and a newer frame replaces a waiting one, so delay does not build up.
- Encrypts the link (TLS 1.2, ECDHE-PSK with ChaCha20-Poly1305) with a pairing key shared by the two Macs.
- Pairs without copying files: the MacBook and the iMac each show a six-digit code, and you confirm they match.
- Accepts connections only over the Thunderbolt Bridge (`bridge0`) unless you ask for another interface.
- Optionally forwards the iMac's keyboard and mouse to the MacBook (switched on from the server's menu bar item).
- Leaves sound alone. Audio stays on the MacBook.

## Measured results (one pair of machines)

On an M5 MacBook Pro and an M1 24-inch iMac, glass-to-glass latency was about 68 ms. I measured it by filming a millisecond clock on both screens at 240 fps (65 to 70 ms across four readings, each reading about plus or minus 8 ms). A 30-minute run stayed connected with no growth in delay. I have not tested other Mac models, other macOS versions or other cables, so treat these numbers as one data point.

To repeat the measurement, open `Tests/latency_clock.html` in two browser windows, put one on each screen, and film both.

## Requirements

- Both Macs: Apple silicon, macOS 14 or later.
- A Thunderbolt or USB4 cable between them (a charging cable is not enough).
- Xcode command line tools, to build from source.

## Build and run

```
./build.sh              builds both apps into ./build
./build.sh test         runs the unit checks
Tests/all.sh            runs the quiet test groups (nothing opens a window)
Tests/test_lists.sh     checks every unit test file is wired into all three test runners
Tests/all.sh full       runs everything, including the groups that drive real windows
```

Copy `build/TBDisplay Client.app` to the iMac and open it. Open `build/TBDisplay Server.app` on the MacBook. macOS asks for Screen Recording permission on the MacBook, and Local Network permission on both. Choose "Pair a new Mac..." in the MacBook's menu bar item, then "Pair with MacBook..." on the iMac, and check that both screens show the same code.

`Package.swift` exposes the shared code and the unit tests, so you can open the folder in Xcode. The two apps themselves are built by `build.sh`. `Resources/make-icon.sh` regenerates the app icon.

## Where things are kept

- Pairing key: `~/Library/Application Support/tbdisplay/pairing-key`, owner-only. A key replaced by pairing is kept beside it as `pairing-key.previous`.
- Saved position of the virtual display: `~/Library/Application Support/tbdisplay/layout.json`.
- Logs: `~/Library/Logs/TBDisplay/server.log` and `client.log`, owner-only, up to 1 MB each with one older copy. "Show log" in the server menu and in the client window opens the folder.
- Preferences (first-run flag, whether an iMac has ever connected): the apps' own defaults, under `local.tbdisplay.server` and `local.tbdisplay.client`.
- "Open at login" is a checkbox in each app. It only works for an installed app (in Applications), and macOS may ask you to allow it in System Settings.

## Updates

TBDisplay checks GitHub for a newer release. Choose "Check for updates..." in the MacBook's menu bar item, or press the same button in the iMac client window. It also checks quietly at launch, at most once a day, and shows an "Update available" line when there is one. Untick "Check for updates automatically" to stop the daily check.

- The check is one request to GitHub's public API (`api.github.com`). It sends the app name and version and nothing else.
- It never downloads or installs anything. It opens the release page in your browser, and you install the notarised disk image yourself. It ignores any link that is not this project's own release page.
- For maintainers: the check compares the running version (`appVersion` in `Sources/Shared/Shared.swift`) with the tag of the latest published release. Tag each release `v<appVersion>`, for example `v1.8.0`, and publish it as a normal release, not a draft or pre-release.

## Environment variables

None are needed to use the apps. They exist so the tests do not touch your real settings, and they are trusted input.

| Variable | Meaning |
|---|---|
| `TBDISPLAY_KEY_FILE` | Path of the pairing key file |
| `TBDISPLAY_LAYOUT_FILE` | Path of the saved display position file |
| `TBDISPLAY_LOG_DIR` | Folder for the log files |
| `TBDISPLAY_PREFS_SUITE` | Name of the preferences suite to use |
| `TBDISPLAY_PAIR_PORT` | Pairing port (default 47802) |
| `TBDISPLAY_LOCKOUT_SECONDS` | How long a client is blocked after repeated failed attempts (default 60) |

## Limits you should know about

- It uses Apple's private `CGVirtualDisplay` interface, which is undocumented. A macOS update could break it without notice, and apps using it cannot be distributed through the Mac App Store.
- While the "Pair a new Mac" window is open (at most 120 seconds), the MacBook accepts pairing connections on every network, including Wi-Fi, so pairing works wherever the two Macs can see each other. Someone else on the same network could take the single pairing slot first. They would get the key only if you clicked "Yes, it matches" when the iMac was not showing the same code, so only click Yes when both screens show the same six digits. The streaming port accepts only the Thunderbolt Bridge by default, so a copied key alone does not give a Wi-Fi visitor your screen. If you ever suspect a key was taken, choose "Create new pairing key..." in the server menu.
- The pairing protocol and the encrypted link have had internal security reviews but no external professional audit. Do not rely on it to protect anything sensitive.
- After a Thunderbolt cable was unplugged and plugged back in, the link did not return on my test pair until the iMac was restarted. The apps show advice about this, but it is a macOS or hardware behaviour, not something the apps fix.
- No audio, one iMac per MacBook, and no support for Intel Macs or macOS versions before 14.

## Releasing your own build

`Scripts/release.sh` builds, signs with a Developer ID Application certificate, makes a disk image, notarises it with Apple and staples the result. It needs your own certificate and a saved `notarytool` profile named `notary` (or set `NOTARY_PROFILE`).

## Licence

MIT. See `LICENSE`.
