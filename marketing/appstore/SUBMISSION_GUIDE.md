# Publishing NXTPTT to the App Store: step by step

Everything to type or upload is in `LISTING.md` (same folder). Screenshots are in
`iphone-6.9/`, `ipad-13/` and `watch/`. App Store Connect is at
<https://appstoreconnect.apple.com>.

Your app record already exists (TestFlight uploads created it), so you won't need
"New App".

---

## 1. Account housekeeping (once)

1. **Agreements:** App Store Connect → **Business** (or "Agreements, Tax, and Banking").
   The **Free Apps** agreement must be **Active**. For a free app you don't need banking or
   tax forms.
2. **EU trader status (Digital Services Act):** Business → your account → **Compliance** →
   declare whether you are a **trader** (you make money from the app or it's part of a
   business) or **non-trader** (hobby project). If you're a trader, your address, phone and
   email appear publicly on the EU App Store. If you don't do this, the app won't be offered
   in the EU.

## 2. Put the privacy policy and support page online

Apple needs two public web addresses. The text is ready in `docs/PRIVACY.md` and
`docs/SUPPORT.md`. First replace `<your support email>` in both.

Pick one way to publish them:

- **GitHub Pages** (if the ePTT repository is public, or you're on a paid GitHub plan):
  repository **Settings → Pages** → Source: **Deploy from a branch** → Branch **main**,
  folder **/docs** → Save. After a minute the pages are at
  `https://coral-coder.github.io/ePTT/PRIVACY` and `…/SUPPORT`.
- **Any free public page** (Google Sites, Notion "Share to web", Carrd): paste each file's
  text into its own page and publish it.

Open both links in a private browser window to make sure they load without signing in.

## 3. Decide the version number

App Store Connect's version must match the build's version. The current builds are
**0.1.3**. Choose one:

- **Launch as 1.0.0 (recommended):** tell me **"v1.0.0"** and I'll tag it; CI uploads
  **1.0.0 (1)** to TestFlight. Use "1.0.0" as the App Store version below.
- **Launch as 0.1.3:** on the version page, change the version to **0.1.3** and use the
  latest 0.1.3 build.

## 4. App Information (left sidebar → General → App Information)

1. **Name:** `NXTPTT: Push to Talk`. If Apple says it's taken, use the alternatives in
   LISTING.md.
2. **Subtitle:** `Encrypted walkie-talkie`
3. **Category:** Primary **Social Networking**, Secondary **Utilities**.
4. **Content Rights:** "No, it does not contain, show, or access third-party content."
5. **Age Rating → Edit:** answer as in LISTING.md (no mature content; **Yes** to messaging
   and chat between users). Save.
6. Save the page (top right).

## 5. Pricing and Availability (sidebar)

1. **Price:** Free (USD 0.00).
2. **Availability:** All countries or regions (or untick any you don't want).
3. Save.

## 6. App Privacy (sidebar)

1. **Privacy Policy URL:** the PRIVACY link from step 2 → Save.
2. **Data Collection → Get Started:** choose **"No, we do not collect data from this
   app"** → Save → **Publish**.

## 7. The version page (sidebar → iOS App → 1.0 Prepare for Submission)

1. **Version** (top, if it doesn't match your build): 1.0.0 or 0.1.3, from step 3.
2. **Previews and Screenshots:**
   - **iPhone 6.9" Display:** drag in `iphone-6.9/1-talk.png` … `6-face.png`, in order.
   - **iPad 13" Display:** drag in `ipad-13/1-…` … `5-face.png`.
   - **Apple Watch:** drag in `watch/1-idle.png` and `watch/2-rx.png`.
   - Leave the other sizes empty; Apple scales these down.
3. **Promotional Text**, **Description**, **Keywords:** paste from LISTING.md.
4. **Support URL:** the SUPPORT link. **Marketing URL:** optional, leave it blank.
5. **Version:** as above. **Copyright:** `2026 Your Name`.
6. **Build:** click **+ / Add Build** and pick the newest build. The export compliance
   question won't appear, because the build already answers it.
7. **Game Center:** off. **Routing App Coverage:** none.
8. **App Review Information:**
   - Sign-in required: **untick**.
   - Contact: your first and last name, phone and email.
   - **Notes:** paste the reviewer notes from LISTING.md.
   - **Attachment:** a 30–60 second screen recording showing two phones pairing and talking
     (start a screen recording on one phone, or film both). This is the single biggest help:
     reviewers often have only one device and will otherwise reject with "unable to test".
9. **Version Release:** "Manually release this version" (you choose the moment once it's
   approved) or "Automatically release".
10. Click **Save** (top right).

## 8. Submit

1. Top right: **Add for Review** → **Submit to App Review**.
2. Status becomes **Waiting for Review**, then **In Review**. Typically 1–2 days.
3. You'll get an email when it's approved or rejected. If you chose manual release, press
   **Release This Version** when you're ready.

## 9. If Apple rejects it

Reply in **App Review → Messages** (Resolution Center), or send me the rejection text and I'll
draft the reply or fix the app. The most likely points for this app:

- **2.1 (couldn't test):** reviewers had one device. Attach the video and offer a call.
- **2.5.4 (background modes):** explain that push-to-talk and audio are used only to receive
  and play transmissions through Apple's PushToTalk framework (already in the notes).
- **5.1.1 (privacy):** point them to the policy and the "Data Not Collected" answer.
- **Name:** if another app or trademark conflicts with "NXTPTT", pick a different name.

## 10. After launch

- Keep releasing to TestFlight as usual ("b u"). For an App Store update, bump the version
  (tell me e.g. "v1.0.1"), then on App Store Connect click **+** next to "iOS App" to make the
  new version, add the build, fill in **What's New**, and submit.
- Screenshots and text carry over to each new version unless you change them.
