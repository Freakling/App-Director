<!-- App Director · framework-owned: replaced on upgrade. -->
# Release

Build and deploy the app to an environment or platform. Never deploy without the check passing.

The request names the target: `web`, `mobile` (iOS/Android), or `desktop`. The stack and deploy method are in `tools/check.cfg` › `[project] stack` and AGENTS.md › Project facts.

## 1. Ready?
1. The working tree is clean.
2. `bash tools/check.sh` passes. If it fails, stop: the build isn't worth shipping.
3. List what's in this release: the `done` items since the last release tag (`git log <last tag>..HEAD --oneline`). A `high` bug that's done but has no regression test goes into the next acceptance check.

## 2. Build

### Web (TypeScript)
```
npm run build
```
Or `pnpm build` / `yarn build` if the project uses those. Verify the output in `dist/` or `build/`.

### Mobile (React Native)
- iOS: `npx react-native build-ios --mode Release` (requires Xcode on macOS)
- Android: `npx react-native build-android --mode release`

Prepare the build; the human submits to the App Store or Play Store; store submission is a `human` item.

### Mobile (Flutter)
- Android: `flutter build apk --release` or `flutter build appbundle --release`
- iOS: `flutter build ipa` (requires Xcode on macOS)

Prepare the build; the human submits to the stores.

### Desktop (Electron)
```
npm run build:electron
```
Or the project's equivalent. Verify the packaged output.

### Desktop (Tauri)
```
cargo tauri build
```
Verify the installer in `src-tauri/target/release/bundle/`.

## 3. Deploy (web only)

For web targets, pick the method from AGENTS.md › Project facts or ask the human:

- **Vercel:** `npx vercel --prod` (the human approves the deploy in the Vercel dashboard if not already linked).
- **Netlify:** `npx netlify deploy --prod --dir=dist`.
- **GitHub Pages:** push the build output to the `gh-pages` branch.
- **Other:** follow the commands AGENTS.md names.

For any method that uses a service account, managed keys, or production credentials: give the human the exact commands and let them run it.

## 4. Smoke test
After a web deploy, or when a mobile/desktop build is installed on a test device:
- Walk through the primary core flow once end-to-end.
- Check that the app loads without errors.
- Report anything that failed, with steps to reproduce. A failed smoke test is a `high` bug.

## 5. Record
- Tag the commit: `git tag v<version>` where version follows the project's scheme (e.g. `1.2.0` or `2026.10`). Push the tag when the human asks.
- The `(demo)` outcomes in this release go into the next acceptance check, with a note about the environment they were deployed to.
