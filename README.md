# SoloCast for Mac

A small menu bar app to configure a HyperX SoloCast microphone on macOS. HyperX's own NGENUITY software only runs on Windows.

> **Vibe coded.** This app was written with an AI assistant in one sitting and tested on a single Mac with a single microphone. Expect bugs. Use it at your own risk.
>
> Unofficial. Not affiliated with or endorsed by HyperX or HP.

## Features

- **Level meters**: input and output, with a peak marker that turns red near clipping.
- **Gain, mute, sample rate**: the hardware settings the mic exposes to macOS.
- **Noise gate**: on/off and threshold.
- **Equalizer**: 5 bands (80 Hz, 250 Hz, 1 kHz, 4 kHz, 10 kHz), ±12 dB each. Double-click a fader to reset it.
- **Compressor**: on/off, threshold, makeup gain, live gain-reduction readout.

Settings are saved between launches.

The gate, EQ and compressor use Apple's built-in audio units. The processed sound is sent to [BlackHole](https://github.com/ExistentialAudio/BlackHole), a free virtual audio device, which you then select as the microphone in other apps.

## Requirements

- macOS 13 or later (developed on macOS 27, Apple silicon)
- Xcode Command Line Tools, for the Swift compiler: `xcode-select --install`
- [Homebrew](https://brew.sh), to install BlackHole

## Install

1. Get the code and build the app:

   ```bash
   git clone https://github.com/sidalihmdn/hyperx-solocast-mac.git
   cd hyperx-solocast-mac
   sh build.sh
   ```

   The build ends with a self-check. With the mic plugged in, it prints two lines starting with `OK`.

2. Install BlackHole. It asks for your password:

   ```bash
   brew install blackhole-2ch
   ```

3. Restart the Mac. BlackHole does not appear until you do.

4. Start the app:

   ```bash
   open SoloCast.app
   ```

5. Click **Allow** when macOS asks for microphone access.

6. Click the microphone icon in the menu bar. The status dot is green when processed audio is going to BlackHole.

7. In Zoom, OBS, Discord or any other app, choose **BlackHole 2ch** as the microphone.

Without BlackHole the app still works as a meter and for gain, mute and sample rate, but the gate, EQ and compressor have nowhere to send their output.

## Supported devices

| Device | Status |
| --- | --- |
| HyperX SoloCast (USB ID `03f0:078b`) | Tested. The only device this was developed on. |
| HyperX SoloCast 2 | Untested. Should be detected, since its name contains "SoloCast". |
| Older Kingston-branded HyperX SoloCast | Untested. Should be detected for the same reason. |
| HyperX QuadCast, QuadCast S, QuadCast 2, DuoCast | Not detected as is. See below. |
| Other USB microphones | Not detected as is. See below. |

The app finds the mic by looking for "SoloCast" in the device name. Nothing else in it is specific to that model: it only uses standard macOS audio controls. To try another USB microphone, change the name in this line of `SoloCast.swift` and rebuild:

```swift
let found = findDevice(named: "SoloCast")
```

Devices that do not expose gain or mute to macOS will show those controls without effect.

## Known limits

- LED and other NGENUITY-only options are not supported. They use an undocumented USB protocol.
- The app does not start at login.
- Compressor ratio, attack and release are fixed.
- macOS may ask for microphone access again after each rebuild.
- Changing the sample rate interrupts audio for about a second.
- Not tested for long recordings; listen for clicks or drift before relying on it.

## How it works

- Hardware settings go through CoreAudio device properties.
- Audio runs through `AVAudioEngine`: microphone, EQ, Apple's dynamics processor (its expander is the gate), then the output.
- `AVAudioEngine` cannot use two different devices for input and output, so the app joins the mic and BlackHole into one private aggregate device. It is hidden from other apps and removed when the app quits.

Everything is in one file, `SoloCast.swift`. `build.sh` compiles it into `SoloCast.app`.
