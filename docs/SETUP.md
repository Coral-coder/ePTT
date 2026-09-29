# Setting up NXTPTT

NXTPTT has no server, so setup is all on the Apple side: a developer account, a
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
   `com.lightwave.chirp`. Enable these capabilities:
   - **Push Notifications**
   - **Push to Talk**
   - **iCloud**, with **CloudKit**, and a container named
     `iCloud.com.lightwave.chirp` (that is, `iCloud.` plus your bundle ID). This
     is the relay fallback.
   - **App Groups**, with a group named `group.com.lightwave.chirp`. The
     notification extension uses it to hand decoded voice messages to iOS.
2. Create a second App ID, `com.lightwave.chirp.watchkitapp`, for the watch app.
   Enable **Push Notifications** and **iCloud** (CloudKit), using the *same*
   container as the iPhone app. The standalone watch uses both.
3. Create a third App ID, `com.lightwave.chirp.notify`, for the notification
   service extension. Enable **iCloud** (CloudKit, same container) and **App
   Groups** (same group). With automatic signing in Xcode, steps 1 to 3 happen
   for you when you pick your team.
4. **Keys → +** → enable **Apple Push Notifications service (APNs)**. If the
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
open NXTPTT.xcodeproj
```

In `Secrets.xcconfig`, set `DEVELOPMENT_TEAM` and `EPTT_BUNDLE_ID`. Pick your
iPhone and run. Debug builds use **development** (sandbox) push tokens, while
ad-hoc builds use **production** tokens. The environment travels with each
contact card, so mixed groups still work.

## 3. Background playback, with or without a push key

**Without a push key**, a message to a phone that isn't connected goes through
the iCloud relay. iCloud notifies that phone, and NXTPTT's notification
extension decodes the message and plays it as the notification sound, with no
need to open the app. That sound stops after 30 seconds, and it follows the
ring/silent switch and Focus. Tapping the notification plays the whole message.

**With a push key**, your phone wakes a friend's locked phone into a live Push
to Talk session when you key up, the full walkie-talkie experience
(docs/ARCHITECTURE.md explains why the app holds the key and no server does).
There are two ways to get it onto phones.

**Share it in the app (recommended).** On one phone, open **Settings → Push
key** and enter the Team ID, the Key ID and the contents of the `.p8` file.
The screen then shows a QR code. Friends scan it from **Contacts → Add**, or
you send them the link. The key lives in each phone's Keychain and never
appears in the published app.

**Or bundle it into your own builds (nobody has to handle it).** Put the file
at `Config/APNsAuthKey.p8` and set `EPTT_APNS_TEAM_ID` and `EPTT_APNS_KEY_ID`
in `Secrets.xcconfig`. Every build you archive in Xcode then carries it, and
the Push key screen isn't needed. Both files are git-ignored. Anyone who has
the IPA could extract the key, so restrict it to your bundle ID (step 1.4).

What a leaked key allows: sending pushes to NXTPTT users whose push tokens the
holder knows. Tokens only travel inside encrypted NXTPTT traffic and in contact
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
   | `ADHOC_PROFILE_NOTIFY_BASE64` | `base64 -i Chirp_Notify_AdHoc.mobileprovision` (for `….notify`) |
   | `APPLE_TEAM_ID` | your Team ID |
   | `EPTT_BUNDLE_ID` | for example `com.lightwave.chirp` |
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

## TestFlight from GitHub Actions

`.github/workflows/testflight.yml` archives the app and uploads it to TestFlight.
Pushes to `main` are controlled by markers in the commit message:

| Commit message | What happens |
| --- | --- |
| no marker | nothing (the normal CI build still runs) |
| contains `*b` | archive and sign only, as a check; nothing is uploaded |
| contains `*u` | archive and upload to TestFlight: same version, build number plus one |

- **New version:** put `*u` in the commit message, tag the commit and push both:
  `git tag v0.2.0 && git push origin main v0.2.0`. That uploads 0.2.0, build 1.
  A tag on a commit without `*b` or `*u` does nothing.
- **By hand:** **Actions → TestFlight → Run workflow** always uploads. Its
  version and build fields are optional overrides.

The current version and build are `MARKETING_VERSION` and
`CURRENT_PROJECT_VERSION` in `project.yml`. After each successful upload the
workflow commits the numbers it used back to `main`. Signing is automatic: an App Store Connect API
key lets Xcode create and use the distribution certificate and profiles itself.

1. **The app record.** It must already exist in App Store Connect (it does once
   you have uploaded a build by hand).
2. **API key.** In App Store Connect, **Users and Access → Integrations → App
   Store Connect API → Team Keys → +**. Give it the **Admin** role (needed for
   automatic signing to create certificates and profiles). Download the `.p8`
   (only possible once) and note the **Key ID** and the **Issuer ID** shown
   above the key list.
3. **Secrets**, in the `Coral` environment (Settings → Environments → Coral), or as repository secrets. The workflow runs in that environment, so it sees both:

   | Secret | Value |
   | --- | --- |
   | `ASC_KEY_ID` | the API key's Key ID |
   | `ASC_ISSUER_ID` | the Issuer ID |
   | `ASC_KEY_P8` | the full contents of `AuthKey_XXXXXXXXXX.p8`, including the BEGIN/END lines |
   | `APPLE_TEAM_ID` | your Team ID (Membership details in the developer portal) |
   | `EPTT_BUNDLE_ID` | *optional*, defaults to `com.lightwave.chirp` |
   | `APNS_KEY_P8`, `APNS_KEY_ID` | *optional*: the APNs push key (whole `.p8` file, and its Key ID). When both are set, TestFlight builds include it for live Push to Talk wakes. The run log says "Push key: bundled" |

Builds show up in TestFlight after Apple
finishes processing, usually within 5 to 20 minutes.

### Stored signing certificate

Each run happens on a fresh Mac. Without a stored certificate, Xcode makes a new
"Apple Development: Created via API" certificate every time. The workflow never
revokes anything, so these pile up until Apple's limit stops the build. (You can
revoke old "Created via API" ones yourself under Certificates, IDs & Profiles →
Certificates; that doesn't affect TestFlight builds, which Apple re-signs.) To
stop new ones being made, store one certificate once:

1. On a Mac signed in to your developer account in Xcode (Settings → Accounts),
   make sure an **Apple Development** certificate exists: select your team,
   **Manage Certificates…**, and add **Apple Development** if none is listed.
2. Open **Keychain Access** → **login** → **My Certificates**. Find
   **Apple Development: <your name> (…)**. Expand it to check that it has a private
   key, then right-click the certificate → **Export…** → save as `dev.p12` with a
   password.
3. In Terminal: `base64 -i dev.p12 | pbcopy`
4. Add two secrets to the `Coral` environment:

   | Secret | Value |
   | --- | --- |
   | `DEV_CERT_P12` | the pasted base64 text |
   | `DEV_CERT_PASSWORD` | the password you chose in step 2 |

5. Delete `dev.p12`. The next run's log says "Signing certificate: stored".

### "Mac" devices on the account

Before 1.0.1 (2), automatic signing registered each build Mac as a device (Apple
Silicon Macs can run iPhone apps) and Apple emailed you each time. The app now
turns off "Designed for iPhone/iPad" on Mac and Vision Pro, so that stops. To clear
the old entries: developer.apple.com → Account → Certificates, IDs & Profiles →
**Devices**, filter to macOS, open each unwanted Mac and click **Disable**. Apple
doesn't allow deleting devices; disabled ones stop counting towards the limit at your
next membership renewal.

## Export compliance (encryption)

Both apps set `ITSAppUsesNonExemptEncryption` to `NO`, so App Store Connect and
TestFlight skip the encryption and France questions on every upload. The basis:
all cryptography runs through Apple's CryptoKit (built into iOS and watchOS),
with only standard algorithms (X25519, Ed25519, HKDF-SHA256, ChaCha20-Poly1305);
nothing is implemented in the app itself. That declaration is yours to make as
the publisher. If you distribute somewhere that needs a different answer, set
the key to `YES` in `project.yml` and answer the questions in App Store Connect.

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| "Couldn't connect to …" after a wake | Both phones are behind strict NAT with no IPv6. Add an overlay address (Tailscale or similar) in Settings → Network. |
| Friend never wakes up | They have no push key installed, their token is stale (they should open the app once), or their build's push environment doesn't match. |
| Works only when both apps are open | No push key on the talker's phone. See section 3. |
| Watch says "Open NXTPTT on iPhone" | The phone app hasn't been launched since the phone rebooted. |
