# Sidebar

Minimal browser: a hideable vertical sidebar, no tab strip, no bookmarks bar.

The current app is a native macOS build (Swift + WebKit) in `native/`. The original Electron version is still in `src/`.

## Native (macOS 15+)

```bash
cd native
./build.sh            # builds native/build/Sidebar.app
./build.sh --install  # also copies it to /Applications
```

`build.sh` signs with the author's Developer ID if it's in the keychain, otherwise it ad-hoc signs.

## Electron

```bash
npm install
npm start       # run it
npm run dist    # package a macOS .app into dist/
```
