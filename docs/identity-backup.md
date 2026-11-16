# Backing up and restoring MacMate's identity

MacMate's identity is what every paired phone trusts. If it is replaced, every
phone must be paired again. This page says where it lives, what MacMate does
with it, and how to back it up and roll back without ever reading the key.

## Where things are

| What | Where | Notes |
|---|---|---|
| Private key | `~/Library/Application Support/MacMate/key.pem` | mode `0600`, never leaves the Mac |
| Certificate | `…/MacMate/certificate.pem` | public; P-256 / ECDSA-SHA256, 10 years |
| Key + certificate bundle | `…/MacMate/identity.p12` | what MacMate loads (in memory, not the keychain) |
| Bundle passphrase | `…/MacMate/identity.pass` | random, mode `0600`, stored beside the bundle |
| This Mac's device ID | preferences `com.subhashh.MacMate`, key `macmate_device_id` | equals the certificate's common name |
| Paired phones and their pinned fingerprints | preferences `com.subhashh.MacMate`, key `macmate_paired_devices` | **not** in the folder above |

The folder is `0700`. Replacing the app (a new download, the in-app updater,
`brew upgrade`, or dragging a new copy into Applications) only swaps
`MacMate.app`; none of the above is inside it.

A complete backup therefore needs the four files **and** the preferences.

## What MacMate does at startup

- An identity on disk is **reused every launch**; it is never regenerated.
- If the saved device ID is missing but the key is intact, the ID is recovered
  from the certificate (its common name).
- If the files can't be used (corrupt, wrong passphrase, partial), they are
  **renamed** to `<name>.broken-<timestamp>` and a new identity is created. They
  are never overwritten or deleted, so you can put them back (below). Phones
  must be paired again with the new identity.

## Back up

Quit MacMate first so the preferences are written out. These commands copy and
compare files; none prints their contents.

```bash
osascript -e 'tell application "MacMate" to quit'; sleep 2

B=~/MacMate-backup-$(date +%Y%m%d-%H%M%S)
mkdir -m 700 "$B"

S=~/Library/Application\ Support/MacMate
for f in identity.p12 identity.pass key.pem certificate.pem; do cp -p "$S/$f" "$B/$f"; done
defaults export com.subhashh.MacMate "$B/com.subhashh.MacMate.plist"
ditto /Applications/MacMate.app "$B/MacMate.app"          # to roll the app back as well

( cd "$B" && shasum -a 256 identity.p12 identity.pass key.pem certificate.pem > SHA256SUMS && shasum -a 256 -c SHA256SUMS )
```

Every line should end in `OK`. The backup holds the private key, so keep it on
an encrypted volume, never commit or upload it, and delete it when you are done
(`rm -r "$B"` — double-check the variable first).

## Before replacing the app

1. Make the backup above.
2. Note what must not change (both values are public):

   ```bash
   defaults read com.subhashh.MacMate macmate_device_id
   openssl x509 -in ~/Library/Application\ Support/MacMate/certificate.pem -noout -fingerprint -sha256
   ```
3. Replace the app and launch it.
4. Run the two commands again. The device ID and fingerprint must be identical,
   and your phones should reconnect without pairing. No `*.broken-*` files
   should appear in the folder (`ls ~/Library/Application\ Support/MacMate`).

## Roll back

If the identity changed or phones ask to pair again:

```bash
osascript -e 'tell application "MacMate" to quit'; sleep 2
B=<your backup folder>

S=~/Library/Application\ Support/MacMate
for f in identity.p12 identity.pass key.pem certificate.pem; do cp -p "$B/$f" "$S/$f"; done
defaults import com.subhashh.MacMate "$B/com.subhashh.MacMate.plist"
rm -rf /Applications/MacMate.app && ditto "$B/MacMate.app" /Applications/MacMate.app   # only if rolling the app back too
open /Applications/MacMate.app
```

Importing the preferences also restores the pairing list as it was at backup
time, so phones paired afterwards need pairing again. Then repeat the checks in
"Before replacing the app".

To recover from a `*.broken-<timestamp>` set rather than a backup, quit MacMate,
move the newer files out of the way, and rename the four `.broken-<timestamp>`
files back to their original names.
