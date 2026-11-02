#!/bin/bash
# Lists the English localizable strings that are new, changed or removed between
# two revisions, as Crowdin will see them.
#
# Each revision is checked out in a temporary worktree, built, and exported with
# xcodebuild -exportLocalizations, the same export the CI workflow uploads. The
# export cannot build the Iris library itself, so each revision is built first.
# Your checkout is not changed.
#
# Usage: scripts/localization_diff.sh <old-revision> [new-revision]
#   new-revision defaults to HEAD.
#
# Tools: Xcode, git and uv.
set -euo pipefail

cd "$(dirname "$0")/.." || exit 1

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
  sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
fi
old_rev="$(git rev-parse --verify "$1^{commit}")"
new_rev="$(git rev-parse --verify "${2:-HEAD}^{commit}")"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/mochi-l10n.XXXXXX")"
cleanup() {
  for name in old new; do
    if [ -d "$work_dir/$name" ]; then
      git worktree remove --force "$work_dir/$name" >/dev/null 2>&1 || true
    fi
  done
  rm -rf "$work_dir"
}
trap cleanup EXIT

export_strings() {
  local name="$1" rev="$2"
  local tree="$work_dir/$name"
  echo "==> Exporting strings at $(git rev-parse --short "$rev")" >&2
  git worktree add --quiet --detach "$tree" "$rev"
  git -C "$tree" submodule update --quiet --init
  local xcodebuild_args=(
    -project "$tree/Mochi Diffusion.xcodeproj"
    -scheme "Mochi Diffusion"
    -configuration Debug
    -derivedDataPath "$work_dir/$name-derived"
    CODE_SIGNING_ALLOWED=NO
  )
  xcodebuild build "${xcodebuild_args[@]}" >"$work_dir/$name-build.log" 2>&1 \
    || { echo "error: build failed at $rev; see $work_dir/$name-build.log" >&2; exit 1; }
  xcodebuild -exportLocalizations "${xcodebuild_args[@]}" \
    -localizationPath "$work_dir/$name-export" -exportLanguage en \
    >"$work_dir/$name-export.log" 2>&1 \
    || { echo "error: export failed at $rev; see $work_dir/$name-export.log" >&2; exit 1; }
}

export_strings old "$old_rev"
export_strings new "$new_rev"

uv run --no-project --quiet python -I - \
  "$work_dir/old-export/en.xcloc/Localized Contents/en.xliff" \
  "$work_dir/new-export/en.xcloc/Localized Contents/en.xliff" \
  "$work_dir/new" <<'PY'
import subprocess
import sys
import xml.etree.ElementTree as ET

NS = {"x": "urn:oasis:names:tc:xliff:document:1.2"}


def units(path):
    found = {}
    for file in ET.parse(path).getroot().findall("x:file", NS):
        original = file.get("original", "")
        for unit in file.iter("{%s}trans-unit" % NS["x"]):
            source = unit.find("x:source", NS)
            note = unit.find("x:note", NS)
            found[(original, unit.get("id"))] = (
                source.text if source is not None else "",
                note.text if note is not None else "",
            )
    return found


def used_in(tree, text):
    """Swift files that contain `text` as a string literal."""
    if not text:
        return []
    result = subprocess.run(
        ["git", "-C", tree, "grep", "-l", "-F", f'"{text}"', "--", "Mochi Diffusion"],
        capture_output=True, text=True,
    )
    return result.stdout.splitlines()


old, new, tree = units(sys.argv[1]), units(sys.argv[2]), sys.argv[3]
added = sorted(new.keys() - old.keys())
removed = sorted(old.keys() - new.keys())
changed = sorted(k for k in new.keys() & old.keys() if new[k] != old[k])


def show(key, values):
    original, unit_id = key
    source, note = values
    print(f"- {unit_id!r}  ({original})")
    if source != unit_id:
        print(f"    text:    {source!r}")
    print(f"    comment: {note!r}" if note else "    comment: (none)")


print(f"NEW ({len(added)})")
for key in added:
    show(key, new[key])
    files = used_in(tree, new[key][0])
    if files:
        print(f"    used in: {', '.join(files)}")
print(f"\nCHANGED ({len(changed)})")
for key in changed:
    show(key, new[key])
    old_source, old_note = old[key]
    if old_source != new[key][0]:
        print(f"    was:     {old_source!r}")
    if old_note != new[key][1]:
        print(f"    comment was: {old_note!r}")
print(f"\nREMOVED ({len(removed)})")
for key in removed:
    show(key, old[key])
PY
