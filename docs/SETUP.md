# Getting BahnMap onto your iPhone (no Mac needed)

GitHub Actions builds the app on macOS, signs it automatically with your App Store Connect API key, and uploads it to TestFlight. Xcode creates the certificates and provisioning profiles itself.

## 1. Repository secrets

Go to **Settings → Secrets and variables → Actions → New repository secret** and add these. They are the same as in your other repos:

| Secret | Value |
|---|---|
| `APPLE_TEAM_ID` | Your 10-character team ID (developer.apple.com → Membership) |
| `ASC_KEY_ID` | Key ID of the App Store Connect API key |
| `ASC_ISSUER_ID` | Issuer ID shown at the top of the API keys page |
| `ASC_KEY_P8` | Full contents of `AuthKey_XXXXXXXXXX.p8`, including the BEGIN/END lines (base64 also works) |

The API key needs the **Admin** role so that Xcode can create the signing certificate and profile.

Optional: add a repository **variable** (not a secret) called `BUNDLE_ID` to change the bundle ID. The default is `de.astaliyaa.bahnmap`.

## 2. Create the app record in App Store Connect (once)

1. Go to <https://appstoreconnect.apple.com/apps> and choose **+**, then **New App**. Pick iOS, name `BahnMap` (or anything free), and SKU `bahnmap`.
2. If the bundle ID `de.astaliyaa.bahnmap` isn't in the dropdown yet, run the workflow once (step 3). Signing registers it automatically, and the upload step fails until the app record exists. Then create the app and re-run the workflow.

## 3. Build

- Every push to `main` builds, signs and uploads to TestFlight.
- You can also start it manually: **Actions → iOS build → Run workflow**.
- Every other branch only gets a compile check.

After Apple processes the build (5–15 minutes), open **TestFlight → Internal Testing** in App Store Connect, add yourself to a group, and install from the TestFlight app.
