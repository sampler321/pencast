# PenCast: a Windows pen tablet as a pressure tablet for your Mac

Use a Surface (or any Windows tablet with a pen) as a real drawing tablet for macOS apps such as Photoshop and
Illustrator: pressure, tilt, the barrel button and the eraser end arrive on the Mac as genuine tablet events, while
the Mac's screen is streamed back to the tablet with Sunshine and Moonlight.

```
Surface pen (raw HID) --> PenCast.exe --UDP 47555--> PenRelay (Mac) --> macOS tablet events --> Photoshop
Mac screen --> Sunshine --> Moonlight on the Surface
```

## What it does

- **Pen**: position, pressure, tilt (when the pen has it), barrel button, eraser end, proximity (hover), as macOS
  tablet proximity and pointer events, so apps unlock their pressure and tilt features.
- **Only while Moonlight is in front**: PenCast forwards pen and touch only while the Moonlight window is active, so
  the pen works normally in Windows the moment you switch away or quit Moonlight.
- **Touch**: one or two fingers pan, pinch zooms (Photoshop: Zoom In / Zoom Out steps), two-finger tap undo,
  three-finger tap redo. Palm rejection: touch is ignored while the pen is near.
- **Barrel button**: held = Option (in Photoshop a tap picks the colour under the pen).
- **Stroke clean-up**: light smoothing and removal of the backward hook pens make on lift-off.
- **Optional, with InkStudio for Photoshop** ([inkstudio-photoshop](https://github.com/sampler321/inkstudio-photoshop)):
  a per-brush pressure curve and switches for what the pen sends (pressure, tilt, button, eraser), read from the
  plugin's data folder; PenRelay also reports which inputs your pen actually has.

## Setup

**Mac**

1. `mac/build.sh` (needs the Xcode command line tools).
2. Give the terminal you start it from **Accessibility** permission (System Settings > Privacy & Security), so
   PenRelay may post input events.
3. Install [Sunshine](https://github.com/LizardByte/Sunshine) and set `mouse = disabled` in its config, otherwise the
   pen arrives twice (once without pressure).
4. Double-click `mac/Pen Tablet Host.command` (starts PenRelay and Sunshine). `Pen Tablet Stop.command` stops both.

**Windows tablet**

1. Copy the `windows` folder to the tablet, run `build.cmd` (uses the C# compiler that ships with Windows).
2. Install [Moonlight](https://moonlight-stream.org) and pair it with Sunshine on the Mac.
3. Edit `MacPenTablet.cmd`: set `MAC=` to your Mac (`name.local`, LAN IP and/or Tailscale IP, separated by `+`) and
   `MOONLIGHT_HOST=` to the Mac's name in Moonlight.
4. Run `MacPenTablet.cmd` to start; `MacPenTabletStop.cmd` ends PenCast and Moonlight.

UDP port 47555 must be reachable from the tablet to the Mac (LAN or Tailscale both work). Avoid 47999: that is
Sunshine's control port.

## Notes

- Tilt: the Surface Pro 3 pen sends pressure, button and eraser but no tilt; newer Surface Pens send tilt.
- Illustrator integration (scripted pinch zoom and undo) expects InkStudio for Illustrator's `host.jsx`; set
  `PENRELAY_AI_HOST` to its path, or ignore it: other apps use plain shortcuts.

## License

MIT
