# Classic-Launcher-Apple-Silicon

Extract the contents of the folder inside the downloaded ZIP into your game directory.

```bash
tar xf Classic-Launcher-Apple-Silicon-main.zip --strip-components=1
cd custom_launcher/
chmod +x launch.sh
./launch.sh
```

Your directory should look like this:

```text
Game/
├── Data/
├── classic_era/
├── custom_launcher/    ← from this repo
└── build/              ← from this repo
```

When prompted, type `yes` to use HermesProxy so you can connect to legacy 1.12 servers (VMaNGOS & CMaNGOS).

<br/>

Patcher applies `40618.patch` to the Apple Silicon (ARM) build of the Classic 1.14.0 (40618) binary using xdelta3.

```bash
shasum 200c4c54316fb801d6d4d07d7031bb2b43f1c2be
```

If you have quarantine issues, you may need to manually allow the app to run in Gatekeeper.

```bash
sudo xattr -cr custom_launcher/
```

To reset configuration.

```bash
./launch.sh --reset
```
<br/>

### Classic Launcher.app Compilation (Optional)

```bash
cd build/
chmod +x build_launcher.sh
./build_launcher.sh
```

<br/>
<br/>

Credits:  [0Blu](https://github.com/0Blu)   [Arctium](https://github.com/Arctium)
