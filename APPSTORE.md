# Feder → App Store checklist

Feder is free. State in October 2026 (corrected against Apple's pages and the code on 2026-10-07): usage descriptions (microphone, location, calendar), `UIBackgroundModes: audio`, `ITSAppUsesNonExemptEncryption: false`, the launch screen, the icon and the 8 GB gating for Gemma are done. **No signed Release build has ever been made**: the only Release product (Oct 3) is unsigned and still says "Scribe". The bundle id `de.cofinpro.recorder` and `PRODUCT_NAME` `Recorder` never change.

Status: **[done]** is in the app; **[this change]** is being added now; **[open]** is for you (or a later code change). Nothing here is legal advice; have a lawyer confirm the legal items.

## 1. Read first (Apple), in this order

1. **App Review Guidelines**: https://developer.apple.com/app-store/review/guidelines/
   - **2.1** App completeness: the reviewer must get through the main flow on their device (see the review notes in §6).
   - **2.3** Accurate metadata: 2.3.1 (say "Requires iPhone 12 or later"), 2.3.3 screenshots show the app in use, 2.3.7 name ≤ 30 characters, no trademarks or keyword stuffing.
   - **2.5.4** Background modes only for their purpose: `audio` keeps an ongoing recording, nothing after Stop.
   - **2.5.14** Recording: explicit consent and a clear indicator while recording.
   - **4.2.3(ii)** "If your app needs to download additional resources in order to function on initial launch, disclose the size of the download and prompt users before doing so."
   - **4.3(b)** (June 2026): apps indistinguishable from what is widely available are rejected as spam; transcription is crowded, so the review notes say what sets Feder apart.
   - **5.1.1(i)** Privacy policy link in App Store Connect **and** in the app; **5.1.1(iv)** respect permission settings, offer alternatives (recording works without location or calendar), and no custom screen before a permission alert that lets the user leave without seeing the alert (Feder has none: calendar access is asked from its Settings switch).
   - **5.1.2(i)** Disclose and get permission for sharing personal data with third parties, "including with third-party AI" (Nov 2025). Feder runs Gemma on the device, so nothing is shared.
   - Also relevant: 2.4.1 (iPhone apps should run on iPad), 2.5.2 (no downloaded code; model weights are data), 5.2.1 (third-party trademarks).
2. **Xcode, Preparing your app for distribution**: https://developer.apple.com/documentation/xcode/preparing-your-app-for-distribution
3. **Xcode, Distributing your app for beta testing and releases**: https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases
4. **Privacy manifest and required-reason APIs** (uploads are refused without them since May 1, 2024):
   - https://developer.apple.com/documentation/bundleresources/privacy-manifest-files
   - https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api
5. **App Privacy details** ("collect" means sent off the device and kept): https://developer.apple.com/app-store/app-privacy-details/
6. **App Review overview and common rejections**: https://developer.apple.com/distribute/app-review/
7. **EU DSA trader status**: https://developer.apple.com/help/app-store-connect/manage-compliance-information/manage-european-union-digital-services-act-trader-requirements/
8. **Age rating**: https://developer.apple.com/help/app-store-connect/manage-app-information/set-an-app-age-rating/ and https://developer.apple.com/help/app-store-connect/reference/app-information/age-ratings-values-and-definitions (4+/9+/13+/16+/18+ since July 2025; social-media questions required for submissions since September 2026).
9. **Screenshot specifications**: https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications
10. **Metadata fields**: https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information and https://developer.apple.com/help/app-store-connect/reference/app-information/app-information
11. **TestFlight**: https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/ (100 internal testers without review; builds expire after 90 days).
12. **Export compliance**: https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance/
13. **HIG** for the onboarding and AI work: Privacy (pre-alert screens: one "Continue" button) https://developer.apple.com/design/human-interface-guidelines/privacy, Onboarding https://developer.apple.com/design/human-interface-guidelines/onboarding, Generative AI (label AI output, say it can be wrong, allow retry or removal) https://developer.apple.com/design/human-interface-guidelines/generative-ai
14. **Only if tips ship**: agreements https://developer.apple.com/help/app-store-connect/manage-agreements/sign-and-update-agreements/, tax https://developer.apple.com/help/app-store-connect/manage-tax-information/provide-tax-information/, banking https://developer.apple.com/help/app-store-connect/manage-banking-information/enter-banking-information/, and https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-in-app-purchase/ (the first In-App Purchase goes in with an app version).
15. Later: upcoming requirements https://developer.apple.com/news/upcoming-requirements/ (Xcode 27.0 and 27.1 RC are both accepted now; the iOS 27 SDK and iPhone Duo screenshots become required from April 2027), Apple-hosted asset packs https://developer.apple.com/help/app-store-connect/manage-asset-packs/overview-of-apple-hosted-asset-packs/

## 2. Launch checklist

### In the app

- [ ] **[this change] Privacy manifest** `Recorder/PrivacyInfo.xcprivacy` (synced folder, ships as a resource): `NSPrivacyTracking` false, no tracking domains, no collected data types, and the required-reason APIs: UserDefaults **CA92.1**; FileTimestamp **C617.1** (`fstat` in mlx-swift's fmt and `contentModificationDateKey` in mlx-swift-lm are in the binary; the app's own `attributesOfItem` reads only the size); DiskSpace **E174.1** (the 4 GB check before Gemma, and mlx-swift-lm). Add 85F4.1 only if free space is ever shown to the user. The packages are linked statically and ship no manifests, so the app's manifest covers them. After archiving: check `Recorder.app/PrivacyInfo.xcprivacy`, Organizer › Generate Privacy Report, and watch for an ITMS-91053 email naming a missing category.
- [ ] **[this change] In-app Privacy Policy and Legal Notice** (Impressum, § 5 DDG), EN and DE, from `Recorder/Legal.json`, reachable from Settings (5.1.1(i)). **[open]** Fill the placeholders once the account is decided: `[Provider name]`, `[Street and number]`, `[Postcode and city]`, `[Email]`, `[Phone]`, `[Supervisory authority]`, `[Privacy policy URL]`, the data protection officer line; for a company also `[Managing directors]`, `[Register court and number]`, `[VAT ID]` (drop those three sections for a personal account), and confirm or drop the consumer dispute resolution sentence.
- [ ] **[this change] Acknowledgements page** in Settings. Required for code compiled into the binary (MIT/BSD notices, Apache-2.0 text and NOTICE files); recommended for the downloaded models (Feder ships no weights; they come from the licensors' own repositories). Facts in §3.
- [x] **[done] Gemma gating**: offered only when `physicalMemory ≥ 7e9` (every 8 GB iPhone, not only the iPhone 17), needs 4 GB free, background `URLSession` with cellular, expensive and constrained networks off.
- [x] **[done] Usage descriptions, background audio, export key, launch screen, icon.**
- [ ] **[open] German purpose strings**: all three (microphone, location, and calendar from Name from Calendar) need a German review in `InfoPlist.xcstrings`; five keys in `Localizable.xcstrings` have no German (e.g. "%@ Speakers"). Consider saying in the location string that the place name is looked up with Apple Maps. Every new onboarding, legal and Settings string needs German.
- [ ] **[open] `Recorder/Saved state!.icon`** is untracked and sits in the synced folder, so the next archive would ship it. Remove it or move it out of `Recorder/` before archiving; check the archive has only `AppIcon`.
- [ ] **[this change] Download rules and the Save Location switch** (`NetworkPath`, onboarding, Settings › Recording), as decided for this release: pyannote/WeSpeaker 21 MB after the Welcome screen on any network; LS-EEND 45 MB and Nemotron 100 MB start automatically on Wi-Fi only (a download started on Wi-Fi may finish over cellular: FluidAudio's session can't be configured from outside), or on cellular after "Download Now Using Cellular"; Gemma 3.6 GB and Parakeet 610 MB only on request. **[open]** Before submitting, check that the final code matches `Legal.json`, the review notes and the description, and that the welcome page states the sizes before anything downloads (4.2.3(ii)).
- [ ] **[this change] Pin the model revisions, where FluidAudio allows it**: `AppServices.modelRevisions` → `ModelRegistry.revisionOverrides` pins `FluidInference/ls-eend-coreml` to `28ce1b1f8ef186729df63b3886fbaae7bc10c4a1` (`main` on 2026-10-07, the one tested). FluidAudio pins pyannote itself (`df2625ac…`). Nemotron and Parakeet Ultra stay on `main`: for a revision other than "main" FluidAudio deletes a repo folder that lacks its private `.fluidaudio-revision` marker (ModelCache.swift:43-45), so a pin made a fresh Nemotron download fail (its loader's second, root-level download wiped the bundle it had just fetched) and made existing Parakeet users download 610 MB again. Nemotron is still guarded by FluidAudio's `weightsVersion` marker. **[open]** Pinning those two needs FluidAudio to adopt an existing cache (upstream change or fork); until then re-check their repos before each release, and keep the Acknowledgements in step.
- [ ] **[open] Drop the unused NemoTextProcessing trait** (~8 MB Rust library, plus NOTICE duties for NeMo, rustfst, flate2 and others). FluidAudio documents `.package(url: …, traits: [])`. The installed XcodeGen 2.46.0 has a `traits` field for packages (seen in its binary; not tried): try `traits: []` on FluidAudio in `project.yml`, regenerate, and check that `libtext_processing_rs.a` is gone. If it can't be turned off, show its NOTICE and THIRD-PARTY-LICENSES on the Acknowledgements page.
- [ ] **[this change] Settings › Transcription footer** no longer says "Apple Speech needs no download" (iOS may download Apple's speech model at the first recording in a language).
- [ ] **[this change] Voice profiles are optional**: Settings › People › "Recognize People by Voice" (on by default). Off, no voice profiles are computed or kept and nobody is recognized; turning it off deletes all existing profiles after a confirmation. The onboarding's Before You Record and the privacy policy say so (GDPR Art. 9: biometric data in professional use).
- [ ] **[this change] AI label** (HIG Generative AI): every transcript says "AI-generated content can contain mistakes." under its date line and summary (words, speakers and recognized names are generated too, so a caption on the summary alone was misleading). **[open]** A regenerate or remove action for the summary.
- [ ] **[this change] Recording-consent note**: the onboarding's Before You Record page (one balanced screen, a single Continue, once for everyone): ask people before recording them (§ 201 StGB); voices are remembered on this iPhone (a voice profile of everyone it hears; delete a person and their transcripts to forget a voice); automatic results can be wrong; a Privacy Policy link.

### Build, device and TestFlight

- [ ] **[open] First signed Release archive** (Product › Archive, Release) with the released Xcode 27.0 (or 27.1 RC), when no other session is building. Check `codesign -d --entitlements -` on the archived app shows `com.apple.developer.kernel.increased-memory-limit` in the distribution profile (never verified), that every QA hook compiles out under `#if DEBUG`, and that MLX's Metal shaders work in Release.
- [ ] **[open] Build numbers**: `CURRENT_PROJECT_VERSION` is fixed at "1"; every upload needs a new one. Let Organizer manage it or bump it per upload. `MARKETING_VERSION` 1.0.
- [ ] **[open] TestFlight on the iPhone 17** (internal, a week of real use): the first Release run of MLX and FluidAudio on a device. On a fresh install check: no speech-recognition prompt and no crash (SpeechAnalyzer without `NSSpeechRecognitionUsageDescription` is observed, not documented); the first recording and a language switch in airplane mode; the background state of a recording; the audio session goes inactive after Stop (2.5.4).
- [ ] **[open] Full UI suite** on both runtimes once (`build/qa/uitests.sh`).

### App Store Connect

- [ ] **[open] DSA trader status**: Feder publishes under the personal account timtody (team GL55J24MCR, bundle id `de.timtody.feder`, decided 2026-10-08). Declare the trader status in App Store Connect › Business early (verification can take weeks). As a non-trader (free, no In-App Purchases, no business purpose) nothing is shown; as a trader Apple shows address, phone and email on the EU product page, and allows a P.O. box for individuals there. Tips would very likely make Feder a trader, which is one more reason to ship 1.0 without them.
- [ ] **[open] App record**: name "Feder" (check it is free when you create the record), primary language German, category Productivity (secondary Business), English and German localizations (§5).
- [ ] **[open] Impressum (§ 5 DDG)** in `Legal.json` › legalNotice, shown in the app (Settings › About › Legal Notice: two taps, works offline) and to be put on the support page, so it can be read before the download (e-recht24's app guidance: at most two clicks, online and offline). It needs the full first and last name (the account name timtody alone is not enough), a *ladungsfähige Anschrift* (a street address where court and official mail can be served; a P.O. box is not enough), so not the private address: use the c/o address of an Impressum or mail-forwarding service, and an email plus a second quick contact (phone or contact form). The privacy policy names the publisher with name and email and points to the Impressum.
- [ ] **[open] Privacy policy URL**: host the same text as `Legal.json` (EN and DE) at a public URL and enter it; put the Impressum on the support page too. **Support URL** with real contact details (required).
- [ ] **[open] App Privacy**: "Data Not Collected" (No to "Do you or your third-party partners collect data?"). Reasons: everything is processed on the device; the Hugging Face downloads carry no identifier or token and the IP address only serves the file; data Apple collects (MapKit, App Store) is not yours to disclose.
- [x] **[done] Export compliance**: `ITSAppUsesNonExemptEncryption = false` (HTTPS via `URLSession`, CryptoKit hashing; no BoringSSL in the binary). Recheck if an encryption library is added.
- [ ] **[open] Age rating questionnaire**: answer every section, Social Media: No. Expect 4+ (no web access, no user-generated content shared with others, no chat, no ads).
- [ ] **[open] Content Rights**: the app downloads third-party content (model weights under open licences, §3); answer accordingly.
- [ ] **[open] Screenshots**: the only required iPhone size is 1206×2622 (or 1179×2556); take them on the iPhone 17 iOS 27 simulator with seeded transcripts, in EN and DE, PNG without alpha, 1–10. 6.9" is optional.
- [ ] **[open] Availability**: deselect **China mainland** (needs an ICP filing and approval for generative AI). Decide **Mac (Apple silicon) and Apple Vision Pro**: on by default, untested (microphone, background audio, MLX, the 8 GB check), so deselect for 1.0 unless tested. Reviewers may also run the iPhone app on an iPad (2.4.1).
- [ ] **[open] Description**: "Requires iPhone 12 or later" (SpeechTranscriber is unavailable on iPhone 11 and SE 2, which iOS 26 still supports; the app installs there and can't record) and "Titles and summaries need an iPhone with at least 8 GB of memory". No "Gemma", "Google" or "NVIDIA" in the name, subtitle or keywords (descriptive use in the app is fine).
- [ ] **[open] Release**: manual release for 1.0; phased release for updates.
- [ ] **[open] Legal review by a lawyer**: the Impressum and the privacy policy (placeholders, the legal-basis paragraph, whether the model and place-name requests are attributable to the provider, the consumer-dispute sentence), and the **EU AI Act Art. 50(2)** question: machine-readable marking of AI-generated text applies since 2 Aug 2026; Feder launches after that, so no grace period; are on-device titles and summaries of the user's own transcript an "assistive function" that does "not substantially alter the input data"? Cheap hedge: the AI label above.

### Optional, not for 1.0

- [ ] **Tips (StoreKit 2)**: not implemented. Needs the Paid Apps Agreement (Account Holder only), tax and banking, and the In-App Purchases submitted with an app version (3.1.1; 2.3.2 mention purchases in the description). Check the US state age-assurance laws (Texas SB2420 is enforceable while the appeal runs) before selling in the US. The privacy policy already has a neutral sentence (Apple processes purchases); App Privacy stays "Data Not Collected". Recommendation: ship 1.0 without tips.
- [ ] **Apple-hosted Background Assets** for 1.1: on-demand asset packs instead of Hugging Face (iOS 26+, 200 GB and 200 packs per app, reviewed, testable from Xcode 27). No third-party server, a simpler privacy policy, system-managed downloads.
- [ ] Storage overview in Settings (disk use per model; Delete for Parakeet and Nemotron too; Gemma has it). Add 85F4.1 to the manifest if it shows free space.
- [ ] Accessibility Nutrition Labels (voluntary for now).
- [ ] Later, Apple-only crash signals via MetricKit (no third party).

## 3. Licences (corrected)

Gemma needs **no** "I agree" step. Attribution goes on the Acknowledgements page; no licence asks for anything in the onboarding or the listing.

| Model | Repository downloaded | Licence | Credit |
|---|---|---|---|
| Gemma 4 E2B (titles, summaries) | `mlx-community/gemma-4-e2b-it-4bit` @ `2387675…` (pinned) | **Apache-2.0** (Google). The Gemma Terms of Use scope themselves away from Gemma 4; the mlx-community card's `license: gemma` tag is stale | "Gemma 4 E2B by Google DeepMind, Apache License 2.0 (ai.google.dev/gemma/docs/gemma_4_license). 4-bit MLX conversion by mlx-community." Don't call the Prohibited Use Policy inapplicable in user-facing text. |
| Nemotron 3 Diarization (speakers after Stop) | `FluidInference/nemotron-3-diarization-coreml` (main; not pinned, see §2) | **OpenMDW-1.1** (not the "NVIDIA Open Model License") | "NVIDIA Nemotron 3 Diarization by NVIDIA, OpenMDW License Agreement v1.1 (openmdw.ai/license/1-1). Core ML conversion by Fluid Inference." + full text |
| pyannote community-1 + WeSpeaker + BUT PLDA (speakers, voices) | `FluidInference/speaker-diarization-coreml` @ `df2625ac…` (pinned) | **CC-BY-4.0, scoped** to the files Feder loads (NOTICE.md) | Name pyannote, WeSpeaker, BUT Speech@FIT and Fluid Inference, link CC-BY-4.0, say the files are modified Core ML conversions; citations Plaquet & Bredin (INTERSPEECH 2023), Wang et al. (Wespeaker, ICASSP 2023), Landini et al. (VBx, CSL 2022) |
| LS-EEND `dih3` (live labels) | `FluidInference/ls-eend-coreml` @ `28ce1b1…` (pinned) | **MIT**, © 2023 Audio-WestlakeU | LS-EEND by Di Liang and Xiaofei Li (Westlake University); Core ML conversion by Fluid Inference |
| Parakeet **Ultra** (optional transcription) | `FluidInference/parakeet-ultra-coreml` (main; not pinned, see §2) | **CC-BY-4.0** | "Parakeet Ultra by Moondream, based on NVIDIA parakeet-tdt-0.6b-v3; converted to Core ML (modified) by Fluid Inference. CC BY 4.0." |

Compiled into the binary (required): FluidAudio 0.17.4 (Apache-2.0) with everything in its `ThirdPartyLicenses/` (fastcluster BSD-2, VBx port Apache-2.0 © BUT Speech@FIT, NemoTextProcessing with its NOTICE unless the trait is off, JapaneseG2P and KokoroAneSpanishFrenchG2P: Misaki Apache-2.0, cutlet MIT, Convert-Numbers-to-Japanese MIT); mlx-swift 0.32.3 (MIT) with mlx (MIT © Apple), mlx-c, PocketFFT (BSD-3), metal-cpp (Apache-2.0), nlohmann/json (MIT); mlx-swift-lm 3.32.3 (MIT); swift-transformers 1.3.4, swift-huggingface 0.12.0, swift-jinja 2.5.1 (Apache-2.0); swift-crypto 4.5.2 (Apache-2.0, **NOTICE.txt verbatim**); EventSource 1.5.1 and yyjson 0.12.0 (MIT); swift-collections and swift-numerics (Apache-2.0 with the runtime exception; listing them does no harm). Not shipped: swift-asn1, swift-syntax. Open questions for Fluid Inference: the Mandarin G2P ports have no licence file, and the bundled LuxTTS lexicon (`luxtts_en_us_lexicon.tsv.zz`, from espeak-ng pronunciations) has no stated licence; both are TTS code Feder never uses and the trait does not remove.

## 4. Network facts the texts rely on

- Hugging Face (huggingface.co and its CDN) sees the IP address, the requested file and ordinary connection data; no account, token, identifier or telemetry is sent.
- Apple: the speech model for a language (downloaded by iOS) and MapKit reverse geocoding of the recording location, once per recording: at Start, for the first recording at Stop, when iOS asks for location (only with location allowed; "Save Location" turns it off, and turned off before Stop the running recording saves no place and nothing is looked up).
- Recordings (WAV in Documents), the SwiftData store (transcripts, summaries, people, voice profiles, tags, places) and UserDefaults are in the iOS/iCloud backup like other app data; the model folders are excluded from backup (`FluidAudioDiarizer.swift`, `GemmaDownload.swift`).
- Sizes: the Release build was 67 MB with 31 MB of `__TEXT` (limit 500 MB for iOS 9+, 4 GB uncompressed); no weights are bundled.

## 5. App Store texts (draft)

| Field | Limit | EN | DE |
|---|---|---|---|
| Name | 30 | Feder (5) | Feder (5) |
| Subtitle | 30 | Private on-device transcripts (29) | Transkribieren auf dem iPhone (29) |
| Keywords | 100 bytes | `transcription,speech to text,meeting,notes,speaker,dictation,interview,minutes,lecture,summary,voice` (100) | `Transkription,Sprache zu Text,Meeting,Protokoll,Sprecher,Diktat,Notizen,Interview,Zusammenfassung` (97) |
| Promotional text | 170 | Transcribe conversations on your iPhone, see who said what and find any word later. Your recordings and transcripts never leave your iPhone. (140) | Transkribiere Gespräche auf deinem iPhone, sieh, wer was gesagt hat, und finde jedes Wort wieder. Deine Aufnahmen und Transkripte bleiben auf deinem iPhone. (156) |

Counts are characters (keywords: bytes). The name and subtitle words are indexed already, so keywords don't repeat them.

### Description, English (1,583 characters of 4,000)

```
Feder turns what people say into text, right on your iPhone. Tap Transcribe and watch the words appear as you talk. When you stop, Feder transcribes the recording again for accuracy and works out who said what.

KNOW WHO SAID WHAT
• Speakers are told apart automatically: live while you record, and more precisely after you stop.
• Name a speaker once, and Feder recognizes their voice in later recordings.
• See every transcript a person speaks in.

FIND ANYTHING
• Search every word in all your transcripts.
• Narrow results by people and tags.
• See where a recording was made, if you allow location.

TITLES AND SUMMARIES
• On iPhones with 8 GB of memory or more, an AI model that runs on your iPhone gives each transcript a title and a short summary. Summaries can contain mistakes, so check what matters.

PRIVATE BY DESIGN
• Your recordings and transcripts never leave your iPhone. No account, no analytics, no ads.
• Feder downloads its models once: about 170 MB of speaker models (the larger ones only over Wi-Fi) and, only if you want them, a 3.6 GB summary model and a 610 MB transcription model.
• Place names come from Apple Maps, only if you allow location.

MORE
• Keeps recording when you lock your iPhone or switch apps.
• Add names and terms the transcription should get right.
• Tag transcripts and share them as text.
• Transcribes German, English and the other languages your iPhone's on-device speech recognition supports.

Please ask people before you record them.

Requires iPhone 12 or later. Titles and summaries need an iPhone with at least 8 GB of memory.
```

### Description, German (1,879 characters of 4,000)

```
Feder macht aus Gesprochenem Text, direkt auf deinem iPhone. Tippe auf „Transkribieren“ und sieh zu, wie die Wörter erscheinen, während ihr sprecht. Nach dem Stoppen transkribiert Feder die Aufnahme noch einmal genauer und erkennt, wer was gesagt hat.

WISSEN, WER WAS GESAGT HAT
• Sprecher werden automatisch unterschieden: live während der Aufnahme und genauer nach dem Stoppen.
• Gib einem Sprecher einmal einen Namen, und Feder erkennt die Stimme in späteren Aufnahmen wieder.
• Sieh alle Transkripte, in denen eine Person spricht.

ALLES WIEDERFINDEN
• Durchsuche jedes Wort in all deinen Transkripten.
• Grenze Ergebnisse nach Personen und Tags ein.
• Sieh, wo eine Aufnahme entstand, wenn du den Standort erlaubst.

TITEL UND ZUSAMMENFASSUNGEN
• Auf iPhones mit mindestens 8 GB Arbeitsspeicher gibt ein KI-Modell, das auf deinem iPhone läuft, jedem Transkript einen Titel und eine kurze Zusammenfassung. Zusammenfassungen können Fehler enthalten – prüfe, was wichtig ist.

PRIVAT VON GRUND AUF
• Deine Aufnahmen und Transkripte verlassen dein iPhone nie. Kein Konto, keine Analyse, keine Werbung.
• Feder lädt seine Modelle einmalig: etwa 170 MB Sprechermodelle (die größeren nur im WLAN) und, nur wenn du möchtest, ein Zusammenfassungsmodell mit 3,6 GB und ein Transkriptionsmodell mit 610 MB.
• Ortsnamen kommen von Apple Karten, nur wenn du den Standort erlaubst.

MEHR
• Nimmt weiter auf, wenn du dein iPhone sperrst oder die App wechselst.
• Füge Namen und Begriffe hinzu, die die Transkription richtig schreiben soll.
• Versieh Transkripte mit Tags und teile sie als Text.
• Transkribiert Deutsch, Englisch und die weiteren Sprachen, die die Spracherkennung deines iPhone auf dem Gerät unterstützt.

Bitte frag Menschen, bevor du sie aufnimmst.

Erfordert ein iPhone 12 oder neuer. Titel und Zusammenfassungen brauchen ein iPhone mit mindestens 8 GB Arbeitsspeicher.
```

## 6. App Review notes (draft, 3,056 bytes of 4,000)

```
Feder transcribes on the device. No account or sign-in; this version has no In-App Purchases.

HOW TO TEST
1. Tap Transcribe in the bar above the tab bar. iOS asks for the microphone. Speak English or German; the words appear live. Tap Stop.
2. The transcript opens. Speakers are identified after Stop. Tap a speaker label to name the person; named people are recognized in later recordings (Settings > People).
3. The Search tab finds words, people and tags.

DOWNLOADS (all are model weights, i.e. data, no executable code; no user data is uploaded)
- First recording in a language: iOS may download Apple's on-device speech model for it, with progress on the Record screen.
- After the Welcome screen: a 21 MB speaker model from huggingface.co, on any network. Until it is there, recording works and transcripts say that speakers will be identified once it has downloaded.
- Started automatically on Wi-Fi only: a 45 MB live speaker-label model and a 100 MB improved speaker model (a download started on Wi-Fi may finish over cellular if Wi-Fi drops). Started on cellular only after the user taps "Download Now Using Cellular".
- Only on request, as clearly optional improvements on the onboarding's last page (a switch each) or in Settings: Parakeet transcription (610 MB; Wi-Fi only from the onboarding, any network from Settings > Transcription) and the Gemma model for titles and summaries (3.6 GB, Wi-Fi only, background, offered only on iPhones with at least 8 GB of memory).

BACKGROUND AUDIO
UIBackgroundModes "audio" keeps an ongoing recording and its live transcription running when the screen locks or the user switches apps. It is not used after Stop.

RECORDING CONSENT AND INDICATOR (2.5.14)
Recording starts only when the user taps Transcribe, after the system microphone permission. While recording, the card and the bar's accessory show a timer, a level meter and Stop, and iOS shows its microphone indicator. Before the first recording, the onboarding's Before You Record page asks users to tell people they are recording and get their consent.

LOCATION (optional)
iOS asks for location at the first Stop, not over the live recording. If allowed, the recording's location (for the first recording, where it was stopped; later ones, where they started) is reverse-geocoded with MapKit to show a place name. A Save Location switch in Settings turns it off; denying it changes nothing else.

CALENDAR (optional)
Off until the user turns on the "Name from Calendar" switch in Settings > Recording. Only that tap asks for full calendar access. Feder then reads today's and tomorrow's events on the device, in memory only, and never changes or deletes an event: a transcript started during one of the user's events shows its title, which the user can make the transcript's name with a tap on Use as Title (someone else's event in a calendar shared read-only, and any event of a subscribed calendar, only when the user chose that calendar as Preferred Calendar), and the event's invitees' names are offered when naming speakers. Only the title and those names are stored with the transcript; nothing is sent anywhere. Denied, recording works the same (5.1.1(iv)), and the switch offers the Settings app.

AI
Titles and summaries are generated on the device by Gemma 4 E2B (Apache-2.0), running with MLX. Nothing is sent to a third-party AI service.

REQUIREMENTS
Transcription uses SpeechTranscriber, which needs an iPhone 12 or later (it is not available on iPhone 11 or iPhone SE 2nd generation). Titles and summaries need at least 8 GB of memory; on other iPhones they are not offered.

LANGUAGE
The primary language is German; the app is fully available in English and transcribes English speech on an English device.

WHAT IS DIFFERENT (4.3)
Speaker identification on the device, people recognized by voice across recordings, on-device titles and summaries, and full-text search across words, people and tags, with no account and no cloud.

Demo video: [link]
Contact: [name, phone, email]
```

## Order

1. Account decision and DSA trader status (can take weeks; start now) → fill the placeholders in `Legal.json`, host the privacy page and the support page.
2. Remove `Saved state!.icon`; privacy manifest, Privacy Policy, Legal Notice and Acknowledgements in; German strings; the NemoTextProcessing trait.
3. Signed Release archive → TestFlight on the iPhone 17 → a week of real use, including the airplane-mode checks.
4. A lawyer reviews the texts (and Art. 50) in parallel.
5. App record, App Privacy, age rating, screenshots (EN, DE), availability (no China mainland; Mac/Vision Pro decided) → submit with manual release.
