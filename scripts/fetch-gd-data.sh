#!/usr/bin/env bash
#
# fetch-gd-data.sh — find Grim Dawn data on a Windows machine (run under WSL)
# and rsync the subset gd-explorer needs into a `data/gd-data` layout on another host.
#
# It searches every mounted Windows drive (/mnt/c, /mnt/e, ...) for:
#   * the game install (database.arz + Text_EN.arc + gdx1/gdx2/gdx3 DLC)
#   * your saves (transfer stash + each character's player.gdc), checking both
#     the Documents location and the Steam Cloud (userdata) location.
#
# It stages only the ~100 MB we actually need (not the multi-GB install), then
# rsyncs the staging dir to your destination.
#
# Usage:
#   ./fetch-gd-data.sh [user@host:/path/to/gd-explorer/data/gd-data]
#
#   - With a destination: stages locally, then rsyncs to it.
#   - Without a destination: stages locally only and prints the path so you can
#     copy it yourself.
#
# Options (env vars):
#   STAGING=<dir>    staging directory (default: ./gd-data-staging)
#   GAME_DIR=<dir>   skip game-install detection, use this dir
#   SAVE_DIR=<dir>   skip save detection, use this dir
#   ASSUME_YES=1     don't prompt before copying
#
set -euo pipefail

DEST="${1:-}"
STAGING="${STAGING:-./gd-data-staging}"
ASSUME_YES="${ASSUME_YES:-0}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

command -v rsync >/dev/null || die "rsync not found. Install it: sudo apt install rsync"

# --- enumerate Windows drives mounted in WSL (e.g. /mnt/c, /mnt/e) -------------
drives=()
for d in /mnt/*; do
  [ -d "$d" ] || continue
  name=$(basename "$d")
  # single-letter mounts are the Windows drives
  [[ "$name" =~ ^[a-z]$ ]] && drives+=("$d")
done
[ "${#drives[@]}" -gt 0 ] || die "No Windows drives found under /mnt. Are you in WSL?"
log "Drives to search: ${drives[*]}"

# --- locate the game install ---------------------------------------------------
# A valid game dir contains database/database.arz.
find_game_dir() {
  # Fast path: well-known relative locations under each drive.
  local rels=(
    "Program Files (x86)/Steam/steamapps/common/Grim Dawn"
    "Program Files/Steam/steamapps/common/Grim Dawn"
    "SteamLibrary/steamapps/common/Grim Dawn"
    "Steam/steamapps/common/Grim Dawn"
    "Games/Steam/steamapps/common/Grim Dawn"
    "Games/SteamLibrary/steamapps/common/Grim Dawn"
  )
  local drive rel cand
  for drive in "${drives[@]}"; do
    for rel in "${rels[@]}"; do
      cand="$drive/$rel"
      [ -f "$cand/database/database.arz" ] && { printf '%s\n' "$cand"; return 0; }
    done
  done
  # Fallback: bounded find (Steam libraries can live at odd depths).
  for drive in "${drives[@]}"; do
    while IFS= read -r -d '' cand; do
      [ -f "$cand/database/database.arz" ] && { printf '%s\n' "$cand"; return 0; }
    done < <(find "$drive" -maxdepth 7 -type d -iname 'Grim Dawn' \
               -ipath '*steamapps/common*' -print0 2>/dev/null)
  done
  return 1
}

# --- locate save dirs ----------------------------------------------------------
# A valid save dir contains transfer.gst/.gsh and/or main/<char>/player.gdc.
# Both the Documents copy and the Steam Cloud copy may exist; we list all and
# pick the one with the most recently modified player.gdc.
save_dir_is_valid() {
  local d="$1"
  [ -f "$d/transfer.gst" ] || [ -f "$d/transfer.gsh" ] && return 0
  find "$d" -maxdepth 2 -name player.gdc -print -quit 2>/dev/null | grep -q . && return 0
  return 1
}

newest_gdc_mtime() {  # epoch seconds of newest player.gdc, or 0
  find "$1" -name player.gdc -printf '%T@\n' 2>/dev/null | sort -n | tail -1 | cut -d. -f1
}

find_save_dirs() {
  local drive cand
  for drive in "${drives[@]}"; do
    # Documents (incl. OneDrive-redirected) for every user
    while IFS= read -r -d '' cand; do
      save_dir_is_valid "$cand" && printf '%s\n' "$cand"
    done < <(find "$drive" -maxdepth 6 -type d -ipath '*My Games/Grim Dawn/save' -print0 2>/dev/null)
    # Steam Cloud userdata
    while IFS= read -r -d '' cand; do
      save_dir_is_valid "$cand" && printf '%s\n' "$cand"
    done < <(find "$drive" -maxdepth 8 -type d -ipath '*userdata/*/219990/remote/save' -print0 2>/dev/null)
  done
}

# --- detect -------------------------------------------------------------------
if [ -n "${GAME_DIR:-}" ]; then
  game_dir="$GAME_DIR"
  [ -f "$game_dir/database/database.arz" ] || die "GAME_DIR has no database/database.arz: $game_dir"
else
  log "Searching for Grim Dawn install..."
  game_dir=$(find_game_dir) || die "Could not find a Grim Dawn install. Set GAME_DIR=... explicitly."
fi
log "Game install: $game_dir"

if [ -n "${SAVE_DIR:-}" ]; then
  save_dir="$SAVE_DIR"
  save_dir_is_valid "$save_dir" || die "SAVE_DIR has no saves: $save_dir"
else
  log "Searching for save data (Documents + Steam Cloud)..."
  mapfile -t save_candidates < <(find_save_dirs | sort -u)
  [ "${#save_candidates[@]}" -gt 0 ] || die "Could not find any saves. Set SAVE_DIR=... explicitly."
  if [ "${#save_candidates[@]}" -eq 1 ]; then
    save_dir="${save_candidates[0]}"
  else
    warn "Multiple save locations found (picking the one with the newest character):"
    best=""; best_t=-1
    for c in "${save_candidates[@]}"; do
      t=$(newest_gdc_mtime "$c"); t=${t:-0}
      when=$(date -d "@$t" '+%Y-%m-%d %H:%M' 2>/dev/null || echo '?')
      printf '      %s   (newest character: %s)\n' "$c" "$when" >&2
      if [ "$t" -gt "$best_t" ]; then best_t=$t; best=$c; fi
    done
    save_dir="$best"
  fi
fi
log "Save data: $save_dir"

# --- summarize what we'll copy -------------------------------------------------
echo
log "Game files to copy (only those that exist):"
game_rel=(
  "database/database.arz"
  "resources/Text_EN.arc"
  "gdx1/database/GDX1.arz"  "gdx1/resources/Text_EN.arc"
  "gdx2/database/GDX2.arz"  "gdx2/resources/Text_EN.arc"
  "gdx3/database/GDX3.arz"  "gdx3/resources/Text_EN.arc"
)
for rel in "${game_rel[@]}"; do
  if [ -f "$game_dir/$rel" ]; then
    sz=$(du -h "$game_dir/$rel" | cut -f1)
    printf '      %-32s %s\n' "$rel" "$sz"
  else
    printf '      %-32s (missing — DLC not owned?)\n' "$rel"
  fi
done

echo
log "Save files to copy:"
for f in transfer.gst transfer.gsh; do
  [ -f "$save_dir/$f" ] && printf '      %s\n' "$f"
done
char_count=0
while IFS= read -r gdc; do
  printf '      main/%s/player.gdc\n' "$(basename "$(dirname "$gdc")")"
  char_count=$((char_count+1))
done < <(find "$save_dir/main" -maxdepth 2 -name player.gdc 2>/dev/null | sort)
[ "$char_count" -eq 0 ] && warn "No character player.gdc files found under $save_dir/main"

echo
log "Staging dir: $STAGING"
[ -n "$DEST" ] && log "Destination: $DEST" || warn "No destination given — will stage locally only."

if [ "$ASSUME_YES" != "1" ]; then
  read -r -p "Proceed? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || die "Aborted."
fi

# --- stage --------------------------------------------------------------------
log "Staging into $STAGING ..."
rm -rf "$STAGING"
for rel in "${game_rel[@]}"; do
  src="$game_dir/$rel"
  [ -f "$src" ] || continue
  dst="$STAGING/game/$rel"
  mkdir -p "$(dirname "$dst")"
  cp -p "$src" "$dst"
done

mkdir -p "$STAGING/save/main"
for f in transfer.gst transfer.gsh; do
  [ -f "$save_dir/$f" ] && cp -p "$save_dir/$f" "$STAGING/save/$f"
done
while IFS= read -r gdc; do
  name=$(basename "$(dirname "$gdc")")
  mkdir -p "$STAGING/save/main/$name"
  cp -p "$gdc" "$STAGING/save/main/$name/player.gdc"
done < <(find "$save_dir/main" -maxdepth 2 -name player.gdc 2>/dev/null)

staged_size=$(du -sh "$STAGING" | cut -f1)
log "Staged $staged_size into $STAGING"

# --- push ---------------------------------------------------------------------
if [ -n "$DEST" ]; then
  log "Rsyncing to $DEST ..."
  # Trailing slash on source copies its *contents* into DEST.
  rsync -av --progress "$STAGING/" "$DEST/"
  log "Done. Data is at: $DEST"
else
  echo
  log "Staged locally. To finish, rsync it to your Linux box, e.g.:"
  echo "      rsync -av '$STAGING/' user@host:/var/home/xavier/code/gd-explorer/data/gd-data/"
fi
