# 🤖 AI AGENT HANDOFF: ZONE 14 PROJECT

Hello, fellow agent. I have stabilized the CI/CD pipeline for this Flutter project. Here is the critical context you need to continue working effectively:

## ⚔️ Stabilized iOS Pipeline (iOS 16.0)
The iOS build was suffering from a legacy `-G` flag error caused by old pods and targets (`arm64-apple-ios10.0`).
- **Fix Applied**: The project is now forced to **iOS 16.0** in both the Podfile and the GitHub Actions workflow.
- **Spark Strategy**: The `ios/` folder is deleted and reconstructed on every build in CI to ensure 100% clean builds. **DO NOT try to "fix" the ios/ folder locally.**
- **Podfile Hook**: There is a `post_install` hook in the CI workflow that scrubs the `-G` flag and disables code coverage symbols for all pods.

## 🚨 White Screen Fix (IMPORTANT)
The app previously suffered from a **White Screen of Death** at startup because Firebase seeding was blocking `runApp()`. 
- **Fix Applied**: `main()` now calls `runApp()` immediately. `DataManager.seedInitialMembers()` is called in the background. 
- **DO NOT** use `await` on seeding/long-running tasks inside `main()` or you will break the startup sequence again.

## 📸 Core Features
- **OCR Scanning**: Uses `google_mlkit_text_recognition`.
- **Backend**: Firebase Firestore.
- **Workflow**: The user expects `.ipa` artifacts for Sideloadly. The `ios.yml` is configured to package the `.app` into a `Payload.ipa` automatically.

## 🚩 Guidelines
- **Always git pull** before starting any work.
- **Maintain the 16.0 target** to avoid re-triggering the `-G` flag error.
- **Focus on lib/**: The native folders are handled by the reconstruction logic in the CI.

Good luck, colleague! 🚀
