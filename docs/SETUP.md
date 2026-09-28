# Setting up Chirp

Chirp has no server, so setup is all on the Apple side: a developer account, a
push key, and, for ad-hoc distribution, a list of registered devices.

## What you need

- A paid **Apple Developer Program** membership ($99/year). The PushToTalk
  entitlement, push notifications and ad-hoc distribution all require it. A
  free Apple ID can't sign any of them.
- A Mac with **Xcode 16** or later, plus [XcodeGen](https://github.com/yonaskolb/XcodeGen)
  (`brew install xcodegen`), for local builds.
- iPhones on **iOS 16** or later. Apple Watch on **watchOS 9** or later is optional.

## 1. Register the app with Apple

In [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources):

1. **Identifiers → +** → App IDs → App, with bundle ID for example
   `com.yourname.eptt`. Enable these capabilities:
   - **Push Notifications**
   - **Push to Talk**
   - **iCloud**, with **CloudKit**, and a container named
     `iCloud.com.yourname.eptt` (that is, `iCloud.` plus your bundle ID). This
     is the relay fallback.
2. Create a second App ID, `com.yourname.eptt.watchkitapp`, for the watch app.
   It needs no capabilities.
3. **Keys → +** → enable **Apple Push Notifications service (APNs)**. If the
   portal lets you restrict a key to one environment and topic, restrict it
   to *Production* and your bundle ID. That limits the damage if the key ever
   leaks. Download `AuthKey_XXXXXXXXXX.p8` and note the **Key ID** and your
   **Team ID**. The key can be downloaded only once, so keep it safe.

### iCloud relay (one-time)

In the [CloudKit Console](https://icloud.developer.apple.com/), for your
container:

1. Run a development build once. The first relayed message creates the
   `RelayMessage` record type. Alternatively, create it by hand with the
   fields `mailbox` (String), `payload` (Bytes) and `expires` (Date/Time).
2. **Indexes:** make `mailbox` *Queryable*, and `recordName` *Queryable* as
   well, which CloudKit needs for subscriptions.
3. **Security roles:** give the *Authenticated* role **Write** on
   `RelayMessage`, so recipients can delete a message once it is delivered.
   Without this, messages are still removed, but only when they expire after
   24 h. Records only ever contain encrypted data.
4. **Deploy Schema Changes** to Production. Ad-hoc builds use the production
   environment.

Everyone using the relay must be signed in to iCloud on their iPhone.

## 2. Build from Xcode (development)

```sh
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig   # then edit it
xcodegen
open Chirp.xcodeproj
```

In `Secrets.xcconfig`, set `DEVELOPMENT_TEAM` and `EPTT_BUNDLE_ID`. Pick your
iPhone and run. Debug builds use **development** (sandbox) push tokens, while
ad-hoc builds use **production** tokens. The environment travels with each
contact card, so mixed groups still work.

## 3. Get the push key onto every phone

The push key is what lets your phone wake a friend's locked phone when you key
up (docs/ARCHITECTURE.md explains why the app holds it and no server does).
There are two ways to get it onto phones.

**Share it in the app (recommended).** On one phone, open **Settings → Push
key** and enter the Team ID, the Key ID and the contents of the `.p8` file.
The screen then shows a QR code. Friends scan it from **Contacts → Add**, or
you send them the link. The key lives in each phone's Keychain and never
appears in the published app.

**Or bundle it into your own builds.** Put the file at `Config/APNsAuthKey.p8`
and set `EPTT_APNS_TEAM_ID` and `EPTT_APNS_KEY_ID` in `Secrets.xcconfig`.
Only do this for builds you don't publish. Anyone who has the IPA can extract
the key.

What a leaked key allows: sending pushes to Chirp users whose push tokens the
holder knows. Tokens only travel inside encrypted Chirp traffic and in contact
QR codes. A leaked key cannot decrypt or forge audio. If it leaks, revoke the
key in the portal and share a new one.

## 4. Ad-hoc distribution from GitHub Pages

The **Ad-hoc release** workflow (`.github/workflows/release.yml`) builds a
signed IPA and publishes an install page at
`https://<owner>.github.io/<repo>/`.

### Before the first release

1. **Register devices.** Go to **Devices → +** and add each iPhone's and
   Apple Watch's UDID. You can register up to 100 of each per membership year.
   A friend can find their UDID by connecting the phone to a Mac (Finder shows
   it when you click the serial number) or with a UDID-lookup profile.
2. **Distribution certificate.** Go to **Certificates → +** → *Apple
   Distribution*. Export it with its private key from Keychain Access as a
   `.p12` file with a password.
3. **Provisioning profiles.** Go to **Profiles → +** → *Ad Hoc*. Create one
   profile for the iOS App ID and one for the watch App ID, each including all
   your registered devices, then download both.
4. **GitHub secrets.** Under **Settings → Secrets and variables → Actions**:

   | Secret | Value |
   | --- | --- |
   | `BUILD_CERTIFICATE_P12_BASE64` | `base64 -i dist.p12` |
   | `P12_PASSWORD` | the `.p12` password |
   | `ADHOC_PROFILE_IOS_BASE64` | `base64 -i Chirp_AdHoc.mobileprovision` |
   | `ADHOC_PROFILE_WATCH_BASE64` | `base64 -i Chirp_Watch_AdHoc.mobileprovision` |
   | `APPLE_TEAM_ID` | your Team ID |
   | `EPTT_BUNDLE_ID` | for example `com.yourname.eptt` |
   | `APNS_KEY_P8`, `APNS_KEY_ID` | *optional*: used only when the repository variable `BUNDLE_APNS_KEY` is `true` |

5. **Pages.** Under **Settings → Pages → Source**, choose **GitHub Actions**.
   GitHub Pages sites are public. The page is marked `noindex` but not hidden.
   That is why the push key is left out of the IPA by default. The IPA only
   installs on registered devices, but anyone can download it. On a free
   GitHub plan, Pages requires a public repository.

### Releasing

Push a tag such as `git tag v0.1.0 && git push origin v0.1.0`, or run the
workflow manually from the Actions tab. When it finishes, open the Pages URL
in **Safari** on a registered iPhone and tap **Install**.

### Adding a friend later

1. Register their UDID.
2. Edit both ad-hoc profiles to include the new device, then download them.
3. Update the two profile secrets and run the workflow again. Existing
   installs keep working.

## 5. First run

1. Grant microphone, local network and notification access when asked.
2. **Contacts → My code** shows your QR code. Scan each other's codes.
   Adding someone is mutual only once both of you have scanned.
3. Compare safety numbers in each contact's detail screen.
4. Pick a channel on the **Talk** tab and hold the button.
5. Create talk groups on the **Channels** tab. Members receive the key
   automatically over their private channels.

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| "Couldn't connect to …" after a wake | Both phones are behind strict NAT with no IPv6. Add an overlay address (Tailscale or similar) in Settings → Network. |
| Friend never wakes up | They have no push key installed, their token is stale (they should open the app once), or their build's push environment doesn't match. |
| Works only when both apps are open | No push key on the talker's phone. See section 3. |
| Watch says "Open Chirp on iPhone" | The phone app hasn't been launched since the phone rebooted. |
