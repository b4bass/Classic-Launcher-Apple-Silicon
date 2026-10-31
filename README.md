# Classic-Launcher-Apple-Silicon

Patches and launches the modern macOS build of Classic 1.14 for Apple Silicon and Intel, enabling connections to legacy Vanilla 1.12 realms.

<br />

Extract the contents of the ZIP downloaded from this repository directly into your game directory.

```bash
tar xf Classic-Launcher-Apple-Silicon-main.zip --strip-components=1
chmod +x launcher/launch.sh
```

Your directory should look like this:

```text
Game/
├── Data/
├── _classic_era_/
└── launcher/      ← from this repo
```

Manually execute the launch script.

```bash
./launcher/launch.sh
```

When prompted, type `yes` to use HermesProxy so you can connect to legacy 1.12 servers (MaNGOS).

The launcher copies `classicpatch.dylib` to the game app and modifies the binary once to load the library at start time.<br />
At each startup, the library patches the client in memory, modifying the server keys, certificate checks, and login portal.

It expects the unpatched sha1 checksum:

- 1.14.0 (40618): `200c4c54316fb801d6d4d07d7031bb2b43f1c2be`
- 1.14.1 (42032): `bff00e04f1a02ecf4b8410d5796eddda1dc24afc`
- 1.14.2 (42597): `638233fd384602862e41590e4b0213242c82257f`

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

To use a custom proxy executable located in the `proxy` folder instead of the default.

```bash
launch.sh --switchproxy MyProxy
```

To pass dynamic override arguments to HermesProxy (e.g., overriding the server address).

```bash
launch.sh --set ServerAddress=logon.example.com
```

You can also chain arguments together:

```bash
launch.sh --switchproxy MyProxy --set ServerAddress=127.0.0.1 --set LogLevel=Debug
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

### Classic Era Launcher.app Compilation (Optional)

```bash
chmod +x launcher/build/build_launcher.sh
./launcher/build/build_launcher.sh
```

### Resetting the Compiled App

Once you've built `Classic Era Launcher.app`, the only way to change the server you connect to (realmlist) is to reset its configuration.

1. Open your game folder in Finder — the one holding `Classic Era Launcher.app` and `_classic_era_`.
2. Delete the `connect.conf` file.
3. Relaunch the app — you'll be prompted to set up the realm connection again.

<br />

### classicpatch.dylib Compilation (Optional)

The library can be built from `classicpatch.c` for both Apple Silicon and Intel Macs.

```bash
xcode-select --install
chmod +x launcher/build/patch/build_classicpatch.sh
./launcher/build/patch/build_classicpatch.sh
```

`classicpatch.dylib` is already precompiled and ships ready to use.

<br />
<br />

Credits:  [0Blu](https://github.com/0Blu)   [Arctium](https://github.com/Arctium)   [Xian55](https://github.com/Xian55/HermesProxy)   [Jhinzuo2](https://github.com/jhinzuo2/wow-classic-arm64-customservers)
<br />
