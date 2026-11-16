#!/bin/bash
#
# Writes Casks/macmate.rb in a checkout of the Homebrew tap for one release.
#
#   scripts/update-homebrew-cask.sh <tap-checkout> <version> <sha256-AppleSilicon-dmg> <sha256-Intel-dmg>
#
# The cask comes from scripts/homebrew/macmate.rb.template. If the tap still has
# the cask under its old name (Casks/tether.rb), it is renamed with `git mv`
# first, in a commit of its own, so `git log --follow Casks/macmate.rb` keeps
# its history. The new cask contents are staged but not committed, and nothing
# is pushed; release.sh does that.

set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "usage: $0 <tap-checkout> <version> <sha256-arm> <sha256-intel>" >&2
  exit 2
fi
tap=$1 version=$2 sha_arm=$3 sha_intel=$4

[[ "$version" =~ ^[0-9]+(\.[0-9]+)*$ ]]  || { echo "Bad version: $version" >&2; exit 2; }
[[ "$sha_arm" =~ ^[0-9a-f]{64}$ ]]       || { echo "Bad Apple Silicon sha256" >&2; exit 2; }
[[ "$sha_intel" =~ ^[0-9a-f]{64}$ ]]     || { echo "Bad Intel sha256" >&2; exit 2; }

here="$(cd "$(dirname "$0")" && pwd)"
template="$here/homebrew/macmate.rb.template"
[[ -f "$template" ]] || { echo "Missing $template" >&2; exit 1; }
[[ -d "$tap/Casks" ]] || { echo "$tap has no Casks directory" >&2; exit 1; }

new="$tap/Casks/macmate.rb"
old="$tap/Casks/tether.rb"

if [[ -e "$new" && -e "$old" ]]; then
  echo "Both Casks/macmate.rb and Casks/tether.rb exist in $tap; remove the old one first." >&2
  exit 1
elif [[ ! -e "$new" && -e "$old" ]]; then
  # The rename gets a commit of its own, with the content unchanged, so git
  # records it as a rename and `git log --follow` reaches the older commits.
  # Renaming and rewriting in one commit would look like a delete plus an add.
  git -C "$tap" mv Casks/tether.rb Casks/macmate.rb
  git -C "$tap" commit -qm "Rename the cask from tether to macmate"
  echo "    renamed Casks/tether.rb -> Casks/macmate.rb in its own commit (history kept)"
fi

sed -e "s/@VERSION@/$version/" -e "s/@SHA_ARM@/$sha_arm/" -e "s/@SHA_INTEL@/$sha_intel/" "$template" > "$new"

/usr/bin/ruby -c "$new" >/dev/null
grep -q "version \"$version\"" "$new" && grep -q "$sha_arm" "$new" && grep -q "$sha_intel" "$new" \
  || { echo "Couldn't write $new" >&2; exit 1; }
! grep -q '@[A-Z_]*@' "$new" || { echo "Unfilled placeholder in $new" >&2; exit 1; }

git -C "$tap" add Casks/macmate.rb
echo "    Casks/macmate.rb -> $version"
