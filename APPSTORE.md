# Scribe → App Store checklist

Scribe is free; users can tip via In-App Purchase. Implementation items first, in the order to do them; account and listing items after. State of the project when this was written (October 2026): usage descriptions (microphone, location), `UIBackgroundModes: audio`, `ITSAppUsesNonExemptEncryption: false`, the launch screen and the icon are done; no Release build has ever been made.

## 1. Implementation — must-haves

- [ ] **Privacy manifest** `Recorder/PrivacyInfo.xcprivacy`: required-reason APIs (`UserDefaults` → `CA92.1`; file attributes only if dates are read), tracking = no, collected data = none. Uploads without it are rejected.
- [ ] **First Release build**: `xcodebuild archive -configuration Release`. Check that every QA hook (`-seedSamples`, `-fakeCorrections`, fakes, the Developer section, `print("[Scribe] …")`) compiles out under `#if DEBUG`, that MLX's Metal shaders compile in Release, and that the optimizer raises no concurrency warnings. Then TestFlight on the iPhone 17: the first Release run of the whole pipeline on a device.
- [ ] **Model-license disclosure**: the app distributes models by downloading them.
  - Gemma: Google's Gemma Terms of Use + Prohibited Use Policy shown before the first download, with "I agree".
  - Acknowledgements page in Settings: Parakeet (CC-BY-4.0), Nemotron (NVIDIA Open Model License), pyannote community-1, FluidAudio, MLX, swift-transformers (Apache/MIT), Qwen (Apache 2.0, DEBUG only).
- [ ] **Device gating for the local model**: Gemma peaks at ~3.7 GB RAM. Gate the download on `ProcessInfo.processInfo.physicalMemory ≥ 7 GB` with a note ("needs an iPhone 17 or later"); show storage needed vs. free before any download.
- [ ] **Tip jar (StoreKit 2)** — tips must be In-App Purchases (App Review 3.1.1; no Ko-fi/PayPal links).
  - App Store Connect: three consumables (`tip.small` €0.99, `tip.medium` €2.99, `tip.large` €9.99); a `.storekit` configuration file for local testing.
  - Code: a `TipJar` observable — `Product.products(for:)`, `purchase()`, a `Transaction.updates` listener, `finish()` on verified transactions, a thank-you state; consumables need no restore.
  - UI: "Support Scribe" row at the bottom of Settings → a page with the three tips (StoreKit's `ProductView`) and one line: "Scribe is free and stays free; a tip helps keep it that way."
  - Needs the Paid Apps agreement, banking and tax forms first (days).
- [ ] **App Store name**: "Scribe" is almost certainly taken (names are unique). Pick the listing name now, e.g. "Scribe – On-Device Transcripts"; the display name under the icon stays "Scribe"; the bundle id `de.cofinpro.recorder` and `PRODUCT_NAME` never change.
- [ ] **Review path**: the reviewer tests with English speech on an unknown device. Verify: Apple Speech path works without any download; the empty state explains the record button; offline is handled (it is); nothing crashes with downloads refused. Review notes: the optional downloads (610 MB / 100 MB / 3.6 GB), German as the primary language, a short demo video link.

## 2. Implementation — should-haves for 1.0

- [ ] Storage overview in Settings: disk use per model, Delete for Parakeet and Nemotron too (Gemma has it).
- [ ] Full UI suite on both runtimes once (`build/qa/uitests.sh`), then a week of real use of the Release build on the phone.
- [ ] Decide: keep the "Better Summaries" toggle or only Delete (one control fewer).
- [ ] Later, Apple-only crash signals via MetricKit (no third party); not for 1.0.

## 3. Account and listing

- [ ] Paid Apps agreement, banking, tax (needed for tips).
- [ ] Privacy policy URL (one page: nothing leaves the device; optional model downloads from Hugging Face; tips through Apple).
- [ ] Support URL / email.
- [ ] App Privacy questionnaire: "Data Not Collected".
- [ ] Screenshots: 6.9" and 6.3"; German and English listing text; category Productivity (or Business); age rating 4+.
- [ ] Export compliance: already `ITSAppUsesNonExemptEncryption = false` (HTTPS only).

## Order

1. Privacy manifest → 2. Release build + TestFlight → 3. License disclosure → 4. Device gating (one to two days, mechanical, verifiable with a Release archive)
→ 5. Tip jar (one day, after the agreement is signed) → account/listing in parallel → a week on TestFlight → submit.
