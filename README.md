# Classic-Launcher-Apple-Silicon

Patches and launches the modern macOS builds of Classic Era 1.14, TBC Classic 2.5, WotLK Classic 3.4.3 and Cataclysm Classic 4.4.2 for Apple Silicon and Intel, enabling connections to legacy realms (1.12, 2.4.3, 3.3.5a, 4.3.4).

<br />

Extract the contents of the ZIP downloaded from this repository directly into your game directory.

Your directory should look like this:

```text
Game/
├── Data/
├── _classic_era_/  ← Classic Era
├── _classic_/      ← TBC, WotLK or Cataclysm Classic
└── launcher/       ← from this repo
```

Manually execute the launch script.

```bash
./launcher/launch.sh
```

When prompted, type `yes` to use HermesProxy so you can connect to legacy servers (MaNGOS, TrinityCore, AzerothCore).

The launcher copies `classicpatch.dylib` to the game app and modifies the binary once to load the library at start time.<br />
At each startup, the library patches the client in memory, modifying the server keys, certificate checks, and login portal.

It expects the unpatched sha1 checksum:

- 1.14.0 (40618): `200c4c54316fb801d6d4d07d7031bb2b43f1c2be`
- 1.14.1 (42032): `bff00e04f1a02ecf4b8410d5796eddda1dc24afc`
- 1.14.2 (42597): `638233fd384602862e41590e4b0213242c82257f`
- 2.5.2 (40892): `be5eee620d5a75e4142a60858c013a861625b62e`
- 2.5.3 (42328): `fc843a8d2f9a0ba0e2f86c0ad9e23b03de1ef99d`
- 2.5.3 (42598): `be3a5cb20630b0f420b5531238933f6f3fb8f09a`
- 3.4.3 (54261): `1d7cee2116baf1c4247e67a4b5f3c760dd5df7e6`
- 4.4.2 (60895): `e4b089c80ceb293931ad97e0b2f90b0b7c2de108`

<br />

If you have quarantine issues, you may need to manually allow the app to run in Gatekeeper.

```bash
sudo xattr -cr launcher/
```

If you encounter a CAS system error, delete your Cache folder or reset the configuration.

<br />

### Usage

To only patch the game.

```bash
launch.sh --patch
```

To verify that the client is properly patched.

```bash
launch.sh --checkpatch
```

To reset configuration.

```bash
launch.sh --reset
```

To fetch missing files.

```bash
launch.sh --getmissing
```

To use a game folder somewhere else.

```bash
launch.sh --game /path/to/Game
```

To list all available options.

```bash
launch.sh --help
```

<br />

### Proxy Options

To use another proxy executable instead of the default: its name in the `proxy` folder, or its path.

```bash
launch.sh --switchproxy MyProxy
```

To pass dynamic override arguments to HermesProxy (e.g., overriding the server address).

```bash
launch.sh --set ServerAddress=logon.yourserver.com
```

You can also chain arguments together:

```bash
launch.sh --switchproxy MyProxy --set ServerAddress=logon.yourserver.com --set Log.MinimumLevel=Debug
```

To specify a custom proxy configuration file.

```bash
launch.sh --config /path/to/proxy.config
```

To force a direct connection (bypasses proxy entirely).

```bash
launch.sh --bnet 127.0.0.1
```

<br />

### Launcher App Compilation (Optional)

Builds one app per client in the game folder: `Classic Era Launcher.app`, `TBC Classic Launcher.app`, `WotLK Classic Launcher.app` or `Cataclysm Classic Launcher.app`.

```bash
./launcher/build/build_launcher.sh
```

### Resetting the Compiled App

Once you've built a launcher app, the only way to change the server you connect to (realmlist) is to reset its configuration.

1. Open your game folder in Finder — the one holding the app.
2. Delete the `connect.conf` file.
3. Relaunch the app — you'll be prompted to set up the realm connection again.

<br />

### classicpatch.dylib Compilation (Optional)

The library can be built from `classicpatch.c` for both Apple Silicon and Intel Macs.

```bash
xcode-select --install
./launcher/build/patch/build_classicpatch.sh
```

`classicpatch.dylib` is already precompiled and ships ready to use.

<br />
<br />

Credits:  [0Blu](https://github.com/0Blu)   [Arctium](https://github.com/Arctium)   [WowLegacyCore](https://github.com/WowLegacyCore/HermesProxy)   [Xian55](https://github.com/Xian55/HermesProxy)   [Jhinzuo2](https://github.com/jhinzuo2/wow-classic-arm64-customservers)
<br />
