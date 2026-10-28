# boot-to-windows

Dual-boot helper for **Linux Mint**, Ubuntu and Debian.

- Turning the PC on goes **straight into Linux**, with no boot menu.
- A **Restart to Windows** icon (and a `boot-to-windows` command) reboots into Windows **once**.
- The next restart goes back to Linux automatically.

No more tapping F11 or racing a GRUB menu.

## Requirements

- Linux Mint 21+/22+, Ubuntu 22.04+ or Debian 12+, using GRUB
- UEFI boot (any PC from the last ~10 years)
- Windows already installed, with **Fast Startup turned off** in Windows
  (Command Prompt as admin: `powercfg /h off`)
- In the BIOS, your Linux entry (usually called **ubuntu**) set as **Boot Option #1**

## Install

One line:

```bash
curl -fsSL https://raw.githubusercontent.com/Mrmoody1/boot-to-windows/main/boot-to-windows-setup.sh -o boot-to-windows-setup.sh && sudo bash boot-to-windows-setup.sh install
```

Or download the repo as a ZIP (green **Code** button → **Download ZIP**), unzip it, open a terminal in the folder and run:

```bash
sudo bash boot-to-windows-setup.sh install
```

The installer:

1. Sets GRUB to boot Linux by default with the menu hidden.
2. Finds your Windows entry automatically.
3. Installs the `boot-to-windows` command, a **Restart to Windows** entry in the app menu, and a desktop icon.

### Options

| Option | What it does |
|---|---|
| `--fix-clock` | Stops the clock being an hour out after using Windows |
| `--menu-timeout 5` | Show the boot menu for 5 seconds instead of hiding it |
| `--entry "NAME"` | Use a specific Windows entry (if you have more than one) |
| `--no-desktop-icon` | Only add it to the app menu, not the desktop |

Example: `sudo bash boot-to-windows-setup.sh install --fix-clock`

## Use it

- **Double-click "Restart to Windows"** on the desktop (or find it in the app menu), confirm, enter your password.
- Or in a terminal: `boot-to-windows`
- Test without rebooting: `boot-to-windows --dry-run`

To get back to Linux, just restart Windows normally.

**Backup ways into Windows:** tap **Esc** just after the BIOS logo to show the GRUB menu, or use your motherboard's boot menu key (F11 on MSI, F12 on most others).

## Check / uninstall

```bash
sudo bash boot-to-windows-setup.sh status      # what's installed, Windows entries, boot order
sudo bash boot-to-windows-setup.sh uninstall   # removes everything it added
```

## Troubleshooting

**"No Windows entry found"**
Run `sudo update-grub`. It should print `Found Windows Boot Manager`. If not, make sure Fast Startup is off in Windows, then re-run the installer.

**It always boots into Windows**
Your BIOS is starting Windows instead of GRUB. Set **ubuntu** as Boot Option #1 (MSI: under *UEFI Hard Disk Drive BBS Priorities*). Windows updates sometimes change this back.

**The boot menu still shows up**
After a failed or interrupted boot, GRUB deliberately shows the menu once so you can recover. A normal restart hides it again.

**Desktop icon won't open**
Right-click it → **Allow Launching**.

**Already set this up by hand?**
The installer's settings load last, so they take priority. You can delete an old manual script such as `~/windows.sh` and its desktop icon.

## How it works

- `/etc/default/grub.d/99_zz-boot-to-windows.cfg`: sets `GRUB_DEFAULT=saved`, hidden menu, timeout 0.
- `/etc/grub.d/42_boot-to-windows`: re-applies the hidden menu after `os-prober`. Ubuntu-based distros force the menu on when another OS is found.
- `/usr/local/bin/boot-to-windows`: runs `grub-reboot "<Windows entry>"` then reboots. `grub-reboot` only applies to the *next* boot, which is why it returns to Linux afterwards.
- `/etc/boot-to-windows.conf`: remembers which entry is Windows (by ID, with title and auto-detect as fallbacks).

## License

MIT, see [LICENSE](LICENSE).
