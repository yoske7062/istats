<p align="center"><img src="assets/icon.png" width="128" alt="iStats"></p>

# iStats

A tiny performance overlay for Mac games. Shows CPU, GPU, memory and chip temperature on top of your game, with colors that go green, yellow, orange, red as things heat up.

- Floats above fullscreen games. Clicks pass through to the game.
- Lives in the menu bar as `:)`. Hide or show the overlay from there.
- Record a session: get a summary (average and max) and a CSV saved in `~/Documents/iStats`.
- Reads numbers from macOS only. It never touches the game's process.
- Optional keyboard sounds: hear a mechanical switch in your headphones as you type. Nine switches to pick from, plus volume, pitch and release sound.

## Install

1. Download `iStats.zip` from the [latest release](../../releases/latest) and unzip it.
2. Move `iStats.app` to Applications.
3. First launch: right-click the app, choose Open. (The app is not notarized, so macOS asks once.)

Requires an Apple Silicon Mac on macOS 14 or newer.

## Use

- Double-click the overlay to unlock it, drag it where you want, double-click again to lock.
- Menu bar `:)` for Hide Overlay, Start/Stop Recording, Horizontal Layout (one row instead of a stack), Keyboard Sounds, Quit.

### Keyboard sounds

Menu bar `:)` > Keyboard Sounds > Play Key Sounds. Pick a switch to hear a short demo. The first time, macOS asks for Input Monitoring: allow iStats in System Settings > Privacy & Security > Input Monitoring and the sounds start on their own.

The sounds are synthesized, not recordings, so they are close to each switch rather than exact copies. iStats only sees which key went down or up to pick a sound; it never changes, blocks or saves your keys. The audio device only runs while you type and stops 20 seconds after the last key.

If you build iStats yourself, each new build counts as a new app for macOS, so you may need to allow Input Monitoring again.

## Build

```bash
./build.sh
```

Output goes to `dist/`. Needs Xcode command line tools.

## Support

If iStats is useful, you can [buy me a coffee on Ko-fi](https://ko-fi.com/wynix).

## License

MIT
