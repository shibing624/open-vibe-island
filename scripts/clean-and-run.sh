#!/bin/zsh
# clean-and-run.sh — one command for manual end-to-end verification.
#
#   zsh scripts/clean-and-run.sh              # clean, rebuild the dev bundle, launch, verify
#   zsh scripts/clean-and-run.sh --dry-run    # show what cleaning would remove, then stop
#   zsh scripts/clean-and-run.sh --no-clean   # rebuild and launch only
#   zsh scripts/clean-and-run.sh --skip-setup # do not reinstall agent hooks
#
# This composes the two existing scripts rather than reimplementing them:
#
#   scripts/clean-user-env.sh   removes hooks, app data, defaults, and the bundle
#   scripts/launch-dev-app.sh   rebuilds ~/Applications/Open Island Dev.app and opens it
#
# What it adds on top is the part that was missing: proving the app is actually
# running. `open` returns 0 as soon as LaunchServices accepts the bundle, so a
# rejected signature, a missing Info.plist key, or a crash on launch all look
# like success. When the process is not alive this script surfaces the crash
# report and re-runs the binary in the foreground, which is the fastest way to
# see the real reason.
#
# It also reports which sound theme will be used: cleaning removes
# ~/Library/Application Support/OpenIsland, and sound packs live in there, so a
# cleaned environment falls back to macOS system sounds until the packs are
# fetched again. The symptom of missing packs is "one plain alert sound", which
# is easy to misread as the theme feature being broken.
#
# This script is for manual verification. Automated checks belong in
# scripts/harness.sh; the smoke path there deliberately targets the repository
# binary rather than the installed dev bundle.

# Re-exec under zsh. Running this as `sh scripts/clean-and-run.sh` ignores the
# shebang, and the script relies on zsh glob qualifiers and modifiers, so under
# sh it would fail on syntax rather than on anything meaningful.
if [ -z "${ZSH_VERSION:-}" ]; then
    exec /bin/zsh "$0" "$@"
fi

set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "clean-and-run runs only on macOS." >&2
    exit 1
fi

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

bundle_dir="$HOME/Applications/Open Island Dev.app"
bundle_binary="$bundle_dir/Contents/MacOS/OpenIslandApp"
packs_dir="$HOME/Library/Application Support/OpenIsland/SoundPacks"
process_name="OpenIslandApp"

dry_run=false
clean=true
skip_setup=false

for arg in "$@"; do
    case "$arg" in
        --dry-run)    dry_run=true ;;
        --no-clean)   clean=false ;;
        --skip-setup) skip_setup=true ;;
        *)
            echo "unknown flag: $arg" >&2
            echo "usage: $0 [--dry-run] [--no-clean] [--skip-setup]" >&2
            exit 2
            ;;
    esac
done

say() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

if $dry_run; then
    say "Cleaning (dry run)"
    zsh "$repo_root/scripts/clean-user-env.sh" --dry-run
    say "Dry run complete — nothing was changed, nothing was built"
    exit 0
fi

if $clean; then
    say "Cleaning user environment"
    zsh "$repo_root/scripts/clean-user-env.sh"
fi

say "Building and launching the dev bundle"
if $skip_setup; then
    zsh "$repo_root/scripts/launch-dev-app.sh" --skip-setup
else
    zsh "$repo_root/scripts/launch-dev-app.sh"
fi

say "Verifying the app is running"
for _ in {1..10}; do
    sleep 1
    if pgrep -x "$process_name" >/dev/null 2>&1; then
        break
    fi
done

if ! pgrep -x "$process_name" >/dev/null 2>&1; then
    echo "FAILED: $process_name is not running." >&2
    echo "\`open\` returning success does not mean the process survived." >&2

    crash="$(ls -t "$HOME/Library/Logs/DiagnosticReports"/OpenIslandApp*.ips 2>/dev/null | head -1 || true)"
    if [[ -n "$crash" ]]; then
        echo "" >&2
        echo "most recent crash report: $crash" >&2
        grep -m1 -E '"exception"|"termination"|Namespace' "$crash" 2>/dev/null | sed 's/^/  /' >&2 || true
    fi

    if [[ -x "$bundle_binary" ]]; then
        echo "" >&2
        echo "running the bundle binary in the foreground for 5s:" >&2
        "$bundle_binary" 2>&1 | head -30 | sed 's/^/  /' >&2 &
        binary_pid=$!
        sleep 5
        kill "$binary_pid" 2>/dev/null || true
        wait "$binary_pid" 2>/dev/null || true
    fi

    exit 1
fi

echo "running (pid $(pgrep -x "$process_name" | tr '\n' ' '))"

say "Event sound themes"
# Iterating the glob directly rather than collecting an array: under `set -u`
# zsh treats an empty array as unset, so both `"${arr[@]}"` and `${#arr}` abort
# the script when no pack is installed — which is exactly the case this branch
# exists to report.
found_pack=false
for manifest in "$packs_dir"/*/theme.json(N); do
    found_pack=true
    echo "  ${manifest:h:t}"
done
if $found_pack; then
    echo "pick one in Settings > Sound"
else
    echo "no sound packs installed — every event will play one macOS system sound"
    echo "install them with: ./scripts/fetch-sound-packs.sh peon"
fi

say "Ready"
cat <<'EOF'
Manual checks:
  - the island appears in the notch (or as a top-center bar on non-notch Macs)
  - Settings > Setup shows the agent hooks as installed
  - Settings > Sound can preview each event category

If the island is not visible, click the menu bar icon to reopen it.
EOF
