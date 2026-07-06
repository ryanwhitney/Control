#!/bin/bash
#
# Puts this Mac into the known state the live test suite expects, so the action
# tests exercise real apps instead of skipping. Idempotent — safe to re-run.
#
#   ./Scripts/live-setup.sh
#
# What it does:
#   • Generates two ~60 s audio fixtures (via `say`) under
#     ~/Library/Application Support/ControlLiveFixtures/
#   • Music: creates a "VC Test" playlist with both fixtures, starts it, pauses
#     (gives play/pause and next-track a stable multi-track starting point)
#   • QuickTime Player: opens fixture 1, paused
#   • VLC (if installed): opens fixture 2, paused
#   • IINA (if installed): opens fixture 1 (status-read coverage only)
#   • Spotify (if installed): just launches it — loading a track needs an
#     account, so play a track once by hand for its action test to run
#
# First run may show macOS Automation prompts (this terminal → Music/QuickTime/
# VLC/System Events) — approve them. Note the *tests* need separate Automation
# grants attributed to sshd; see ControlTests/Live/Fixtures.md.
#
# To undo: delete the "VC Test" playlist in Music (and the two "Control test
# clip" tracks it added to the library), close the players, and remove
# ~/Library/Application Support/ControlLiveFixtures/.

set -euo pipefail

FIXTURES_DIR="$HOME/Library/Application Support/ControlLiveFixtures"
CLIP1="$FIXTURES_DIR/control-test-clip-1.m4a"
CLIP2="$FIXTURES_DIR/control-test-clip-2.m4a"
PLAYLIST="VC Test"

ready=()
notes=()

make_clip() { # $1 = path, $2 = spoken label
  if [[ ! -f "$1" ]]; then
    echo "Generating $(basename "$1") (~60 s)…"
    # Spoken marks separated by embedded silences so a test never hits
    # end-of-media mid-run.
    say -o "$1" --file-format=m4af --data-format=aac \
      "$2 $(printf 'mark. [[slnc 4000]] %.0s' {1..12}) end of clip."
  fi
}

app_installed() { # $1 = app name
  [[ -d "/Applications/$1.app" || -d "$HOME/Applications/$1.app" ]]
}

mkdir -p "$FIXTURES_DIR"
make_clip "$CLIP1" "Control test clip one."
make_clip "$CLIP2" "Control test clip two."

# --- Music: "VC Test" playlist with both clips, playing then paused ----------
echo "Setting up Music…"
if osascript - "$CLIP1" "$CLIP2" "$PLAYLIST" <<'EOF'
on run {clip1, clip2, playlistName}
    tell application "Music"
        launch
        if not (exists playlist playlistName) then
            make new playlist with properties {name:playlistName}
        end if
        if (count of tracks of playlist playlistName) < 2 then
            add POSIX file clip1 to playlist playlistName
            add POSIX file clip2 to playlist playlistName
        end if
        play playlist playlistName
        delay 1
        pause
    end tell
end run
EOF
then
  ready+=("Music — \"$PLAYLIST\" playlist loaded and paused")
else
  notes+=("Music setup failed — approve the Automation prompt and re-run")
fi

# --- QuickTime Player: fixture 1, paused --------------------------------------
echo "Setting up QuickTime Player…"
if osascript - "$CLIP1" <<'EOF'
on run {clip1}
    tell application "QuickTime Player"
        open POSIX file clip1
        delay 1
        if exists document 1 then tell document 1 to pause
    end tell
end run
EOF
then
  ready+=("QuickTime Player — clip open and paused")
else
  notes+=("QuickTime setup failed — approve the Automation prompt and re-run")
fi

# --- VLC: fixture 2, paused ----------------------------------------------------
if app_installed "VLC"; then
  echo "Setting up VLC…"
  # VLC auto-plays on open; `play` toggles, so pause only if it is playing.
  if osascript - "$CLIP2" <<'EOF'
on run {clip2}
    tell application "VLC"
        open POSIX file clip2
        delay 1
        if playing then play
    end tell
end run
EOF
  then
    ready+=("VLC — clip open and paused")
  else
    notes+=("VLC setup failed — approve the Automation prompt and re-run")
  fi
else
  notes+=("VLC not installed — its tests will skip")
fi

# --- IINA: fixture 1 (status coverage; its tests are foreground-only) ----------
if app_installed "IINA"; then
  echo "Opening IINA…"
  open -a IINA "$CLIP1"
  ready+=("IINA — clip open (status coverage)")
else
  notes+=("IINA not installed — its status test will skip")
fi

# --- Spotify: launch only (loading a track requires an account) ----------------
if app_installed "Spotify"; then
  echo "Launching Spotify…"
  open -a Spotify
  notes+=("Spotify launched — play any track once by hand so its action test runs")
else
  notes+=("Spotify not installed — its tests will skip")
fi

echo
echo "Ready:"
for r in "${ready[@]}"; do echo "  ✓ $r"; done
if ((${#notes[@]})); then
  echo "Notes:"
  for n in "${notes[@]}"; do echo "  • $n"; done
fi
echo
echo "Run the live suite (see ControlTests/Live/Fixtures.md for credential setup):"
echo "  TEST_RUNNER_VC_LIVE=1 TEST_RUNNER_VC_LIVE_USER=\$USER \\"
echo "  TEST_RUNNER_VC_LIVE_PASS=\"\$(security find-generic-password -s vc-live -w)\" \\"
echo "  xcodebuild test -scheme Control -destination 'platform=iOS Simulator,name=iPhone 16' \\"
echo "    -only-testing:ControlTests/LiveIntegrationTests"
echo
echo "Add TEST_RUNNER_VC_LIVE_STRICT=1 to turn any remaining skips into failures."
