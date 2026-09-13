# Release signing — why an update would otherwise need an uninstall

Android installs an APK over an existing one only when **both** are signed by
the same key. Nothing in a fresh Flutter project provides one, so every release
build silently falls back to the *debug* keystore — and a debug keystore is
generated per machine. The dev laptop has one; a GitHub Actions runner makes
itself a different one. The two builds are then, as far as Android is
concerned, two unrelated apps claiming the same package name. Installing
either over the other fails with `INSTALL_FAILED_UPDATE_INCOMPATIBLE`, and the
only way through is an uninstall — which wipes the player's save: level,
doubloons, unlocked characters, campaign stars, all of it.

So Raft Rumble needs one real, permanent release key. Builds signed with it
install straight over each other and keep the save.

## How the build finds the key

| File | Purpose | In git? |
| --- | --- | --- |
| `android/app/release-key.jks` | The signing key itself. | **No** — gitignored |
| `android/app/key.properties` | Its passwords and alias. | **No** — gitignored |
| `android/app/build.gradle.kts` | Reads both, and falls back to the debug key when they are missing. | Yes |

Because the fallback exists, a fresh clone builds and runs with no setup at
all — it just produces an APK that will not install over anybody else's.

## Creating the key (once, ever)

```bash
keytool -genkey -v \
  -keystore android/app/release-key.jks \
  -storetype JKS \
  -keyalg RSA -keysize 2048 -validity 10950 \
  -alias raftrumble
```

Then write `android/app/key.properties`:

```properties
storePassword=<the store password you just chose>
keyPassword=<the key password you just chose>
keyAlias=raftrumble
```

`flutter build apk --release` picks both up with no extra flags.

> **Back both files up somewhere off this machine.** They are deliberately not
> in git and they cannot be regenerated: lose them and the *only* way to
> install a future build is an uninstall, taking every player's save with it.
> A copy in a password manager or a private cloud folder is enough.

## Making GitHub Actions builds match

CI builds are signed with a throwaway debug key until the key is added as
repository secrets — every workflow prints a warning when that happens, so a
release built without them is not silent.

1. Produce a base64 copy of the keystore:

   ```bash
   base64 -w0 android/app/release-key.jks > docs/.keystore-base64.txt
   ```

   (On Windows PowerShell:
   `[Convert]::ToBase64String([IO.File]::ReadAllBytes("android/app/release-key.jks")) | Set-Content docs/.keystore-base64.txt`)

2. On GitHub → **Settings → Secrets and variables → Actions**, add four
   **repository secrets**:

   | Name | Value |
   | --- | --- |
   | `ANDROID_KEYSTORE_BASE64` | the entire contents of `docs/.keystore-base64.txt` |
   | `ANDROID_STORE_PASSWORD` | `storePassword` from `android/app/key.properties` |
   | `ANDROID_KEY_PASSWORD` | `keyPassword` from the same file |
   | `ANDROID_KEY_ALIAS` | `raftrumble` |

3. Delete `docs/.keystore-base64.txt` once pasted. It is gitignored, but it is
   a plain-text copy of a private key sitting in the working tree and it has
   no further use — the `.jks` is the one to keep.

### One optional variable

| Name | Purpose |
| --- | --- |
| `RAFT_SERVER` | Repository **variable** (not a secret) holding the online play server base URL baked into release builds. Leave it unset to use the default in `lib/game/server_discovery.dart`. |

## A trap worth knowing about

Every workflow decodes the keystore in a step with **no `if:` condition**, and
lets the script decide whether the secret is set. That is deliberate. A step's
`if:` cannot read an `env:` block declared on that same step — GitHub only
exposes step-level env once the step is already running, not while its own
`if:` is being evaluated. Gating the step on something like
`env.HAS_KEYSTORE` therefore makes it *silently never run*, even with the
secrets set perfectly, and every release quietly falls back to a fresh debug
key and refuses to install over the last one. The symptom is confusing
("releases keep needing an uninstall") and the cause is invisible in the logs,
because the step simply does not appear.

## Every time you ship a build

Bump the build number in `pubspec.yaml`:

```yaml
version: 1.1.0+2      # ← the +N
```

Android compares that `+N` (`versionCode`). A **higher** number is an update;
the **same** number reinstalls in place; a **lower** number is refused
outright. Release-please bumps the version half automatically from Conventional
Commits, but the `+N` is yours to keep moving.

## Checking a build before handing it over

```bash
# Which key signed it — the SHA-256 must match on both builds
apksigner verify --print-certs build/app/outputs/flutter-apk/app-release.apk

# What versionCode it carries
aapt dump badging build/app/outputs/flutter-apk/app-release.apk | head -1
```

`apksigner` and `aapt` live in `$ANDROID_HOME/build-tools/<version>/`.
