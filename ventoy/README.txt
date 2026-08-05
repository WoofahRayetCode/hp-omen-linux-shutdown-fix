# Ventoy helper folder

Copy the contents of this folder to the root of your Ventoy data partition.

## Place these files at the Ventoy root

- `autounattend.xml`
- `install-windows.ps1`
- `install-linux.sh`
- your Windows ISO
- your Linux ISO

## Ventoy config location

Ventoy's own config file must be placed at:

- `/ventoy/ventoy.json`

## Notes

- `autounattend.xml` is for Windows Setup, not Ventoy.
- `ventoy.json` is for Ventoy itself.
- The minimal config here is just to keep Ventoy in a simple default menu mode.
