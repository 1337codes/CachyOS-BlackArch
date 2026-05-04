# Z13 CachyOS Setup

Post-install script for ASUS ROG Flow Z13 (GZ302EA, 2025) on CachyOS Linux.

Replays everything needed to get a working Z13: hardware fixes, kernel parameters, Bluetooth, BlackArch pentest tools, Joplin for documentation.

## Usage

```bash
curl -fsSL -O https://raw.githubusercontent.com/<you>/z13-setup/main/z13-cachyos-setup.sh
chmod +x z13-cachyos-setup.sh
./z13-cachyos-setup.sh           # interactive
./z13-cachyos-setup.sh --yes     # non-interactive
```

Reboot when done.

## What it does

- GZ302 hardware fixes via [th3cavalry/GZ302-Linux-Setup](https://github.com/th3cavalry/GZ302-Linux-Setup)
- Limine kernel params: `amd_pstate=guided`, `rtc_cmos.use_acpi_alarm=1`, `amdgpu.dcdebugmask=0x600`
- Bluetooth `AutoEnable=true`
- MT7925 WiFi ASPM workaround
- Masks broken `asusd` (z13ctl replaces it)
- BlackArch repo + officials metapackage
- Joplin + pandoc + LaTeX for reporting
- Distrobox + podman (optional Kali container)
- Snapper baseline snapshot

## Flags

| Flag | Purpose |
|---|---|
| `-y`, `--yes` | Accept all defaults |
| `--skip-gz302` | Skip GZ302 hardware fixes |
| `--skip-blackarch` | Skip BlackArch repo |
| `--skip-pentest` | Skip pentest tools |
| `--skip-joplin` | Skip Joplin + docs |
| `-h`, `--help` | Show help |

## Requirements

- CachyOS Linux (Arch-based)
- Kernel ≥ 6.19 (tested on 7.0.3)
- Limine bootloader (CachyOS default)
- ~20 GB free disk space
- Active network connection

Idempotent — safe to re-run. Creates timestamped backups before editing config files.

Log: `/tmp/z13-cachyos-setup-<date>.log`

## License

MIT
