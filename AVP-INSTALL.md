# Installing Wind Waker VR on Apple Vision Pro

Wind Waker VR is [Trevorbilt](https://trevorbilt.com)'s native visionOS port of
[SwitchWaker](https://github.com/centollOS/SwitchWaker), which compiles zeldaret's
[decompilation](https://github.com/zeldaret/tww) of the game natively on encounter's
[Aurora](https://github.com/encounter/aurora); the [README](README.md#credits) credits everyone it
builds on.

*The Legend of Zelda: The Wind Waker* (GameCube) runs natively on Apple Vision Pro once you build
this project with Xcode and install it on your own headset. It plays in a **Window** beside your
other apps, with the game's world in real 3D behind the glass, or in 2D like the original. Full and
Progressive (first-person VR) are in the app behind an experimental switch, untested on a headset.
There's no ready-made app to download, and none of the game's files are here: you bring your own
disc.

## Requirements

- **Apple Vision Pro** on visionOS 26 or later (played on visionOS 27).
- **A Mac with Apple silicon** and **Xcode** at `/Applications/Xcode.app`, not a path with a space
  in it (CMake can't handle one). Built and tested with Xcode 27.1 on macOS 27. Open Xcode once so
  it finishes installing, then add its visionOS platform in Xcode › Settings › Components.
- **An Apple Account** signed in to Xcode (Xcode › Settings › Accounts). The app asks for the
  increased memory limit. It's been built with a paid Apple Developer Program team; whether a free
  account can sign it is untested, and apps a free account signs stop opening after 7 days until
  you install them again.
- **Homebrew** ([brew.sh](https://brew.sh)), these tools from it, and the Rust nightly the build
  pins (nod, the disc reader, is Rust; Homebrew's `rustup` stays off your `PATH`, hence the first
  `export`):

  ```bash
  brew install cmake ninja xcodegen python rustup
  export PATH="$(brew --prefix rustup)/bin:$PATH"
  rustup toolchain install nightly-2026-09-30 --profile minimal
  rustup target add --toolchain nightly-2026-09-30 aarch64-apple-visionos aarch64-apple-visionos-sim
  ```

  CMake 3.28 or newer and Python 3.10 or newer; Homebrew's are.
- **About 5 GB of free disk space** and the network. The first build takes an hour or two: it builds
  Dawn (the graphics layer) once, then the whole game. Later builds take minutes.
- **A controller.** The Window view plays with a gamepad (DualSense, Xbox or another), or both PS VR2
  Sense controllers held as one.

## Game files

You supply the game yourself; this repository contains none, and the build never downloads any.

1. **Dump your own disc.** [Dolphin's guide](https://wiki.dolphin-emu.org/index.php?title=Ripping_Games)
   explains how.
2. **Check it's the supported release:** *The Legend of Zelda: The Wind Waker*, USA, game ID
   **GZLE01, revision 0** (the original release), as an **uncompressed `.iso`** of 1,459,978,240
   bytes. A `.rvz` or `.ciso` needs converting to ISO first (in Dolphin: right-click the game,
   Convert File, ISO). The European and Japanese discs, later revisions and the Wii U's HD remaster
   don't work. What's checked, and where:
   - **The app** reads the disc's header and size: GZLE01, revision 0, a full disc. It tells you if a
     disc is another region or revision, and turns away a compressed image (`.rvz`, `.ciso`)
     with how to convert it.
   - **The build** (step 2 below) checks the disc's `main.dol` against the decompilation's SHA-1,
     `8d28bab68bb5078c38e43f29206f0bd01f7e7a67`, before it makes anything from it.
   - The image this port was built and played with has SHA-1
     `6b5f06c10d50ebb4099cded88217eb71e5bfbb4a` (MD5 `d8e4d45af2032a081a0f446384e9261b`). Another
     image of the same disc can hash differently and still work, as long as its `main.dol` matches.
3. **Keep it handy.** The build reads it once on your Mac, and it goes onto the headset after the
   app is installed (step 6 below).

## Get the code

If you came from the AVP Ports Index and already cloned the commit it lists, skip this step and
build from that folder.

```bash
git clone https://github.com/edgytoast/windwaker-visionos.git windwaker-visionos
cd windwaker-visionos
```

The folder's path may have spaces in it; Xcode's may not.

## Build and install

1. **Connect the headset.** If you haven't run your own apps on it before, turn on Developer Mode
   (Settings › Privacy & Security › Developer Mode; the headset restarts), then pair it with your
   Mac: open Xcode › Window › Devices and Simulators, and on the headset open Settings › General ›
   Remote Devices and pick your Mac. Keep the headset on and unlocked while it installs.
2. **Generate the game's asset headers from your disc, once,** from the project's folder:

   ```bash
   COS_DISC=/path/to/your/GZLE01.iso native/tools/gen_assets.sh
   ```

   The game's code includes model and resource data in headers that only your disc can provide.
   The script makes a shallow clone of the decompilation the game code came from (the repository
   and commit in `game/UPSTREAM`) into `build/decomp`, links your disc into it, runs its
   `configure.py` and then only the steps that write headers (its own pinned decomp-toolkit, which
   it downloads, checks `main.dol`'s SHA-1 and extracts the data; no compiler is downloaded and
   nothing is compiled). The headers go to `build/native-mac/assets/GZLE01`. Everything stays
   under `build/`, which git ignores: they're derived from your disc, so keep them to yourself.
3. **Find your team ID:** the 10-character ID shown for your team in Xcode › Settings › Accounts.
4. **Build and install:**

   ```bash
   visionos/scripts/build-visionos.sh --team YOURTEAMID --install
   ```

   With more than one headset paired, add `--device <UDID>` (`xcrun devicectl list devices` lists
   them). Here's everything it does on your Mac. It never uses `sudo`, and apart from Xcode's,
   CMake's and Cargo's own caches it writes only inside this folder:

   1. **Checks** for Xcode, `xcodegen`, `cmake`, `ninja`, the Rust nightly and your asset headers
      before it fetches or builds anything, and says what's missing.
   2. **Fetches the pinned sources,** once: [Aurora](https://github.com/encounter/aurora) at
      SwitchWaker's commit into `ref/aurora`, and elliotttate's
      [RecompCore](https://github.com/elliotttate/RecompCore) (for Dolphin's DSP, the game's audio)
      into `ref/recompcore`.
   3. **Builds Dawn for visionOS, once** (`visionos/scripts/build-dawn-visionos.sh`). It downloads
      [encounter/dawn](https://github.com/encounter/dawn) at the revision Aurora pins, and Dawn's own
      dependencies, applies `visionos/patches/dawn/`, and keeps the result in `.scratch/dawn`.
   4. **Builds the game** as `WindWakerVisionGame.framework`, in `.scratch/`. Aurora is patched
      there (SwitchWaker's patches, then `visionos/patches/aurora/`). CMake downloads Aurora's own
      dependencies at its pins (SDL 3, abseil, fmt, FreeType, libpng, zstd, Dear ImGui, xxHash,
      Tracy, nod's source and Corrosion) and the
      [OpenXR SDK](https://github.com/KhronosGroup/OpenXR-SDK) 1.1.61's headers, and Cargo builds
      nod with its crates. [THIRD_PARTY.md](THIRD_PARTY.md) lists each one.
   5. **Generates the Xcode project** (`visionos/App/WindWakerVision.xcodeproj`) and builds the app,
      signed with your team. The bundle ID is `dev.windwakervr.vision.YOURTEAMID`: keep the team
      suffix, since a bare ID can already belong to someone else's team, and signing then fails on
      the memory entitlement.
   6. **Installs it** on your paired Apple Vision Pro with `xcrun devicectl`.

5. **Trust it,** if visionOS says the developer isn't trusted: Settings › General › VPN & Device
   Management.
6. **Add your disc**, any one of these ways:
   - AirDrop the `.iso` to your Vision Pro and choose **Wind Waker VR** to open it with.
   - Put it anywhere Files can reach, then tap **Import** in the app.
   - Copy it into the app's own folder in Files (On My Apple Vision Pro › Wind Waker VR).
7. **Play.** Tap **Play**, and look at the game's window to give it your controller. The launcher's
   **Controls** tab shows every button for what you're holding, and the camera's directions.

## Update

Get the new code: if you came from the AVP Ports Index, run `git fetch`, then `git checkout` the
commit Wind Waker VR's page there lists now (that's the code it scanned). If you cloned the
`visionos` branch, `git pull`. Then build and install again:

```bash
visionos/scripts/build-visionos.sh --team YOURTEAMID --install
```

The asset headers in `build/` stay as they are (run `gen_assets.sh` again only if an update says
so), and your disc and saves stay on the headset. The app's About tab says when a newer version is
out.

## Saving

Save from the game's own menu, the way you always did. Close the game's window to quit: your
progress is what you last saved. In Full and Progressive, the Digital Crown pauses the game and the
launcher offers **Resume** or **Quit**.

Saves are the game's own memory card, in Files › On My Apple Vision Pro › Wind Waker VR ›
WindWaker. Copy that folder out to keep your own backup: deleting the app deletes it.

## Controls

- **Window:** it plays like the original game, so it needs a gamepad, or both Sense controllers
  held as one. Look at the game window to give it your controller: visionOS sends a controller's
  input to the window you're looking at. The [README](README.md#play) has every button. The 2D or 3D
  button sits above the window's corner (L1 and Create together on a gamepad), and the Controls tab
  sets which way the camera turns.
- **Full and Progressive (experimental):** turn on **Try Full and Progressive (experimental)** under
  the cards on Play first. PS VR2 Sense controllers, bare hands or a gamepad; the Controls tab draws
  every button and gesture. They haven't been played on a headset yet, so stereo, comfort and frame
  rate are untested: take it slow, and stop if anything feels off.

## Troubleshooting

- **`no asset headers`:** run step 2 (`gen_assets.sh` with your disc) first.
- **`gen_assets.sh` stops on a checksum or SHA-1 mismatch:** the disc's `main.dol` isn't revision
  0 of the USA release (another revision or region, or a damaged dump).
- **The app says the disc is compressed or cut short:** convert it to an uncompressed `.iso`
  (1,459,978,240 bytes) and import it again.
- **CMake can't find Xcode:** Xcode must be at `/Applications/Xcode.app`, not a path with a space.
- **Rust errors about `aarch64-apple-visionos`:** run the two `rustup` lines under Requirements
  (with Homebrew's `rustup` on your `PATH`).
- **Signing fails on the memory entitlement:** keep the bundle ID's team suffix (the script's
  default), and check the team ID is your own.
- **The install hangs:** wake and unlock the headset, then run the build command again.
- **The controller works the launcher, not the game:** look at the game's window; visionOS gives
  the controller to the window you're looking at.

Something else? [Report a problem](https://github.com/edgytoast/windwaker-visionos/issues).

## Credits and licences

- The Apple Vision Pro port by [Trevorbilt](https://trevorbilt.com), MIT.
- [SwitchWaker](https://github.com/centollOS/SwitchWaker), the native port this builds on, by
  Pulpparty, depende3000 and the SwitchWaker contributors (MIT).
- [zeldaret/tww](https://github.com/zeldaret/tww), the decompilation, with
  [snrubrm/tww](https://github.com/snrubrm/tww)'s completed functions (CC0-1.0).
- [Aurora](https://github.com/encounter/aurora), the GameCube SDK over WebGPU, by encounter (MIT).
- Twilight Princess VR's lineage: [JoeyAW's TPVR](https://github.com/JoeyAW/TPVR) and Trevorbilt's
  [visionOS port](https://github.com/edgytoast/tpvr-visionos), on Twilit Realm's
  [Dusklight](https://github.com/TwilitRealm/dusklight), which the window's scene mirror, the stereo
  view and the VR hooks follow.
- The visionOS OpenXR provider from [WiiCompiled Vision](https://github.com/iChris4/Wiicompiled_VR)
  (GPL-3.0-or-later), so the app you build is GPL-3.0.
- Dolphin's DSP, the game's audio, through elliotttate's adapter from
  [Wind Waker Recomp](https://github.com/elliotttate/Wind-Waker-Recomp) (GPL-2.0-or-later).
- TrevorbiltKit, the shared launcher (MIT; its fonts under the SIL Open Font License 1.1).

[THIRD_PARTY.md](THIRD_PARTY.md) lists every component and its licence. *The Legend of Zelda: The
Wind Waker* is Nintendo's. This project isn't affiliated with or endorsed by Nintendo, and none of
the game's files are in the app or the repository.
