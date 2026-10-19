# Tech debt backlog

Items found by the audit of 19 October 2026 and not fixed yet.

## TD-005: No automated build on each push

- **Category:** Build and Deployment
- **File:** (none, there is no `.github/workflows`)
- **Line(s):** n/a
- **Impact:** MEDIUM
- **Effort:** MODERATE
- **Risk:** LOW
- **Added:** 2026-10-19
- **Status:** OPEN

Nothing builds the apps or runs the quiet tests when code is pushed. A workflow on a macOS runner could run `./build.sh` (it falls back to ad hoc signing when no certificate is found) and `Tests/all.sh`. Cap the job time, cancel superseded runs, and ignore documentation-only changes. The window and loopback groups need a screen and should stay local.

## TD-006: Large files with mixed responsibilities

- **Category:** Architecture and Structure
- **File:** `Sources/Client/main.swift`, `Sources/Shared/Shared.swift`
- **Line(s):** whole files (about 640 and 510 lines)
- **Impact:** MEDIUM
- **Effort:** COMPLEX
- **Risk:** MEDIUM
- **Added:** 2026-10-19
- **Status:** OPEN

`Client/main.swift` holds option parsing, the video view, the client class and start-up. `Shared.swift` holds framing, key storage, TLS parameters, preferences, logging and argument parsing. Splitting them by job would make each part easier to test. Move code without changing behaviour, one file at a time, with the loopback and window groups run after each move.

## TD-007: Network, window and encoder code is covered only by scripted window tests

- **Category:** Testing
- **File:** `Sources/Server/StreamSession.swift`, `Sources/Client/main.swift`, `Sources/Server/Encoder.swift`
- **Line(s):** n/a
- **Impact:** MEDIUM
- **Effort:** COMPLEX
- **Risk:** LOW
- **Added:** 2026-10-19
- **Status:** OPEN

The decision logic lives in `Sources/Core` and has unit tests. The code that talks to sockets, windows and the hardware encoder is checked only by `Tests/loopback.sh` and the window scripts, which need a screen and take over the keyboard and mouse. Moving more decisions into `Sources/Core` would widen the quiet test coverage.

## TD-008: Three functions longer than 50 lines

- **Category:** Code Quality
- **File:** `Sources/Server/main.swift` (`start`, 64 lines), `Sources/Client/main.swift` (`decodeFrame`, 56 lines), `Sources/Server/StreamSession.swift` (`handle`, 52 lines)
- **Line(s):** see names
- **Impact:** LOW
- **Effort:** MODERATE
- **Risk:** MEDIUM
- **Added:** 2026-10-19
- **Status:** OPEN

Each does several steps in order. They are readable today, and the network paths are covered only by the window-driving tests (TD-007), so splitting them carries regression risk. Do it together with TD-007.

## TD-009: Pairing port listens on every network interface

- **Category:** Security (accepted risk, recorded for the record)
- **File:** `Sources/Core/PairingNetwork.swift`
- **Line(s):** 51
- **Impact:** LOW
- **Effort:** QUICK
- **Risk:** MEDIUM
- **Added:** 2026-10-19
- **Status:** ACCEPTED

The pairing window (at most 120 seconds) accepts connections on all interfaces so pairing works over Wi-Fi as well as the cable. Someone on the same network could take the single pairing slot, and would get the key only if the person clicked Yes while the other screen showed no matching code. The streaming port stays cable-only by default, so a copied key alone does not expose the screen. The owner chose to keep pairing easy and documented the risk in the README. Revisit if pairing is ever offered on shared networks: restrict the listener to the Thunderbolt Bridge unless `--any-interface` is given.
