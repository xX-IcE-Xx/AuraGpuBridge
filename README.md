# AuraGpuBridge

Sync ASUS Aura / Armoury Crate lighting to an MSI GeForce RTX 4090 Gaming X Trio —
a card Armoury Crate cannot control natively, since Aura Sync only supports
ASUS/Aura-partner hardware.

No OpenRGB, SignalRGB, or MSI Center required at runtime: this is a small
PowerShell + C# bridge that reads what Armoury Crate is currently displaying and
drives the card's RGB controller directly over the GPU's own I2C bus via NVAPI.

## How it works

- **`MsiGpuRgb.cs`** — talks to the card's ITE9 RGB controller (I2C address `0x68`
  on the GPU's NVAPI I2C port 1) through `nvapi64.dll`. Compiled in-memory by
  PowerShell's `Add-Type`; no SDK or build step needed. The register protocol is
  derived from [OpenRGB](https://openrgb.org)'s `MSIGPUv2Controller` (GPL-2.0).
- **`Bridge.ps1`** — the watch loop:
  - Watches `C:\ProgramData\ASUS\RogAura30\SetV2EngineScript.xml`, which Armoury
    Crate rewrites whenever you change effect or color. Parses the effect name and
    HSL color, and maps it to the closest GPU hardware mode (the card is a single
    RGB zone with fixed hardware effects, so animated Aura effects use a nearest
    equivalent — see the mapping table below).
  - Tails `C:\ProgramData\ASUS\ARMOURY CRATE Diagnosis\OptionHAL\EneHal.log` to
    detect the global lighting on/off toggle: the ASUS ENE DRAM HAL streams
    per-LED frames there while lighting is on, and "off" appears as all-black
    frames followed by silence. Expect roughly a 10-second lag on off/on.
  - Saves state to the controller's flash on change, so the card powers up already
    matching your scheme before Windows loads.
  - Logs decisions to `bridge.log` (self-trims at 512 KB).

### Effect mapping

| Aura effect          | GPU hardware mode |
|----------------------|-------------------|
| Static               | Static            |
| Breathing            | Breathing         |
| Strobing             | Flashing          |
| Rainbow / Wave       | Rainbow wave      |
| Color Cycle          | Color cycle       |
| Comet                | Meteor            |
| Starry Night         | Breathing         |
| anything else        | Static (effect's color) |

Tweak it in the `switch` table inside `Apply-ToGpu` in `Bridge.ps1`.

## Requirements

- MSI GeForce RTX 4090 Gaming X Trio (PCI subsystem `1462:5103`). Other MSI
  40/50-series cards using the same ITE9 ("MSI GPU v2") controller very likely
  work too — change the subsystem check in `MsiGpuRgb.cs` (`Connect()`); see
  OpenRGB's `MSIGPUv2ControllerDetect.cpp` for the full list of known IDs.
- ASUS motherboard with Armoury Crate (tested: ROG Crosshair X870E Hero,
  Armoury Crate 6.5.7, Aura 3.0 / `RogAura30` plugin).
- Windows 11, PowerShell 7, NVIDIA driver (provides `nvapi64.dll`).

## Install

```powershell
git clone https://github.com/<you>/AuraGpuBridge
cd AuraGpuBridge
.\Bridge.ps1 -Once     # test: applies the current Aura state to the GPU once
.\Install-Task.ps1     # register the hidden autostart scheduled task
```

Remove with `Unregister-ScheduledTask AuraGpuBridge` .

## Utilities

- `Set-GpuColor.ps1 -R 255 -G 0 -B 0` — manually set a static color (stop the
  bridge first, or it will overwrite within 5 minutes).
- `Probe-I2c.ps1` — sanity check that the RGB controller ACKs at address 0x68.

## Caveats

- Reverse-engineered against Armoury Crate 6.5.7's on-disk files; an ASUS update
  that changes those formats will break parsing (check `bridge.log`).
- Don't run alongside OpenRGB / SignalRGB / MSI Center — two writers, one
  controller.
- I2C writes go to the card's RGB controller only, using the same transactions
  OpenRGB ships for this exact device — but as with anything that pokes hardware
  registers: use at your own risk.

## Credits & license

GPL-2.0-or-later (see `LICENSE`). The ITE9 register protocol comes from the
[OpenRGB](https://gitlab.com/CalcProgrammer1/OpenRGB) project's
`MSIGPUv2Controller` by Wojciech Lazarski and contributors — this tool exists
because of their reverse-engineering work.
