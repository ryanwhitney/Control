# Live integration tests (`.tags(.live)`)

These tests in `ControlTests/Live/` run the app's real generated AppleScript
against real apps on a real Mac over the production SSH transport. They are the
only coverage that catches AppleScript property/format drift across app and OS
versions. They are **off by default** and never run in a normal suite or CI —
they only activate when `VC_LIVE=1`.

Two layers, one suite:

- **`LiveIntegrationTests.swift`** — transport-level: raw scripts over the real
  `SSHClient`/`LegacySSHClient` → ChannelExecutor → PTY → parser path (volume
  round-trip on both transports, every platform's status script, play/pause on
  Music/Spotify/QuickTime/VLC, next-track on Music).
- **`LiveAppControllerTests.swift`** — the real `AppController` wired to the
  same live connection: initial refresh populates published state, the volume
  coalescer's trailing send lands on the Mac, an action updates the state the
  UI renders. Full production stack minus SwiftUI.

## One-time setup on the target Mac

1. **Enable Remote Login**
   System Settings › General › Sharing › Remote Login → On.
   (The tests default to `127.0.0.1`; loopback is exempt from the iOS
   simulator's local-network privacy prompt.)

2. **Grant Automation permission to `sshd`**
   The scripts drive apps via Apple Events, which require Automation permission
   attributed to the SSH session (not the app). The first live run against each
   target app will fail with `Not authorized to send Apple events` and add an
   entry under System Settings › Privacy & Security › Automation — approve it
   there, once per app. (This is the same string the app's UI already handles.)

3. **Provide credentials via environment variables** (never commit these). The
   variables are:
   ```
   VC_LIVE=1                              # enables the suite
   VC_LIVE_USER=<a login account on the Mac>
   VC_LIVE_PASS=<its password>
   VC_LIVE_HOST=127.0.0.1                 # optional, this is the default
   VC_LIVE_STRICT=1                       # optional, see "Skips" below
   ```
   There are two ways to actually deliver them to the tests — see below. (A
   plain `VC_LIVE=1 xcodebuild …` does **not** work: the launching shell's
   environment isn't forwarded into the simulator test runner.)

## Before each run: `Scripts/live-setup.sh`

The action tests need apps running with media loaded. Instead of arranging that
by hand, run:

```bash
./Scripts/live-setup.sh
```

It generates two ~60 s audio fixtures (via `say`), builds a **"VC Test"**
playlist in Music (started then paused — a stable multi-track starting point
for play/pause and next-track), opens one clip paused in QuickTime, and — when
installed — a clip in VLC (paused) and IINA. Spotify can only be launched:
loading a track needs an account, so play something once by hand if you want
its action test to run. The script is idempotent; its header comment documents
how to undo everything.

Each test restores the state it changed (volume, play/pause, track position),
so runs are non-destructive.

> Note: IINA and mpv are UI-scripted and will briefly come to the foreground
> during their status read — expected under the live suite.

## Skips: graceful by default, strict on demand

A platform whose app isn't running — or has nothing loaded — is *skipped*, and
every skip is printed to the test log (`⏭️ live skip — …`) so a green run still
shows what wasn't exercised. On a Mac that is supposed to be fully provisioned
(after `live-setup.sh`, or later against a baked VM image), set
`VC_LIVE_STRICT=1` (via `TEST_RUNNER_` prefix or the scheme, like the other
variables) to turn every skip into a failure, so a missing fixture can't
silently zero out coverage. A transport failure is always a failure, never a
skip.

## Delivering the variables

### Option A — command line, prefixed with `TEST_RUNNER_` (recommended for secrets)
xcodebuild forwards only variables prefixed with `TEST_RUNNER_` into the
simulator test runner. `LiveEnvironment` reads both the prefixed and unprefixed
names, so prefix them on the command and keep the password out of any file:

```bash
TEST_RUNNER_VC_LIVE=1 \
TEST_RUNNER_VC_LIVE_USER=you \
TEST_RUNNER_VC_LIVE_PASS='secret' \
xcodebuild test -scheme Control \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:ControlTests/LiveIntegrationTests
```

Pull the password from Keychain instead of typing it, e.g.:
```bash
TEST_RUNNER_VC_LIVE_PASS="$(security find-generic-password -s vc-live -w)"
```
(store it once with `security add-generic-password -s vc-live -a "$USER" -w`).

### Option B — Xcode scheme (convenient for running from the Test navigator)
Product → Scheme → Edit Scheme… → **Test** → **Arguments** →
**Environment Variables**, add `VC_LIVE=1`, `VC_LIVE_USER`, `VC_LIVE_PASS`
(unprefixed here). Then run tests with ⌘U or from the diamond next to
`LiveIntegrationTests`.
⚠️ These are stored in plaintext in the scheme file under `xcuserdata/`. That
path is normally git-ignored, but confirm before committing so the password
never lands in the repo.

## Running

```bash
# Default suite only (hermetic, no Mac needed) — live suite stays inert:
xcodebuild test -scheme Control \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

Filter by tag with `--tag live` / `--skip-tag live` where supported.
