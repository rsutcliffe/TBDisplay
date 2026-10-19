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
Tests/all.sh full       runs everything, including the groups that drive real windows
```

Copy `build/TBDisplay Client.app` to the iMac and open it. Open `build/TBDisplay Server.app` on the MacBook. macOS asks for Screen Recording permission on the MacBook, and Local Network permission on both. Choose "Pair a new Mac..." in the MacBook's menu bar item, then "Pair with MacBook..." on the iMac, and check that both screens show the same code.

`Package.swift` exposes the shared code and the unit tests, so you can open the folder in Xcode. The two apps themselves are built by `build.sh`. `Resources/make-icon.sh` regenerates the app icon.

## Limits you should know about

- It uses Apple's private `CGVirtualDisplay` interface, which is undocumented. A macOS update could break it without notice, and apps using it cannot be distributed through the Mac App Store.
- The pairing protocol and the encrypted link have had internal security reviews but no external professional audit. Do not rely on it to protect anything sensitive.
- After a Thunderbolt cable was unplugged and plugged back in, the link did not return on my test pair until the iMac was restarted. The apps show advice about this, but it is a macOS or hardware behaviour, not something the apps fix.
- No audio, one iMac per MacBook, and no support for Intel Macs or macOS versions before 14.

## Releasing your own build

`Scripts/release.sh` builds, signs with a Developer ID Application certificate, makes a disk image, notarises it with Apple and staples the result. It needs your own certificate and a saved `notarytool` profile named `notary` (or set `NOTARY_PROFILE`).

## Licence

MIT. See `LICENSE`.
