# minui-dreamcast.pak

A MinUI Emu Pak for Dreamcast, wrapping the standalone `flycast` Dreamcast emulator (version `7d64554`).

## Requirements

This pak is designed and tested on the following MinUI Platforms and devices:

- `tg5040`: Trimui Brick (formerly `tg3040`)
- `h700`: Anbernic H700 devices (RG35XX/RG40XX series) running NextUI

Use the correct platform for your device.

## Installation

1. Mount your MinUI SD card.
2. Download the latest release from Github. It will be named `DC.pak.zip`.
3. Copy the zip file to `/Emus/$PLATFORM/DC.pak.zip`.
4. Extract the zip in place, then delete the zip file.
5. Confirm that there is a `/Emus/$PLATFORM/DC.pak/launch.sh` file on your SD card.
6. Create a folder at `/Roms/Sega Dreamcast (DC)` and place your roms in this directory.
7. Copy your BIOS files to `/BIOS/DC`. The paths are as follows
    1. Dreamcast: `/BIOS/DC/dc_boot.bin`
    2. Naomi: `/BIOS/DC/naomi.zip`
8. Unmount your SD Card and insert it into your MinUI device.

## Usage

Browse to `Sega Dreamcast` and press `A` to play a game.

The following filetypes are supported:

- Native: `.cdi`, `.chd`, `.cue and .bin`, `.gdi and .bin.`

### Controller Layouts

#### Default Controller Layout

Dreamcast Controller Keys:

| Hardware Button | Dreamcast Mapping |
|-----------------|-------------|
| `L1`            | `L`         |
| `R1`            | `R`         |
| `A`             | `B`         |
| `B`             | `A`         |
| `X`             | `Y`         |
| `Y`             | `X`         |

| Action                  | Hardware Combination   |
|-------------------------|------------------------|
| MinUI Menu Resume State | `X`                    |
| Quit Game               | `MENU`                 |
| Flycast Menu            | `SELECT`               |
| Fast Forward            | `R2`                   |
| Load State              | `L3`, or `HOTKEY 1`    |
| Save State              | `R3`, or `HOTKEY 2`    |
| Screenshot              | `L2`                   |

### Emulator settings

To change emulator settings, press and hold the `R2` button while selecting/resuming a game to play. Hold R2 until a menu appears.

If the `B` or `MENU` buttons are pressed, the user is returned to the MinUI game selection screen. Settings are managed on a per-game basis, and can be saved for future gameplay, or the game can be started with the current settings as is.

To start a game in this menu, press the `X` button. Any settings currently selected will be used for the game session.

Settings in this menu can be saved by selecting `Save settings for game` and pressing the `A` button. This will save the settings and bring the user back to the menu. The `X` button can be pressed to start the game.

This pak also ships with some default Flycast settings. Users may edit these settings in the in-emulator settings menu, and they will persist across game sessions. To reset these settings to the ones shipped with Flycast, select `Re-apply default flycast settings` and press the `A` button.

#### Controller Layout

Allows changing between controller layouts.

- default: `default`
- options: `default`, `custom`

If `default` is set, the pak will reset the settings to the built-in controller mapping on boot.

Flycast names its mapping file after the SDL joystick name, which is not the same
on every platform, so the pak writes the layout under the name flycast reads on
`h700`.

When `custom` is selected, users will be allowed to customize their controller layout and have that persist across game starts. These settings will also be stored in a per-game path, and restored when that same game is played again.

#### CPU Mode

Allows changing the CPU Mode the emulator uses at runtime.

- default: `performance`
- options: `ondemand`, `performance`

#### DPAD Mode

Allows changing how the dpad is used in game.

- default: `dpad`
- options: `dpad`, `joystick`, `joystick and dpad`, `joystick on f2`

> [!NOTE]
> On `h700` only `dpad` and `joystick` are offered. The other two modes need
> Trimui's `trimui_inputd`, which h700 does not have.
>
> `joystick` is also applied differently. On `tg5040` the input daemon redirects
> the dpad to the stick. On `h700` the pak rewrites the flycast mapping instead,
> and what it writes depends on whether the model has an analog stick:
>
> - **With a stick** (`rg34xxsp`, `rg35xxh`, `rg35xxpro`, `rg40xxh`, `rg40xxv`,
>   `rgcubexx`) the two are exchanged: the dpad drives the Dreamcast analog
>   stick and the physical stick drives the Dreamcast dpad. Use the stick to
>   navigate the flycast menu while this mode is on.
> - **Without a stick** the dpad drives the Dreamcast analog stick, and nothing
>   is left to drive the Dreamcast dpad. Flycast's own menu only moves between
>   items on dpad or arrow key input, so the pak also mirrors the dpad onto the
>   arrow keys of a virtual keyboard while this mode is on, which keeps that
>   menu usable. See [Dpad mirroring](#dpad-mirroring).

#### Dpad mirroring

> [!NOTE]
> This applies to `h700` models without an analog stick, in `joystick` DPAD
> Mode, and to nothing else.

`gptokeyb2` mirrors the dpad onto the arrow keys of a virtual keyboard it
creates, so that flycast's own menu can still be navigated while the dpad is
driving the Dreamcast analog stick. It reads the pad through SDL and never grabs
it, so flycast keeps receiving the dpad as well. The mapping it uses is
`config/dpad-arrows.gptk`, which clears gptokeyb2's defaults and binds only the
four directions.

Three details make this work, and all of them are specific to NextUI on `h700`:

- NextUI's SDL is built without libudev, so SDL opens no keyboard at all unless
  `SDL_EVDEV_DEVICES` names one. The pak starts gptokeyb2, waits for its device
  to appear, and sets that variable before launching flycast.
- Flycast's built-in keyboard mapping binds the arrow keys to the Dreamcast
  dpad, which would make the dpad drive the analog stick and the dpad at once.
  While the mirror is running the pak gives the keyboard a mapping with no
  bindings, at `$FLYCAST_CONFIG_DIR/mappings/SDL_Keyboard.cfg`. It is removed
  again afterwards, and only ever when the pak wrote it.
- gptokeyb2 names its keyboard differently between releases, `Fake Keyboard` in
  older builds and `Fake Keyboard Mouse` in current ones, and also creates a
  mouse device, so the pak matches on the name's prefix rather than the whole
  name.

If the mirror cannot be started the mode still works, but flycast's menu cannot
be navigated until DPAD Mode is set back to `dpad`.

#### Widescreen Mode

> [!NOTE]
> See [this document](https://forums.launchbox-app.com/topic/65672-169-sega-dreamcast-via-flycast-norms-true-anamorphic-widescreen-project/) for details on how Dreamcast handles widescreen mode.

Allows toggling between widescreen modes

- default: `off`
- options: `off`, `on`, `cheat`

### Save states

In addition to in-game saves, this pak supports a single save state. Save states are stored in `$SDCARD_PATH/.userdata/shared/DC-flycast`

### Screenshots

Screenshots are written to `/Screenshots` with a sanitized version of the rom name as the screenshot prefix.

### Sleep Mode

Built-in MinUI cores have support for turning off the display and eventually shutting down when the power button is pressed. Standalone emulators do not have this functionality due to needing support inside of the console for this. At this time, this pak does not implement sleep mode.

### Debug Logging

Debug logs are written to the`$SDCARD_PATH/.userdata/$PLATFORM/logs/` folder.

## Screenshots

| Name               | Image                                                     |
|--------------------|-----------------------------------------------------------|
| Emulator Settings  | <img src="screenshots/emulator-settings.png" width=240 /> |
