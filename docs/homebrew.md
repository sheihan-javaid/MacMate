# Homebrew tap

MacMate installs with:

```bash
brew install --cask sheihan-javaid/macmate/macmate
```

That resolves to the repository **`sheihan-javaid/homebrew-macmate`**, file
`Casks/macmate.rb`. `scripts/release.sh --publish` updates that file after it
publishes a release, using `scripts/update-homebrew-cask.sh` and the template
in `scripts/homebrew/macmate.rb.template`.

## Before the first publish

Two things must be true, or `release.sh --publish` stops before building
anything (it checks the tap first so a release is never left half done):

1. **The tap repository exists and you can push to it.** At the time of writing
   `sheihan-javaid/homebrew-macmate` does not exist. The old Tether cask lives in
   `subhashhhhhh/homebrew-tether`, another account's repository; this project can
   read it but cannot, and should not, change it.
2. **`sheihan-javaid/MacMate` is public.** Homebrew downloads the DMG from the
   release URL, and the in-app updater reads `updates/latest.json` through
   `raw.githubusercontent.com`. Neither works for anonymous users while the
   repository is private.

## Create the tap

Run these yourself; nothing in this repository pushes to a tap until you
publish a release.

### Option A: keep the existing cask history

Seeds the new tap from the Tether tap, so `git log --follow Casks/macmate.rb`
reaches the cask's first commit. The rename is committed on its own (content
unchanged) so git records it as a rename.

```bash
git clone https://github.com/subhashhhhhh/homebrew-tether.git homebrew-macmate
cd homebrew-macmate
git remote remove origin

# From the MacMate checkout, with the SHA-256 of each DMG from dist/SHA256SUMS-<version>.txt:
/path/to/MacMate/scripts/update-homebrew-cask.sh . 2.0 <sha256-AppleSilicon-dmg> <sha256-Intel-dmg>
git commit -m "MacMate 2.0"

gh repo create sheihan-javaid/homebrew-macmate --public --source . --push
```

This copies Tether's public tap history (its author's commits, under their
names) into your repository. The README it carries still describes Tether; edit
it before publishing.

### Option B: start clean

```bash
gh repo create sheihan-javaid/homebrew-macmate --public --clone
cd homebrew-macmate && mkdir Casks
/path/to/MacMate/scripts/update-homebrew-cask.sh . 2.0 <sha256-AppleSilicon-dmg> <sha256-Intel-dmg>
git commit -m "Add the MacMate cask" && git push
```

After either option, `release.sh --publish` keeps `Casks/macmate.rb` current.

## Notes

- The cask's `zap` stanza lists MacMate's own folders and preferences only. It
  includes `~/Library/Application Support/MacMate`, which holds the device
  identity, so `brew uninstall --zap` discards it; see
  [identity-backup.md](identity-backup.md).
- The cask declares `auto_updates true`, so `brew upgrade` leaves a
  self-updating MacMate alone.
- Check a change to the template without publishing anything: run
  `scripts/update-homebrew-cask.sh` against a scratch clone with its remote
  removed.
