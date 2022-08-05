
# Archify

It gets rid of mach-o universal binaries to save some space

[![GPLv3 License](https://img.shields.io/badge/License-GPL%20v3-yellow.svg)](https://opensource.org/licenses/)


## Installation

- python3 required for `archify.py`
  + `brew install python` via https://brew.sh
  + or use a binary from [releases](https://github.com/Oct4Pie/archify/releases)
- `ldid` can also be found in [releases](https://github.com/Oct4Pie/archify/releases)

```
  git clone https://github.com/Oct4Pie/archify.git
  cd archify
```
    
## Usage

To start

```
  python3 archify.py [-h] -app APP_DIR [APP_DIR ...] [-o OUTPUT_DIR] [-arch ARCH]
                  [-ld LDID] [-Ns] [-Ne]
```
- `-app and --app_dir` support one or more apps
- `-arch, --arch` is the target architecture. I use arm64 on a m1 device.
- Intel 32-bit should be `i386` and 64-bit `x86_64` for macs. 
- `arch` command is another way to find out
- `-ld, --ldid` the path to `ldid` binary. ()
- `ldid` is not required but may be needed for some apps
- if `ldid` is found:
    + `-Ne` does not sign with the original binary signature
    + `-Ns` does not sign at all (might be helpful for some apps that have self-check)



## Usage Example
- To have a fully native apple silicon Adobe Illustrator 
  packaged in `/Users/oct4pie/apps/ptest`:
```
python3 archify.py -app /Applications/Adobe\ Illustrator\ 2022/Adobe\ Illustrator.app
-o /Users/oct4pie/apps/ptest -arch arm64
```
- To have a 64-bit intel version of Excel and OneNote:
```
python3 archify.py -app /Applications/Microsoft\ Excel.app 
/Applications/Microsoft\ OneNote.app -o /Users/oct4pie/apps/ptest -arch -arch x86_64
```

## Why?
I was tired of downloading bloated universal apps and managing the space became a hassle.
I don't think people should lose storage space because of that.
I just wrote this script to help me.

Hopefully it will be useful to others as well.
I was able to free up ~34GB after using the script on large apps (such as Adobe apps, Unity, 3D Engines, Microsoft Office, etc).
Some apps were already native, so the size change isn't as impressive.

### First attempt:
| Application                    | Original Size | Stripped Size | Percentage Shrinked | Space Saved |
| ------------------------------ | ------------- | ------------- | ------------------- | ----------- |
| Adobe Premiere Pro 2022.app/:  | 6.55GB        | 4.09GB        | 37.5%               | 2.46GB      |
| Adobe Media Encoder 2022.app/: | 5.38GB        | 3.12GB        | 41.96%              | 2.26GB      |
| Adobe Photoshop 2022.app/:     | 4.73GB        | 3.6GB         | 23.97%              | 1.13GB      |
| Adobe Illustrator.app/:        | 2.51GB        | 1.59GB        | 36.5%               | 936.93MB    |
| Google Chrome.app/:            | 939.3MB       | 552.75MB      | 41.15%              | 386.55MB    |
| Microsoft Excel.app/:          | 1.95GB        | 1.62GB        | 17.02%              | 340.12MB    |
| Microsoft Word.app/:           | 2.23GB        | 1.92GB        | 14.0%               | 319.26MB    |
| Microsoft PowerPoint.app/:     | 1.7GB         | 1.4GB         | 17.59%              | 306.47MB    |
| Microsoft OneNote.app/:        | 1.07GB        | 894.02MB      | 18.69%              | 205.47MB    |
| Visual Studio Code.app/:       | 504.7MB       | 331.2MB       | 34.38%              | 173.5MB     |
| Element.app/:                  | 420.65MB      | 248.03MB      | 41.04%              | 172.62MB    |
| Discord.app/:                  | 369.58MB      | 205.3MB       | 44.45%              | 164.29MB    |
| Parallels Desktop.app/:        | 678.22MB      | 522.76MB      | 22.92%              | 155.46MB    |
| Microsoft Remote Desktop.app/: | 263.64MB      | 121.17MB      | 54.04%              | 142.47MB    |
| Pages.app/:                    | 517.74MB      | 377.25MB      | 27.13%              | 140.49MB    |
| Numbers.app/:                  | 462.44MB      | 330.96MB      | 28.43%              | 131.48MB    |
| Android Studio Preview.app/:   | 1.91GB        | 1.79GB        | 6.14%               | 120.13MB    |
| Elmedia Player.app/:           | 207.09MB      | 121.28MB      | 41.44%              | 85.82MB     |
| CMake.app/:                    | 194.92MB      | 117.59MB      | 39.67%              | 77.33MB     |
| Wine Stable.app/:              | 960.44MB      | 900.48MB      | 6.24%               | 59.96MB     |
| VN.app/:                       | 347.47MB      | 290.14MB      | 16.5%               | 57.34MB     |
| Books.app/:                    | 132.59MB      | 77.91MB       | 41.24%              | 54.69MB     |
| Cloudflare WARP.app/:          | 116.24MB      | 70.95MB       | 38.97%              | 45.3MB      |
| HMA VPN.app/:                  | 100.66MB      | 66.41MB       | 34.02%              | 34.25MB     |
| Music.app/:                    | 105.35MB      | 71.74MB       | 31.9%               | 33.61MB     |
| Hopper Disassembler v4.app/:   | 91.11MB       | 59.82MB       | 34.35%              | 31.3MB      |
| Parallels Toolbox.app/:        | 154.1MB       | 124.91MB      | 18.94%              | 29.19MB     |
| qbittorrent.app/:              | 62.35MB       | 33.7MB        | 45.95%              | 28.65MB     |
| iTerm.app/:                    | 72.6MB        | 44.71MB       | 38.42%              | 27.89MB     |
| Maps.app/:                     | 82.09MB       | 57.85MB       | 29.54%              | 24.25MB     |
| Photos.app/:                   | 64.4MB        | 44.61MB       | 30.72%              | 19.79MB     |
| Descript.app/:                 | 359.64MB      | 340.0MB       | 5.46%               | 19.64MB     |
| TV.app/:                       | 75.76MB       | 56.93MB       | 24.86%              | 18.83MB     |
| Podcasts.app/:                 | 46.27MB       | 27.63MB       | 40.27%              | 18.63MB     |
| TeamViewer.app/:               | 133.97MB      | 115.76MB      | 13.59%              | 18.2MB      |
| Tunnelblick.app/:              | 43.75MB       | 30.16MB       | 31.06%              | 13.59MB     |
| Notes.app/:                    | 38.75MB       | 28.13MB       | 27.4%               | 10.62MB     |
| Speedtest.app/:                | 47.03MB       | 38.54MB       | 18.06%              | 8.49MB      |
| FindMy.app/:                   | 37.04MB       | 29.94MB       | 19.16%              | 7.1MB       |
| WhatsApp.app/:                 | 301.25MB      | 294.71MB      | 2.17%               | 6.54MB      |
| Reminders.app/:                | 17.68MB       | 11.28MB       | 36.18%              | 6.4MB       |
| AltServer.app/:                | 12.72MB       | 6.44MB        | 49.35%              | 6.28MB      |
| Mail.app/:                     | 28.17MB       | 22.13MB       | 21.42%              | 6.03MB      |
| App Store.app/:                | 26.49MB       | 20.55MB       | 22.42%              | 5.94MB      |
| LuLu.app/:                     | 20.86MB       | 14.97MB       | 28.25%              | 5.89MB      |
| News.app/:                     | 11.07MB       | 6.05MB        | 45.33%              | 5.02MB      |
| FaceTime.app/:                 | 15.8MB        | 11.2MB        | 29.08%              | 4.59MB      |
| iMazing.app/:                  | 347.53MB      | 343.32MB      | 1.21%               | 4.21MB      |
| Calendar.app/:                 | 16.13MB       | 12.05MB       | 25.28%              | 4.08MB      |
| Preview.app/:                  | 11.06MB       | 8.17MB        | 26.12%              | 2.89MB      |
| Cyberduck.app/:                | 208.18MB      | 205.34MB      | 1.37%               | 2.85MB      |
| Hex Fiend.app/:                | 8.17MB        | 5.41MB        | 33.79%              | 2.76MB      |
| Grammarly for Safari.app/:     | 83.14MB       | 80.5MB        | 3.17%               | 2.64MB      |
| Transparent Note.app/:         | 27.02MB       | 24.64MB       | 8.82%               | 2.38MB      |
| Color Picker.app/:             | 5.98MB        | 3.67MB        | 38.74%              | 2.32MB      |
| QuickTime Player.app/:         | 7.48MB        | 5.63MB        | 24.8%               | 1.86MB      |
| VoiceMemos.app/:               | 5.62MB        | 3.81MB        | 32.15%              | 1.81MB      |
| Messages.app/:                 | 5.83MB        | 4.03MB        | 30.85%              | 1.8MB       |
| Contacts.app/:                 | 15.12MB       | 13.55MB       | 10.38%              | 1.57MB      |
| Shortcuts.app/:                | 3.76MB        | 2.42MB        | 35.61%              | 1.34MB      |
| Stocks.app/:                   | 4.25MB        | 3.01MB        | 29.2%               | 1.24MB      |
| Font Book.app/:                | 7.17MB        | 5.95MB        | 17.0%               | 1.22MB      |
| Safari.app/:                   | 14.41MB       | 13.32MB       | 7.52%               | 1.08MB      |
| Home.app/:                     | 4.21MB        | 3.24MB        | 23.03%              | 993.53KB    |
| Photo Booth.app/:              | 4.66MB        | 3.81MB        | 18.26%              | 872.29KB    |
| System Preferences.app/:       | 2.89MB        | 2.13MB        | 26.21%              | 775.73KB    |
| Calculator.app/:               | 5.77MB        | 5.1MB         | 11.64%              | 687.75KB    |
| Cutter.app/:                   | 612.99MB      | 612.33MB      | 0.11%               | 672.73KB    |
| Chess.app/:                    | 7.45MB        | 6.84MB        | 8.1%                | 618.01KB    |
| Keynote.app/:                  | 449.24MB      | 448.69MB      | 0.12%               | 554.71KB    |
| Automator.app/:                | 5.39MB        | 4.86MB        | 9.97%               | 550.41KB    |
| Userscripts.app/:              | 3.06MB        | 2.56MB        | 16.52%              | 518.23KB    |
| Dictionary.app/:               | 15.16MB       | 14.7MB        | 2.97%               | 461.36KB    |
| Telegram.app/:                 | 113.06MB      | 112.7MB       | 0.31%               | 363.72KB    |
| Stickies.app/:                 | 1.9MB         | 1.55MB        | 18.54%              | 361.58KB    |
| TextEdit.app/:                 | 2.7MB         | 2.44MB        | 9.47%               | 261.8KB     |
| Image Capture.app/:            | 3.31MB        | 3.18MB        | 4.05%               | 137.34KB    |
| Time Machine.app/:             | 1.25MB        | 1.13MB        | 9.46%               | 121.24KB    |
| Siri.app/:                     | 2.54MB        | 2.43MB        | 4.61%               | 120.17KB    |

## Note
The apps I have generated so far work without any issues. If the app crashes, try `ldid` or use different flags for signing.
`-Ns` should work most of the time because of fake-signing.
I am publishing the project for educational purposes. 
Although the script does not alter the original apps, use it with caution. 
I am not responsible for any harm done.
## License

Licensed under [GPLv3](https://choosealicense.com/licenses/gpl-3.0)

