# DRAW — Debugging ROMs Are We

Vendor-baked debug + feature enabler for ROM porting.
No Magisk, no root commands, no manual activation.
Kicks in at `early-init` — before bootanimation, before zygote.
All `persist.draw.*` props survive reboots.

---

## Files

```
vendor/etc/init/init.draw-logging.rc   — init triggers + service definitions
vendor/bin/init.draw-logging.sh        — main setup + runtime prop handler
```

---

## Prop Reference

| Prop | Default | Description |
|------|---------|-------------|
| `persist.draw.enabled` | `1` | Master debug switch (ADB, ro.debuggable, etc) |
| `persist.draw.logging` | `1` | Full audit/kernel logging |
| `persist.draw.selinux` | unset | Set to `permissive` or `enforcing` at runtime |
| `persist.draw.secure` | unset | Enable Play Integrity / SafetyNet prop spoof |
| `persist.draw.dt2w` | unset | Double tap to wake (Transsion/Infinix/Tecno) |
| `persist.draw.otg` | unset | USB OTG toggle |
| `persist.draw.audio_fx` | unset | `0` = disable vendor audio effects |
| `persist.draw.backlight` | unset | `1` = auto-detect max brightness from sysfs |

---

## What `draw-setup` does at boot

- **MTK RIL patch** — binary patches `mtk-ril.so` / `libmtk-ril.so`: `AT+EAIC=2 → AT+EAIC=3`. Fixes incoming calls on non-stock ROM.
- **VNDK lib override** — bind mounts `libbinder`, `libgui_vendor`, `libcutils` from system VNDK to vendor. Prevents linker/SurfaceFlinger crashes.
- **fixSPL / keymaster patch** — binary patches keymaster `.so` files to read redirect props (`ro.keymaster.xxx.*`) instead of real build props. Needed for banking apps and Play Integrity.
- **Samsung keylayout injection** — injects `gpio_keys.kl`, `sec_touchscreen.kl`, `sec_touchkey.kl` for correct volume/power/back input on Samsung vendor.
- **DT2W keylayout fix** — patches `mtk-tpd.kl`: `key 183 F13 → WAKEUP` for Transsion DT2W kernel event.
- **Samsung vendor overlay wipe** — wipes `/vendor/overlay`, replaces with `/system/mystic/vo` if present. Prevents Samsung overlay conflicts.
- **Samsung sysfs perms** — fixes ownership/context on TSP, backlight, FOD, rear flash nodes so Samsung HALs can write them.
- **Fingerprint/device spoof** — copies vendor build identity props to system namespace.
- **Vibrator sysfs setup** — fixes permissions on MTK vibrator nodes.
- **FRP node perms** — fixes Factory Reset Protection partition ownership.

---

## Implementation

**`vendor/etc/selinux/vendor_sepolicy.cil`** — append:
```
(allow vendor_init selinuxfs (file (write)))
(allow vendor_init kernel (security (setenforce)))
```

**`vendor/etc/selinux/file_contexts`** — append:
```
/vendor/etc/init/init\.draw-logging\.rc  u:object_r:vendor_configs_file:s0
/vendor/bin/init\.draw-logging\.sh       u:object_r:vendor_file:s0
```

**`vendor/build.prop`** — append (optional, sets defaults):
```
persist.draw.enabled=1
persist.draw.logging=1
```

---

## Runtime Usage

```sh
# Toggle SELinux without reboot
setprop persist.draw.selinux permissive
setprop persist.draw.selinux enforcing

# Enable DT2W (Infinix HOT 50 / X6882)
setprop persist.draw.dt2w 1

# Enable USB OTG
setprop persist.draw.otg 1

# Disable vendor audio effects (fix crackling)
setprop persist.draw.audio_fx 0

# Enable Play Integrity spoof
setprop persist.draw.secure 1

# Pull boot log
adb pull /data/log/boot_draw.txt
```
