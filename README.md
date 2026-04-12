# Classic-Launcher-Apple-Silicon

Extract the repository content into your  Classic_1.14.0.40618_macOS directory 

> unzip -d Classic-Launcher-Apple-Silicon-main.zip ./custom_launcher
> 
>cd custom_launcher/
>
>chmod+x launch.sh
> 
>./launch.sh

When prompted, type yes to use HermesProxy so you can connect to legacy 1.12 servers (VMaNGOS & CMaNGOS)
<br/>
<br/>


>sudo xattr -c -r custom_launcher

If you have quarantine issues, you may need to manually allow the app to run in gatekeeper
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
### Classic Launcher.app Compilation (Optional)

>cd custom_launcher/build/
>
>chmod+x build_launcher.sh
>
>./build_launcher.sh

<br/>
<br/>

credits: github.com/Blu github.com/Arctium
