# MatchMe — Privacy Policy

**Effective date:** 1 October 2026
**Version:** 1.0
**Status:** Draft — requires review by a qualified lawyer before launch.

---

## 1. The short version

MatchMe connects people who happen to be in the same place, or who are going to the same event, based on what they are looking for and what they are interested in. We match you in the background. You do not browse or swipe.

We designed the service around a simple idea: **we should not keep your location.**

- Live location is deleted within minutes, not months.
- Exact coordinates are never attached to a match.
- The detailed trail that would let us build a history of your movements is **off by default**, opt-in, and capped at 72 hours.

We do run automated checks on your photos, and that necessarily involves sending them to a third-party vision service. We tell you exactly what that involves in section 6.

---

## 2. Who we are

MatchMe is a service for meeting people in person. It is **not a dating app** in the sense that you might expect: there is no browsing, no swiping, and no feed of strangers. We match you with people based on shared intents and shared interests, combined with either physical proximity at the same time, or attendance at the same future event.

People use MatchMe for different reasons — to meet a romantic partner, a new friend, someone to go to an activity with, or a professional contact. What you are looking for is yours to choose and yours to keep private.

---

## 3. What we collect

### 3.1 Information you give us

- **Account details:** name, date of birth, gender, preferred language, email address, and the sign-in method you chose (email and password, email code, Google, Microsoft, Apple, Facebook, or a passkey).
- **Profile content:** your photo(s), bio, interests, the kinds of connections you are looking for, and optionally details about lifestyle, family, religion, languages, height, education, occupation, and social links.
- **Events:** the events you add to your calendar, so we can tell when you and someone else will be in the same place at the same time.
- **Messages:** the content of chats you send and receive.
- **Support and safety reports:** if you report or block another user, we store that.

### 3.2 Information collected automatically

- **Location**, while the app is running and while background location is enabled. See section 4 — this is the most important section in this policy.
- **Device and session information:** a session record containing an identifier, the device platform, and a push-notification token. We use the push token to deliver notifications to that device. It is removed when the session is revoked or when you delete your account.
- **Approximate location from your IP address,** used to estimate your time zone and default map area. This is derived by our hosting provider from the connection, not stored as a location by us.
- **Advertising interaction events** if ads are shown to you: that an ad was shown, that it was clicked, and revenue it generated. See section 7.

### 3.3 What we do **not** collect

- We do not build a profile of your movements over time. We do not predict where you will be.
- We do not use your message content to train any machine-learning model.
- We do not sell your personal information. We do not share it for that purpose with anyone.

---

## 4. Location — the details

This section is deliberately specific. "How long do you keep my location?" deserves more than one sentence, because the honest answer has exceptions.

### 4.1 Live location: 15 minutes

While MatchMe is open, and while background location is enabled, your device sends us your position. We store one current position per user, along with speed and heading. A scheduled job deletes positions that are more than **15 minutes** old.

The matching engine only considers a user whose position was updated within the last few minutes, so a stale position cannot be used to make a match.

### 4.2 Pinned locations: up to 30 days, only if you set one

You can deliberately pin your current location as a "base" — for example, your home or your workplace — for a period you choose. If you do:

- A pin can be set for between **60 seconds and 30 days**, and the total time any single pin may live is capped at 30 days from when it was created.
- The 15-minute deletion above **does not apply to an active pin.** This is the single most important exception in this policy.
- While a pin is active, your live position does not overwrite it.
- An expired pin is deleted automatically.
- You can remove a pin at any time.

We chose to make this an explicit, visible, time-limited action rather than an automatic behaviour, because a permanent "home" location would be exactly the kind of permanent record this policy otherwise avoids.

### 4.3 The optional trail: off by default, up to 72 hours

If you turn on the optional trail, we store a record of where you have been so that we can introduce you to people you were near earlier — including while the app was closed.

- **It is off by default.** You must switch it on yourself.
- You choose how long it is kept: **between 2 and 72 hours.** The default is 24 hours.
- Points that are too inaccurate to be useful are discarded.
- If you turn the feature off, or shorten the retention period, the stored points are **deleted**, not just ignored.
- You can delete the entire trail yourself, on your device and on our servers, at any time.
- The table holding this data has no direct access for any user or client; it can only be reached through our own matching functions.

### 4.4 What a match does and does not contain

When two people are matched, we **do not** store either person's coordinates on the match. We deliberately removed those columns from our database.

A match does contain a **coarse map centre**, rounded to roughly one kilometre, and a zoom level. It is used to draw a small map without a pin. On its own, a location rounded to one kilometre does not identify a person, but we want you to know it exists.

Separately, when a match expires without either person sending a message, we keep a small history of up to three such coarse map centres for that pair, so that we can recognise a repeated encounter. **This history currently has no automatic expiry.** If you would like it erased, contact us using the details in section 12 and we will remove it.

### 4.5 Live location sharing between matches

If you and a match both choose to share your live position with each other, your position is sent directly to the other person's device over an encrypted channel, rather than being stored. The session has a visible countdown and ends when it expires or when either person ends it.

### 4.6 Permissions

MatchMe requests location permission because it cannot function without it. On Android and iOS this includes **background location**, which allows the app to find matches while it is closed. It also requests camera access (for photo capture and identity verification) and calendar access (for event matching). Each is requested at the point we need it, not all at once. You can decline any of them; declining location means MatchMe cannot match you by proximity.

---

## 5. Photos, identity verification, and face analysis

This section describes automated processing of your photographs. We think you should know about it before you upload anything.

### 5.1 Automated photo review

Every photo you upload is automatically reviewed. The image itself — the actual picture file — is sent to a third-party vision service operated by Google (the Gemini models) so that it can be checked.

That review looks for: nudity or sexual content, whether the photo appears to show a minor, whether it is a body shot rather than a face, whether it contains multiple people, whether it is a meme or generated art rather than a real photo, and whether text on the image should be obscured. Depending on the result, the photo may be accepted, rejected, or accepted with the text pixelated.

### 5.2 Identity verification

You can optionally verify your identity by taking a live selfie. Verification compares that selfie with your profile photo, so both images are sent to the same third-party service for that comparison.

- **The verification selfie is deleted 14 days after it was submitted.**
- Verification means MatchMe reviewed a selfie against your profile photo. **It does not guarantee anyone's safety or future behaviour.** Please do not treat a verified badge as a guarantee.

### 5.3 A derived face descriptor

As part of verification, the system extracts a numerical description of face geometry — proportions such as the ratio of face length to width, spacing between the eyes, and similar measurements. This is a list of numbers, not an image, and it exists to reduce fraud.

**We should be clear that this is sensitive.** It is derived from your face. It is stored on your account after verification. It is currently **not** cleared by the 14-day deletion described above, and it is cleared only if an administrator resets your verification. If you would prefer it not to be retained, ask us to remove it (section 12) or do not complete verification — verification is optional and everything else in MatchMe works without it.

---

## 6. Messages and translation

Messages between you and a match are encrypted on your device before they are sent, and are stored encrypted.

You can switch on translation for a given chat. If you do, the **text of your messages is sent to DeepL**, a third-party translation provider, in order to be translated. If you leave translation off, message text is not sent to DeepL.

We do not use your message content to train any machine-learning model.

The auto-generated translation is a machine translation and may be wrong or inappropriate. Treat it as a rough aid, not as a faithful rendering of what the other person wrote.

---

## 7. Advertising

Depending on your subscription tier, MatchMe may display advertising. Advertising is served by **Google AdMob**, and we also operate our own internal sponsored placements.

- Your ad-consent choice is recorded and is sent to Google with the ad request.
- Advertising is configured to be non-personalised by default.
- You can change your consent choice at any time.
- We do not permit behavioural advertising to users we know to be under the applicable minimum age.

Whether advertising is shown to you may depend on your subscription tier. This is configured on our side and may change; we will not remove advertising from a paid plan without notice.

We do not use your precise location to target advertising.

---

## 8. Who we share your information with

We share the minimum necessary with the following categories of provider. Each is subject to a contractual confidentiality obligation.

| Provider | What it does | What it receives |
|---|---|---|
| **Supabase** | Hosting: database, authentication, file storage, real-time messaging, and the backend functions that run our matching | Everything we hold, because it is our infrastructure. Live shared location passes through its real-time layer in transit |
| **Google Firebase Cloud Messaging** | Delivers push notifications | Push notifications and your device's push token |
| **Google AdMob** | Serves advertising | Ad requests and your consent choice, plus data the ad network receives under its own policy |
| **Google Gemini** | Automated photo review, bio review, and identity verification | Your photos and verification selfies, as image data; your bio text |
| **DeepL** | Message and notification translation, only where you or the app have enabled translation | Message or notification text |
| **Resend** | Sends transactional email, including verification codes | Your email address; for some messages, a display name and a match identifier |
| **Cloudflare Turnstile** | Bot protection | The CAPTCHA token generated by the widget |
| **OpenStreetMap** | Map tiles and address search | Map tile requests (which reveal the area you are viewing) and address search queries |
| **Google, Microsoft, Apple, Facebook** | Sign-in via OAuth, if you use it | The identity details those providers return to us |
| **Calendar providers** (Google Calendar, Outlook, device calendar) | Reads events you have linked, for event matching | Calendar access; credentials are cleared when you delete your account |

We do not sell your personal information, and we do not disclose it to third parties for their own marketing purposes.

**International transfers.** Some of these providers process data outside your country. Where that happens, transfers rely on an appropriate safeguard, such as standard contractual clauses.

---

## 9. How long we keep things

| Data | Retention |
|---|---|
| Live location | 15 minutes |
| A pinned location | The period you choose, up to 30 days from creation |
| The optional trail | 2 to 72 hours, as you choose; deleted immediately if you turn it off |
| Verification selfie | 14 days |
| Face geometry descriptor | Until you ask us to remove it, or an administrator resets your verification |
| Chat messages | Until you delete them, unmatch, or delete your account |
| Coarse map centre on a match | For as long as the match exists |
| Coarse encounter history for expired matches | **No automatic expiry at present** — ask us and we will remove it |
| Account | Until you delete it, then removed from our active systems |

**Deleting your account.** You can delete your account yourself from Settings. Deletion requires you to be online and to re-confirm your identity. It removes your profile and photos from our storage, ends your sessions, clears your locally stored data, and requests deletion of your records on our side.

---

## 10. Your rights

Depending on where you live, you may have the right to:

- access the personal data we hold about you
- correct data that is inaccurate
- delete your account and data
- restrict or object to certain processing
- receive a copy of your data in a portable format
- withdraw consent, where we rely on it
- complain to your local data protection authority

**To exercise any of these, use the in-app controls where they exist (deleting your account, deleting your trail, changing your consent choice, blocking or reporting a user) or contact us using the details in section 12.**

We will respond within a reasonable time, and we aim to complete requests within 30 days.

Two things we want to be straightforward about:

- **We do not currently offer a self-service export of your data.** If you would like a copy, contact us and we will provide one.
- **If we receive a report about a user, we record it, but we cannot promise that a human being will review it.** We are honest about this rather than implying a moderation team that we have not described.

---

## 11. Security

We use encryption in transit. Your locally stored data is encrypted on your device. Messages are encrypted before they are sent. Sensitive actions such as changing your email or password require a code sent to your account email or a passkey confirmation.

No system is perfectly secure. If a breach affects your data, we will notify you and the relevant regulator as required by law.

If you are a security researcher, please report vulnerabilities to us rather than exploiting them or accessing other people's data.

---

## 12. Contact us

For any privacy question, data request, or to ask us to delete something we hold about you, contact us at:

**privacy@matchme.app**

When contacting us about a specific piece of data, please tell us the email address or account identifier on the account. We may ask you to confirm your identity before acting on a request.

---

## 13. Children

**MatchMe is not intended for anyone under 18, and we do not knowingly permit anyone under 18 to create an account.** The age requirement is checked when you complete your profile.

We know this is not the same as enforcing it technically, and we will not pretend otherwise. If you believe a child has created an account, contact us and we will remove it.

---

## 14. Changes to this policy

We may update this policy. When we make a material change we will notify you in the app before the change takes effect. We will keep a record of the version number and effective date at the top of this document.

---

<!-- matchme:internal-notes-end -->

## Appendix — Drafting notes (remove before publication)

1. **Requires lawyer review before launch.** Do not publish as-is.
2. **Section 9 — no automatic expiry for expired-match encounter history.** `unmatched_pairs.locations_history` has no TTL and no user-facing delete. The recommended fix is to replace coordinates with a coarse class label, add a 30-day TTL, and add a "forget this match" control. Until then, this section must keep the admission, and section 10's promise to honour deletion requests becomes a manual operational commitment.
3. **Section 5.3 — face geometry descriptor outlives the selfie.** The 14-day cleanup nulls `verification_photo_path` but not `verification_reference_artifact`. Either extend the cleanup or commit to the removal request in this section.
4. **Section 5.2 and 5.3 — the "we do not retain the image" framing is accurate for the photo, not the descriptor.** Keep the two clearly separated.
5. **Section 7 — "may depend on your subscription tier" is config state, not code.** The migrations disagree with each other about which tiers see external ads. Read the live `app_config` table before this becomes a promise.
6. **Section 13 — the 18+ gate is client-side only.** There is no database constraint. Consider adding a server-side check before publication, and then delete this appendix note.
7. **Section 6 — confirm whether chat translation can be enabled without the user asking.** If it can be switched on server-side, the disclosure must say so.
8. **Section 4.2 — pinned locations are the largest exception to the "15 minutes" headline.** Do not shorten this section in editing. Consider whether 30 days is the right cap at all.
9. **Localisation.** Legal text is currently English only. Several jurisdictions require a localised version for users in that jurisdiction. This is a separate decision, not a translation-table task, and needs review per locale.
10. **Section 10 — no self-service data export exists in code.** Either build it or keep the honest wording here.
