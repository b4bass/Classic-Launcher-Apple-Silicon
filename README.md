# Classic-Launcher-Apple-Silicon

Copy custom_launcher folder inside your Classic_1.14.0.40618_macOS client folder

>cd custom_launcher/
>
>chmod+x launch.sh
> 
>./launch.sh

Type yes to use HermesProxy so you can connect to legacy 1.12 servers
<br/>
<br/>


>sudo xattr -c -r custom_launcher

You may need to allow the app to run in gatekeeper if you have quarantine issues
<br/>
<br/>


>shasum 200c4c54316fb801d6d4d07d7031bb2b43f1c2be
>
Patcher applies 40618.patch to the Apple Silicon (ARM) build of the Classic 1.14.0 (40618) binary using xdelta3
<br/>
<br/>

>./launch.sh --reset

To reset configuration
<br/>
<br/>
<br/>
### Classic Launcher.app Compilation

>cd custom_launcher/build/
>
>chmod+x build_launcher.sh
>
>./build_launcher.sh

<br/>
<br/>

credits: github.com/0blu
