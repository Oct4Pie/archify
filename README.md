
<p align="center">
<img src="https://i.imgur.com/ttfaqoV.png" width="132" height="128" alt="archify">
</p>

# Archify

Archify is a tool that helps reduce the size of Mach-O universal binaries to save disk space.

[![GPLv3 License](https://img.shields.io/badge/License-GPL%20v3-yellow.svg)](https://opensource.org/licenses/)
![GitHub stars](https://img.shields.io/github/stars/Oct4Pie/archify)
![GitHub forks](https://img.shields.io/github/forks/Oct4Pie/archify)

## Installation

To install Archify, follow these steps:

1. Go to the [releases](https://github.com/Oct4Pie/archify/releases) section of the Archify GitHub repository.
2. Download the latest release of Archify.
3. Once downloaded, open the dmg or zip file and optionally move the Archify app to your Applications folder.

### Opening the App

When you try to open the app for the first time, macOS Gatekeeper might block it since it's downloaded from the internet. Follow these steps to bypass Gatekeeper:

1. Locate the Archify app in your Applications folder.
2. Right-click (or control-click) on the app and select "Open".
3. A warning dialog will appear, asking if you're sure you want to open it. Click "Open" to confirm.

Alternatively, you can permanently allow the app using the System Preferences:

1. Open **System Preferences** and go to **Security & Privacy**.
2. Under the **General** tab, you will see a message that Archify was blocked. Click the "Open Anyway" button.
3. Confirm by clicking "Open" in the subsequent dialog.

## App Usage
<img width="1200" alt="appusage.png" src="https://github.com/user-attachments/assets/ded275d6-fe97-42d4-a54e-d78ca84fc533">

The new GUI for Archify provides an interface for managing the applications. The GUI includes features such as:

1. **App Selection**: Select the input app and output directory for the app you want to process.
2. **Architecture**: By default, the machine architecture. Can optionally select a target architecture from the list.
3. **Signing**: Toggle between signing options (`ldid` and `codesign`) and specify whether to include entitlements. A new option `App launch` is added and attempts to cache signature to avoid the need for external signing.
4. **Progress and Logging**: View the progress of the processing and detailed logs in real-time.
5. **Size Calculation**: Calculate how much space is being used up by unnecessary binaries in each app.
6. **Language Cleaner**: Scan the `/Applications` directory to find and remove unnecessary language files from apps
7. **Batch Processing**: Scan and process all apps in the `/Applications` directory in one go
8. **Universal Apps**: View the state of the installed apps as native or universal

### Note
- The default options should work the best. It is recommended to only use `App launch (cache)` first.
- If it does not suffice, feel free to experiment with the other signing options.
- Using `codesign` or `ldid` without entitlements usually work, but sometimes injecting entitlements is required.
  - This option may cause issues with the app accessing keychain due to the app having no identity.
- After you have ensured the output app is functional, you can replace it with the original one.

## Helper Tool

Archify now includes a helper tool for privileged operations such as removing files and modifying app binaries. This helper makes sure that the necessary permissions are granted to perform these operations safely and effectively.

The helper tool is used for tasks such as:
- Removing the languages files.
- Extracting and signing binaries.
- Setting file permissions.

## Why Launch the App?

When an app is launched for the first time, macOS performs various checks and initializations. By launching the app before modifying it, you allow macOS to:

1. **Cache**: macOS validates the app's code signature and other integrity checks and may cache this validation. This means later launches rely more on this cached state rather than revalidating the entire app.
2. **Initial State**: The app sets up necessary initial states, caches, and configuration files that do not need revalidation.
3. **Integrity Checks**: After the initial launch, some integrity checks can be bypassed to make it easier for the app to run even if its contents are later modified.

By launching the app before modifying it, the necessary initial validations are done, which helps the app run even after modifications. This technique is useful when modifying apps to change their architecture or remove unnecessary components.

## Python Script Usage

If you prefer using the command-line interface, you can use the provided Python script.

### Requirements

- Python 3 is required.
  - Install via [Homebrew](https://brew.sh): `brew install python`
- `ldid` can also be found in [releases](https://github.com/Oct4Pie/archify/releases)

### Running the Script

To start:

```
python3 archify.py [-h] -app APP_DIR [APP_DIR ...] [-o OUTPUT_DIR] [-arch ARCH]
                   [-ld LDID] [-Ns] [-Ne] [-cs] [-l]
```

#### Options

- `-app, --app_dir`: Support one or more apps.
- `-arch, --arch`: Specify the target architecture. Use `arm64` for Apple Silicon devices. Intel 32-bit should be `i386` and 64-bit `x86_64` for Intel Macs. Default is set by the system.
- `-ld, --ldid`: The path to `ldid` binary (if signing with `ldid` is needed).
- `-Ns, --no_sign`: Do not sign the binaries with `ldid`.
- `-Ne, --no_entitlements`: Do not sign the binaries with original entitlements with `ldid`.
- `-cs, --codesign`: Ad-hoc sign the entire app with `codesign`.
- `-l, --no_launch`: Do not launch the app to initialize before processing.

#### Usage Example

- To create a fully native Apple Silicon version of Adobe Illustrator packaged in `/Users/oct4pie/apps/ptest`:
```
python3 archify.py -app /Applications/Adobe\ Illustrator\ 2022/Adobe\ Illustrator.app -o /Users/oct4pie/apps/ptest -arch arm64
```

- To create a 64-bit Intel version of Excel and OneNote:
```
python3 archify.py -app /Applications/Microsoft\ Excel.app /Applications/Microsoft\ OneNote.app -o /Users/oct4pie/apps/ptest -arch x86_64
```

- The `-arch` by default is the system architecture.

## Why?

I was tired of downloading bloated universal apps, and managing the space became a hassle. I don't think people should lose storage space because of that. I wrote this tool to help me, and I hope it will be useful to others as well. I was able to free up significant space after using the script on large apps (such as Adobe apps, Unity, 3D Engines, Microsoft Office, etc.).

## Note

The apps I have generated so far work without any issues. If the app crashes, try using `ldid`, `codesign` (with/without entitlements) flags for signing. `-Ns` should work most of the time because of fake-signing. This project is published for educational purposes. Although the script does not alter the original apps, use it with caution. I am not responsible for any harm done.

## Changelog
### Version 1.2.0
- Multiple UI enhancements
- Dyanmic versioning
- Improved helper tool disk access checks
- Persistence for universal apps view

### Version 1.2.0

- Language (.lproj) Cleaner to scan `/Applications` and remove unnecessary language files.
- Batch processing to scan and process all universal apps in the `/Applications` directory
- Added helper tool for privileged operations to remove files, extract and sign binaries, and set file permissions.
- Universal apps view

### Version 1.1.0

- GUI: single app processing, multiple architecture size calculations, signing & entitlement options
- Python script: multiple architecture size calculations, ad-hoc sign, entitlement options

### Version 1.0.0

- Initial release of Archify as a python script with single app processing, architecture size calculations, ldid signing

## To-Do
- Persist app states throughout navigation
- Account apps linked into `/Applications` from the `/System` volumes

## License

Licensed under [GPLv3](https://choosealicense.com/licenses/gpl-3.0)
