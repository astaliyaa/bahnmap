# Getting BahnMap onto your iPhone (no Mac needed)

GitHub Actions builds the app on a macOS runner and uploads it to **TestFlight**. Then you install it with the TestFlight app on your iPhone. You do the one-time setup below in a browser plus a terminal (Git Bash, WSL or Linux). It takes about 20 minutes.

## What you'll create

| GitHub secret | What it is |
|---|---|
| `SIGNING_KEY_PEM` | Private key of your distribution certificate (made by the script) |
| `SIGNING_CERT_BASE64` | The `distribution.cer` that Apple gives you, base64-encoded |
| `PROVISION_PROFILE_BASE64` | App Store provisioning profile, base64-encoded |
| `ASC_KEY_ID` | App Store Connect API key ID |
| `ASC_ISSUER_ID` | App Store Connect API issuer ID |
| `ASC_KEY_P8` | Contents of the `AuthKey_XXXX.p8` file |

If you already have an Apple Distribution `.p12`, you can set `BUILD_CERTIFICATE_BASE64` and `P12_PASSWORD` instead of the first two.

---

## 1. Register the App ID

1. Go to <https://developer.apple.com/account/resources/identifiers/list> and click **+**.
2. Choose **App IDs**, then **App**.
3. Description: `BahnMap`. Bundle ID: **Explicit**, for example `de.yourname.bahnmap`. This has to be unique worldwide.
4. Leave the capabilities alone and click **Register**.

## 2. Create the distribution certificate

In this repo, run:

```bash
./scripts/make-signing-request.sh you@example.com "Your Name"
```

This creates `signing/distribution.key` and `signing/distribution.csr`. The `signing/` folder is git-ignored, so never commit it.

1. Go to <https://developer.apple.com/account/resources/certificates/add>.
2. Choose **Apple Distribution** and upload `signing/distribution.csr`.
3. Download the certificate and save it as `signing/distribution.cer`.

> You can have only a few distribution certificates at once. If Apple says you have reached the limit, revoke an old one you don't use.

## 3. Create the provisioning profile

1. Go to <https://developer.apple.com/account/resources/profiles/add>.
2. Under **Distribution**, choose **App Store Connect**.
3. Pick the BahnMap App ID, then the certificate from step 2.
4. Name it, for example `BahnMap AppStore`, then download it into `signing/`.

The workflow reads the bundle ID, team ID and profile name straight from this file, so you don't configure them anywhere else.

## 4. Create the app in App Store Connect

1. Go to <https://appstoreconnect.apple.com/apps> and choose **+**, then **New App**.
2. Platform: iOS. Name: `BahnMap`, or anything else that's free. Language: German or English. Bundle ID: the one from step 1. SKU: `bahnmap`.
3. You don't need to fill in anything else to use TestFlight.

## 5. Create an App Store Connect API key

1. Go to <https://appstoreconnect.apple.com/access/integrations/api> and generate a key under **Team Keys**. Access **App Manager** is enough.
2. Note the **Key ID** and the **Issuer ID** shown at the top.
3. Download `AuthKey_XXXXXXXXXX.p8`. You can only download it once.

## 6. Add the GitHub secrets

Run:

```bash
./scripts/print-secrets.sh
```

Then go to GitHub, open the repo, and choose **Settings**, **Secrets and variables**, **Actions**, then **New repository secret**. Add:

- `SIGNING_KEY_PEM`: the whole key block from the script output, including the `-----BEGIN…` and `-----END…` lines
- `SIGNING_CERT_BASE64`: from the script output
- `PROVISION_PROFILE_BASE64`: from the script output
- `ASC_KEY_ID`: the Key ID
- `ASC_ISSUER_ID`: the Issuer ID
- `ASC_KEY_P8`: open the `.p8` file in a text editor and paste all of it

## 7. Build

- Every push builds the app for the simulator as a compile check.
- Every push to `main` also signs the app and uploads it to TestFlight.
- To upload from any branch, open the **Actions** tab, choose **iOS build**, then **Run workflow**.

When the run is green, wait 5–15 minutes for Apple to process the build. Then:

1. In App Store Connect, open **TestFlight** and go to **Internal Testing**.
2. Create a group and add yourself.
3. Install the **TestFlight** app on your iPhone and accept the invite.

Every later build shows up there automatically.

## Troubleshooting

- **"No signing certificate 'iOS Distribution' found"** or **"doesn't match"**: the profile from step 3 must include the certificate from step 2. Create the profile again after you make a new certificate.
- **Upload fails with "bundle version must be higher"**: build numbers come from the workflow run number. Re-run the workflow and the number goes up.
- **"No suitable application records were found"**: you skipped step 4, or the bundle ID there doesn't match.
- **Missing compliance**: the app declares `ITSAppUsesNonExemptEncryption = NO`, so TestFlight shouldn't ask about encryption.
- **macOS minutes**: on a private repo, GitHub bills macOS minutes at 10× the Linux rate. One full build uses about 10–15 minutes. A public repo builds for free.
