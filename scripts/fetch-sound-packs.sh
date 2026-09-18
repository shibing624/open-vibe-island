#!/bin/zsh
# Installs CESP event sound packs for Open Island.
#
#   ./scripts/fetch-sound-packs.sh              # install everything that is missing
#   ./scripts/fetch-sound-packs.sh peon         # install only named packs
#   ./scripts/fetch-sound-packs.sh --force      # re-download and re-install
#   ./scripts/fetch-sound-packs.sh --list       # show the pack table and exit
#
# ## Why a downloader for most packs
#
# The Orc Peon pack is bought out and ships inside the app bundle
# (Sources/OpenIslandApp/SoundPacks/peon) — it is not downloadable, it is already
# there. Everything else in the table below is upstream game audio (PeonPing
# registry) whose manifests declare CC-BY-NC-4.0 — non-commercial, which is
# incompatible with this repository's GPL-3.0 license. The repository root
# LICENSE of PeonPing/og-packs says MIT, but the per-pack declaration wins:
# PeonPing cannot relicense Blizzard or EA audio.
#
# So those packs are never committed here. They are installed into
#
#     ~/Library/Application Support/OpenIsland/SoundPacks/<pack>/
#
# which is outside the repository entirely — nothing to gitignore. This mirrors
# what the commercial Vibe Island app does: it ships no audio either and pulls
# packs from https://PeonPing.github.io/registry/index.json at runtime.
#
# ## What ends up on disk
#
# Each pack directory holds the audio files flat plus a trimmed manifest
# `theme.json` (see `SoundTheme` in Sources/OpenIslandCore). Files are chosen
# **by manifest category**, never by guessing file names — upstream already
# states which sound means "finished" and which means "error".

set -euo pipefail

DEST="$HOME/Library/Application Support/OpenIsland/SoundPacks"
CACHE="$HOME/Library/Caches/OpenIsland/sound-packs"

# Sounds kept per category. Enough to rotate (so the same event does not always
# sound identical) without importing whole packs — ra_soviet alone ships 36.
PER_CATEGORY=3

# Duration cap for a single sound, in seconds.
#
# Needed because upstream categories do not distinguish "cue" from "whole track":
# the Zelda ALTTP pack is built from score, where the first entry of a category
# can run 10 seconds. A cue longer than the event it announces is noise.
# Measured with afinfo (real duration) rather than file size, because mp3 and wav
# bitrates differ by an order of magnitude inside the same pack.
MAX_SECONDS=3.0

# Categories Open Island triggers. See `SoundCue` in Sources/OpenIslandCore.
CATEGORIES=(session.start task.acknowledge task.complete task.error input.required)

# One line per pack: <pack id>|<github repo>|<tag>|<path inside repo>
# An empty path means the manifest sits at the repository root (single-pack repo).
# The pack id is the directory name on disk and the value persisted in settings;
# `peon` is the default picked by the app when no choice has been made yet.
PACKS=(
  # Game audio — CC-BY-NC-4.0, non-commercial, do not redistribute.
  # (peon is not here: it is bought out and bundled with the app.)
  "red-alert-soviet|PeonPing/og-packs|v1.1.0|ra_soviet"             # Red Alert Soviet
  "glados|PeonPing/og-packs|v1.1.0|glados"                          # Portal GLaDOS
  "sc-scv|PeonPing/og-packs|v1.1.0|sc_scv"                          # StarCraft SCV
  "zelda-ocarina|PeonPing/og-packs|v1.1.0|ocarina_of_time"          # Zelda Ocarina of Time
  "pikmin|AlvaroGraca-TomTom/openpeon-pikmin|v1.1.0|"               # Pikmin
  "speaki|CJNA/peon-ping-speaki|v1.0.0|"                            # Petite Speaki
  # Synthesized UI sounds — MIT / CC0, safe to redistribute.
  "cute-minimal|TechPdM/openpeon-cute-minimal|v1.0.1|"              # Cute UI
  "dreamy-minimal|TechPdM/openpeon-dreamy-minimal|v1.0.1|"          # Dreamy Beeps
  "minimal-dings|iain/minimal-dings|v1.0.1|"                        # Minimal Dings
)

FORCE="no"
SELECTED=()
for arg in "$@"; do
  case "$arg" in
    --force) FORCE="yes" ;;
    --list)
      printf '%s\n' "${PACKS[@]}" | sed 's/|/\t/g'
      exit 0
      ;;
    -*)
      echo "unknown flag: $arg" >&2
      echo "usage: $0 [--force] [--list] [pack ...]" >&2
      exit 2
      ;;
    *) SELECTED+=("$arg") ;;
  esac
done

# Downloads the repository archive holding a pack and prints the zip path.
# Cached per repo@tag: og-packs contains five packs in one 62 MB archive, so
# fetching per pack would download it five times.
fetch_repo() {
  local repo="$1" ref="$2"
  local slug zip
  slug="${repo//\//-}"
  zip="$CACHE/$slug-$ref.zip"
  if [[ ! -f "$zip" || "$FORCE" == "yes" ]]; then
    echo "  downloading $repo@$ref" >&2
    mkdir -p "$CACHE"
    curl -sSL --fail -o "$zip" \
      "https://github.com/$repo/archive/refs/tags/$ref.zip" ||
      curl -sSL --fail -o "$zip" \
        "https://github.com/$repo/archive/refs/heads/$ref.zip"
  fi
  echo "$zip"
}

install_pack() {
  local pack="$1" zip="$2" pkgdir="$3" repo="$4"
  local out="$DEST/$pack"

  # "Installed" is decided by the manifest, not by the directory: an empty
  # directory left behind by a failed run would otherwise count as installed and
  # never be repaired.
  if [[ -f "$out/theme.json" && "$FORCE" != "yes" ]]; then
    echo "  $pack already installed (--force to reinstall)"
    return
  fi

  rm -rf "$out"
  mkdir -p "$out"

  python3 - "$zip" "$pkgdir" "$repo" "$out" "$PER_CATEGORY" "$MAX_SECONDS" "${CATEGORIES[@]}" <<'PY'
import json, os, shutil, subprocess, sys, zipfile

zip_path, pkgdir, repo, out = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
per_cat, max_seconds = int(sys.argv[5]), float(sys.argv[6])
categories = sys.argv[7:]
pack = os.path.basename(out)


def duration(path):
    """Real duration in seconds via afinfo (ships with macOS)."""
    txt = subprocess.run(["afinfo", path], capture_output=True, text=True).stdout
    for line in txt.splitlines():
        if "estimated duration" in line:
            return float(line.split(":")[1].strip().split()[0])
    return None


def entries(node):
    """Upstream writes either {"sounds": [...]} or a bare list."""
    if isinstance(node, dict):
        return node.get("sounds", [])
    if isinstance(node, list):
        return node
    return []


with zipfile.ZipFile(zip_path) as z:
    names = z.namelist()
    wanted = f"{pkgdir}/openpeon.json" if pkgdir else "openpeon.json"
    manifest = next((n for n in names if n.endswith(wanted)), None)
    if manifest is None:
        print(f"  {pack}: no {wanted} in archive — pack layout changed?", file=sys.stderr)
        sys.exit(1)

    base = os.path.dirname(manifest)
    data = json.loads(z.read(manifest))

    license_name = data.get("license") or ""
    author = data.get("author") or {}
    if not license_name or not author.get("name"):
        # The app rejects packs without attribution, so installing one here would
        # produce a directory that never shows up in Settings.
        print(f"  {pack}: manifest has no license/author — skipped", file=sys.stderr)
        sys.exit(1)

    meta = {
        "name": data.get("name", pack),
        "display_name": data.get("display_name", pack),
        "version": data.get("version", ""),
        "license": license_name,
        "author": author,
        "cesp_version": data.get("cesp_version", ""),
        "source_repo": repo,
        "source_path": pkgdir,
    }

    # Audio is flat inside the pack: some upstream packs list the same 150 files
    # under every category, and per-category subdirectories would copy them once
    # per category. Category membership lives in the manifest, which is the only
    # thing the app reads.
    used = {}
    copied = set()
    for cat in categories:
        for sound in entries(data.get("categories", {}).get(cat)):
            if len(used.get(cat, [])) >= per_cat:
                break
            src = f"{base}/{sound['file']}"
            if src not in names:
                print(f"  {pack}: manifest lists missing file {sound['file']}", file=sys.stderr)
                sys.exit(1)
            name = os.path.basename(sound["file"])
            dst = os.path.join(out, name)
            if name not in copied:
                with z.open(src) as f, open(dst, "wb") as g:
                    shutil.copyfileobj(f, g)
                if (duration(dst) or 0) > max_seconds:
                    os.remove(dst)
                    continue
                copied.add(name)
            used.setdefault(cat, []).append({"file": name, "label": sound.get("label", "")})
        if not used.get(cat):
            print(f"  {pack}: no sound under {max_seconds}s for {cat} — will borrow", file=sys.stderr)

    if not used:
        print(f"  {pack}: nothing usable in the archive", file=sys.stderr)
        sys.exit(1)

    meta["categories"] = used
    with open(os.path.join(out, "theme.json"), "w") as f:
        json.dump(meta, f, ensure_ascii=False, indent=2)
        f.write("\n")

    total = sum(len(v) for v in used.values())
    print(f"  {pack}: {total} sounds, {len(used)}/{len(categories)} categories, {license_name}")
PY
}

echo "Installing sound packs into: $DEST"
echo "Audio is downloaded, never committed. Most packs are CC-BY-NC-4.0 game"
echo "audio: personal use only, not redistributable with this GPL-3.0 project."
echo
mkdir -p "$DEST"

for entry in "${PACKS[@]}"; do
  IFS='|' read -r pack repo ref pkgdir <<< "$entry"
  if (( ${#SELECTED} )) && [[ " ${SELECTED[*]} " != *" $pack "* ]]; then
    continue
  fi
  echo "$pack"
  install_pack "$pack" "$(fetch_repo "$repo" "$ref")" "$pkgdir" "$repo" || \
    echo "  $pack failed — skipped"
done

echo
# `$DEST/*/` instead of the zsh-only `(/N)` qualifier: `sh` is what people
# actually type (and what tests/CI would use), and on macOS `sh` is bash, which
# cannot parse `(/N)` — it fails the whole script on this line. `find` needs no
# qualifier, matches dirs only, and prints nothing when there are none.
find "$DEST" -mindepth 1 -maxdepth 1 -type d -exec du -sh {} + 2>/dev/null | sed 's/^/  /' || true
echo
echo "Done. Pick the theme in Open Island > Settings > Sound."
echo "If Open Island is already running, press \"Rescan Sound Packs\" there."
