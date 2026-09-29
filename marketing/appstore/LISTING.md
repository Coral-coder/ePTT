# App Store listing: NXTPTT

Copy each field into App Store Connect as-is. Character limits are Apple's; every value
below fits.

## App information (App Store Connect → your app → App Information)

| Field | Value |
| --- | --- |
| Name (30) | `NXTPTT: Push to Talk` |
| Subtitle (30) | `Encrypted walkie-talkie` |
| Primary category | Social Networking |
| Secondary category | Utilities |
| Content rights | "No, it does not contain, show, or access third-party content" |
| Bundle ID | `com.lightwave.chirp` (already set by the TestFlight uploads) |

If the name is taken, try in this order: `NXTPTT – Walkie Talkie`, `NXTPTT Push-to-Talk`,
`NXTPTT Radio`.

## Version page (App Store → iOS App → 1.0 Prepare for Submission)

### Promotional text (170, can be changed any time without review)

```
Hold to talk, let go to listen. Private channels and talk groups, end-to-end encrypted, with no accounts, no phone numbers and no servers of ours in the middle.
```

### Description (4000)

```
NXTPTT brings back push to talk: hold the orb, speak, and your people hear you live, with the chirp. No calls to answer, no voice notes to open.

HOLD TO TALK
• Talk live, one to one or to a whole group.
• Hear them the moment they key up, even with your phone locked, thanks to iOS Push to Talk.
• Call alerts: page someone with the classic four beeps when they aren't listening.
• Works on your Apple Watch too.

TALK GROUPS
• Make a group for your crew, family or team.
• Scan several groups at once, or mute the ones you don't need right now.
• Invite people with a QR code. The group key is never in the code: each member's key is sealed to their own device.
• See who spoke recently in each group.

PRIVATE BY DESIGN
• End-to-end encrypted. Every transmission uses a fresh key.
• No accounts, no phone numbers, no sign-up.
• Connects directly: nearby over peer-to-peer Wi-Fi and Bluetooth, or across the internet phone to phone.
• If someone can't be reached, the message waits for them encrypted in iCloud and is deleted after pickup or within a day.
• Optical handshake: hold two phones screen to screen and they swap keys by light, both ways at once. Or send a link.

YOUR MESSAGES, YOUR CALL
• Choose whether the people you talk to may replay your message. Replays are limited to the last message and expire after an hour.
• See how each transmission was delivered: nearby, Wi-Fi, internet or iCloud relay.

NXTPTT has no ads, no tracking and no analytics.
```

### Keywords (100, comma-separated, no spaces after commas)

```
walkie,talkie,ptt,radio,intercom,group,voice,encrypted,private,chirp,crew,team,two-way,family,hiking
```

### Support URL / Marketing URL / Privacy Policy URL

All three need public web pages. See `SUBMISSION_GUIDE.md`, step 2, for a free way to
publish `docs/PRIVACY.md` and a support page.

### Copyright

```
2026 <your legal name or company>
```

### What's New (for later updates only; not shown for 1.0)

## Screenshots

| Slot in App Store Connect | Files |
| --- | --- |
| iPhone 6.9" Display | `iphone-6.9/1-talk.png` … `6-face.png` (1320 × 2868) |
| iPad 13" Display | `ipad-13/1-talk.png` … `5-face.png` (2064 × 2752) |
| Apple Watch (Series 10/11, 46 mm) | `watch/1-idle.png`, `watch/2-rx.png` (416 × 496) |

Apple scales the 6.9" set down for smaller iPhones and the 13" set for smaller iPads, so
these are the only sizes required. Upload in the numbered order: the first three show up in
search results.

To change a screenshot, edit `src/screens.html` and run `node src/render.mjs` (needs Node and
Playwright).

## App Review information (version page, bottom)

| Field | Value |
| --- | --- |
| Sign-in required | No (untick) |
| Contact | your name, phone and email |
| Notes | the text below |
| Attachment | optional: a short screen recording of two phones talking (strongly recommended) |

### Notes for the reviewer

```
NXTPTT is a push-to-talk walkie-talkie. There is no account or sign-in.

Testing needs two devices with NXTPTT installed (two iPhones, or an iPhone and an iPad):
1. On first launch, enter any name.
2. Pair them: on both devices open Pair → OPTICAL HANDSHAKE and hold the screens together, tops touching, about 15–20 cm apart, until both show the same safety code.
3. Go to Talk, hold the orb on one device and speak; the other device plays it live with a chirp. It also plays when the receiving device is locked, through the Push to Talk framework.
4. Channels → + creates a talk group; the QR button on a group invites others.

Background modes:
- push-to-talk and audio: used only to receive and play a transmission through Apple's PushToTalk framework, and while the user holds the talk button.
- remote-notification: receive end-to-end encrypted messages left in the iCloud relay when a device was unreachable.

Permissions: the microphone is used only while the talk button is held. The camera is used only for the optical handshake and to scan talk group codes, processed on the device.

Encryption: all cryptography is Apple's CryptoKit; see the export compliance answer in the build.

A screen recording of two phones using the app is attached.
```

## App Privacy (App Store Connect → App Privacy)

Answer **"No, we do not collect data from this app."** Reasoning, in case Apple asks:

- There are no accounts, analytics, advertising or tracking, and no servers run by us.
- Voice and messages are end-to-end encrypted between users' devices. When they pass through
  iCloud (the relay) or Apple Push Notifications, neither we nor Apple can read them, and relay
  copies are deleted after pickup or within 24 hours.
- Contact details (name, public keys, network addresses, push tokens) go only to the people a
  user pairs with, never to us.
- To find a direct route between phones, the app asks STUN servers (Google, Cloudflare) for
  its public address. They see an IP address for that request only; nothing is stored for us
  or linked to the user.

Privacy Policy URL is still required: publish `docs/PRIVACY.md` (guide, step 2).

## Age rating questionnaire

Answer honestly; for NXTPTT that is:

- Violence, sexual content, profanity, drugs, gambling, horror, medical: **None**
- Unrestricted web access: **No**
- Messaging and chat (users can communicate with each other): **Yes**
- User-generated content shared publicly: **No** (only with people you pair with)
- Age assurance / parental controls: **No**

Apple then assigns the rating (expect 13+ because of user-to-user voice chat).

## Pricing and availability

- Price: **Free** (USD 0.00, Tier 0)
- Availability: all countries, or leave out countries where you'd rather not answer
  encryption questions (France is no longer a problem: the build declares its encryption).
- Distribution: Public on the App Store.
