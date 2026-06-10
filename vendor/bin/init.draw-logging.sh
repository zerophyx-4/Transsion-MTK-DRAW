#!/vendor/bin/sh
# =============================================================================
# DRAW — Debugging ROMs Are We
# init.draw-logging.sh
#
# Main setup + runtime prop handler script.
# Called by init.draw-logging.rc via:
#   - "setup"          : full boot-time setup (RIL, VNDK, SPL, keylayout, etc)
#   - "dt2w_enable"    : enable double tap to wake
#   - "dt2w_disable"   : disable double tap to wake
#   - "otg_enable"     : enable USB OTG
#   - "otg_disable"    : disable USB OTG
#   - "audio_fx_enable"  : re-enable vendor audio effects
#   - "audio_fx_disable" : disable vendor audio effects
#   - "backlight_scale"  : auto-detect and set backlight range
#   - "secure_enable"    : spoof Play Integrity / SafetyNet props
# =============================================================================

set -o pipefail

CMD="$1"

# =============================================================================
# HELPERS
# =============================================================================

log() {
    echo "[DRAW] $1" >> /data/log/boot_draw.txt
    echo "[DRAW] $1"
}

# copyprop <dst> <src>
# Copy prop from src to dst only if src is non-empty
copyprop() {
    local val
    val="$(getprop "$2")"
    [ -n "$val" ] && resetprop "$1" "$val"
}

# restartAudio — restart audioserver and all audio HAL variants
restartAudio() {
    log "Restarting audio services"
    setprop ctl.restart audioserver
    local audioHal
    audioHal="$(getprop | sed -nE 's/.*init\.svc\.(.*audio-hal[^]]*).*/\1/p')"
    [ -n "$audioHal" ] && setprop ctl.restart "$audioHal"
    setprop ctl.restart vendor.audio-hal-2-0
    setprop ctl.restart audio-hal-2-0
}

# =============================================================================
# RUNTIME HANDLERS — called on-demand via exec from init
# =============================================================================

# -----------------------------------------------------------------------------
# DOUBLE TAP TO WAKE — THIS IS VERY IMPORTANT FOR INFINIX HOT 50 (X6882)
# Transsion kernel exposes /proc/gesture_function
# cc1 = tap to wake, cc2 = full gesture suite
# Fallback: standard oppo /proc/touchpanel/double_tap_enable
# Also fixes mtk-tpd.kl: key 183 (F13) must be WAKEUP not F13
# -----------------------------------------------------------------------------
do_dt2w_enable() {
    log "DT2W: enabling"

    # Transsion / Infinix / Tecno kernel interface
    if [ -f /proc/gesture_function ]; then
        echo cc1 > /proc/gesture_function
        log "DT2W: wrote cc1 to /proc/gesture_function"
        return
    fi

    # Oppo / Realme fallback
    if [ -f /proc/touchpanel/double_tap_enable ]; then
        echo 1 > /proc/touchpanel/double_tap_enable
        log "DT2W: wrote 1 to /proc/touchpanel/double_tap_enable"
        return
    fi

    # Xiaomi proc node fallback
    for node in /proc/touchpanel/wakeup_gesture /proc/tp_wakeup_gesture /proc/tp_gesture; do
        if [ -f "$node" ]; then
            echo 1 > "$node"
            log "DT2W: wrote 1 to $node"
            return
        fi
    done

    log "DT2W: no known gesture node found"
}

do_dt2w_disable() {
    log "DT2W: disabling"
    [ -f /proc/gesture_function ] && echo cc0 > /proc/gesture_function && return
    [ -f /proc/touchpanel/double_tap_enable ] && echo 0 > /proc/touchpanel/double_tap_enable && return
    for node in /proc/touchpanel/wakeup_gesture /proc/tp_wakeup_gesture /proc/tp_gesture; do
        [ -f "$node" ] && echo 0 > "$node" && return
    done
    log "DT2W: no known gesture node found"
}

# -----------------------------------------------------------------------------
# USB OTG — THIS IS VERY IMPORTANT FOR INFINIX HOT 50 (X6882)
# Transsion sysfs: find /sys/ -path *tran_battery/OTG_CTL
# Fallback: standard /sys/class/power_supply/usb/otg_switch
# -----------------------------------------------------------------------------
do_otg_enable() {
    log "OTG: enabling"
    local otg_path
    otg_path=$(find /sys/ -path "*tran_battery/OTG_CTL" 2>/dev/null | head -n 1)
    if [ -n "$otg_path" ]; then
        echo 1 > "$otg_path"
        log "OTG: wrote 1 to $otg_path"
        return
    fi
    if [ -e /sys/class/power_supply/usb/otg_switch ]; then
        echo 1 > /sys/class/power_supply/usb/otg_switch
        log "OTG: wrote 1 to /sys/class/power_supply/usb/otg_switch"
        return
    fi
    log "OTG: no known OTG node found"
}

do_otg_disable() {
    log "OTG: disabling"
    local otg_path
    otg_path=$(find /sys/ -path "*tran_battery/OTG_CTL" 2>/dev/null | head -n 1)
    if [ -n "$otg_path" ]; then
        echo 0 > "$otg_path"
        return
    fi
    [ -e /sys/class/power_supply/usb/otg_switch ] && echo 0 > /sys/class/power_supply/usb/otg_switch
}

# -----------------------------------------------------------------------------
# AUDIO EFFECTS — bind mount empty file over libvolumelistener.so
# Fixes crackling / distortion / HAL crash on mismatched vendor audio
# -----------------------------------------------------------------------------
do_audio_fx_disable() {
    log "Audio FX: disabling vendor soundfx"
    mount /system/phh/empty /vendor/lib/soundfx/libvolumelistener.so 2>/dev/null || true
    mount /system/phh/empty /vendor/lib64/soundfx/libvolumelistener.so 2>/dev/null || true
    resetprop ro.audio.ignore_effects true
    restartAudio
}

do_audio_fx_enable() {
    log "Audio FX: re-enabling vendor soundfx"
    umount /vendor/lib/soundfx/libvolumelistener.so 2>/dev/null || true
    umount /vendor/lib64/soundfx/libvolumelistener.so 2>/dev/null || true
    resetprop --delete ro.audio.ignore_effects 2>/dev/null || true
    restartAudio
}

# -----------------------------------------------------------------------------
# BACKLIGHT SCALE — IMPORTANT FOR ONE UI
# One UI and some vendor HWComposers expect max brightness to be known
# Reads sysfs max_brightness and stores it so SurfaceFlinger can scale correctly
# -----------------------------------------------------------------------------
do_backlight_scale() {
    log "Backlight: auto-detecting max brightness"
    local max_bl=""

    for node in \
        /sys/class/leds/lcd-backlight/max_brightness \
        /sys/class/backlight/panel0-backlight/max_brightness \
        /sys/class/backlight/sprd_backlight/max_brightness; do
        if [ -f "$node" ]; then
            max_bl="$(cat "$node")"
            log "Backlight: found $max_bl at $node"
            break
        fi
    done

    if [ -n "$max_bl" ]; then
        setprop persist.sys.qcom-brightness "$max_bl"
        log "Backlight: set persist.sys.qcom-brightness=$max_bl"
    else
        log "Backlight: no sysfs node found, skipping"
    fi
}

# -----------------------------------------------------------------------------
# SECURE MODE — VERY IMPORTANT FOR ONE UI
# Copies vendor build props -> system props so ROM appears as the vendor device
# Sets verified boot state to green so Play Integrity passes
# Without this: Knox init fails, Samsung Pay won't open, Play Integrity fails
# -----------------------------------------------------------------------------
do_secure_enable() {
    log "Secure mode: applying prop spoof"

    copyprop ro.build.device             ro.vendor.build.device
    copyprop ro.system.build.fingerprint ro.vendor.build.fingerprint
    copyprop ro.bootimage.build.fingerprint ro.vendor.build.fingerprint
    copyprop ro.build.fingerprint        ro.vendor.build.fingerprint
    copyprop ro.product.device           ro.vendor.product.device
    copyprop ro.product.system.device    ro.vendor.product.device
    copyprop ro.product.device           ro.product.vendor.device
    copyprop ro.product.system.device    ro.product.vendor.device
    copyprop ro.product.system.name      ro.vendor.product.name
    copyprop ro.product.name             ro.vendor.product.name
    copyprop ro.product.system.brand     ro.vendor.product.brand
    copyprop ro.product.brand            ro.vendor.product.brand
    copyprop ro.product.system.model     ro.vendor.product.model
    copyprop ro.product.model            ro.vendor.product.model
    copyprop ro.product.manufacturer     ro.vendor.product.manufacturer
    copyprop ro.product.system.manufacturer ro.vendor.product.manufacturer
    copyprop ro.build.product            ro.vendor.product.model

    # Security patch: take the newer of vendor vs keymaster
    local spl
    spl="$( (getprop ro.vendor.build.security_patch; getprop ro.keymaster.xxx.security_patch) \
        | sort | tail -n 1 )"
    [ -n "$spl" ] && resetprop ro.build.version.security_patch "$spl"

    # Verified boot spoof — makes Play Integrity see a "clean" device
    resetprop ro.build.tags             release-keys
    resetprop ro.boot.vbmeta.device_state locked
    resetprop ro.boot.verifiedbootstate green
    resetprop ro.boot.flash.locked      1
    resetprop ro.boot.veritymode        enforcing
    resetprop ro.boot.warranty_bit      0
    resetprop ro.warranty_bit           0
    resetprop ro.debuggable             0
    resetprop ro.secure                 1
    resetprop ro.build.type             user
    resetprop ro.build.selinux          0
    resetprop ro.adb.secure             1

    log "Secure mode: done"
}

# =============================================================================
# SETUP — full boot-time setup, runs once at post-fs-data
# =============================================================================

do_setup() {
    log "=============================="
    log "DRAW setup starting"
    log "=============================="

    local vndk
    vndk="$(getprop persist.sys.vndk)"
    [ -z "$vndk" ] && vndk="$(getprop ro.vndk.version | grep -oE '^[0-9]+')"
    log "VNDK version: $vndk"

    # --------------------------------------------------------------------------
    # TMPFS WORKSPACE
    # All patched files go here before bind mounting back
    # --------------------------------------------------------------------------
    mkdir -p /mnt/draw
    mount -t tmpfs -o rw,nodev,relatime,mode=755,gid=0 none /mnt/draw || true
    mkdir -p /mnt/draw/empty_dir
    touch /mnt/draw/empty

    # --------------------------------------------------------------------------
    # MTK RIL BINARY PATCH — THIS IS VERY IMPORTANT FOR ALL MTK PORTS
    # AT+EAIC=2 blocks incoming calls on non-stock ROM
    # AT+EAIC=3 allows incoming calls to work correctly
    # Without this: phone rings but cannot answer, or calls silently drop
    # --------------------------------------------------------------------------
    log "RIL: patching mtk-ril AT+EAIC"
    for f in \
        /vendor/lib/mtk-ril.so \
        /vendor/lib64/mtk-ril.so \
        /vendor/lib/libmtk-ril.so \
        /vendor/lib64/libmtk-ril.so; do
        [ ! -f "$f" ] && continue
        local ctxt b
        ctxt="$(ls -lZ "$f" | grep -oE 'u:object_r:[^:]*:s0')"
        b="/mnt/draw/$(echo "$f" | tr / _)"
        cp -a "$f" "$b"
        sed -i 's/AT+EAIC=2/AT+EAIC=3/g' "$b"
        chcon "$ctxt" "$b"
        mount -o bind "$b" "$f"
        log "RIL: patched $f"
        setprop persist.sys.draw.ril_patched true
    done

    # --------------------------------------------------------------------------
    # VNDK LIBRARY OVERRIDE — THIS IS VERY IMPORTANT FOR ALL PORTS
    # Vendor .so files are often compiled against older VNDK versions
    # Override with matching system VNDK versions to prevent linker crashes
    # libbinder / libgui mismatch = SurfaceFlinger crash, black screen
    # libcutils mismatch = random HAL crashes
    # --------------------------------------------------------------------------
    log "VNDK: overriding vendor libs with system VNDK $vndk"
    if [ -n "$vndk" ]; then
        mount -o bind /system/lib/vndk-"$vndk"/libgui.so    /vendor/lib/libgui_vendor.so   2>/dev/null || true
        mount -o bind /system/lib64/vndk-"$vndk"/libgui.so  /vendor/lib64/libgui_vendor.so 2>/dev/null || true
        mount -o bind /system/lib/vndk-"$vndk"/libbinder.so /vendor/lib/libbinder.so       2>/dev/null || true
        mount -o bind /system/lib64/vndk-"$vndk"/libbinder.so /vendor/lib64/libbinder.so   2>/dev/null || true
        mount -o bind /system/lib/vndk-"$vndk"/libbinder.so /vendor/lib/vndk/libbinder.so  2>/dev/null || true
        mount -o bind /system/lib64/vndk-"$vndk"/libbinder.so /vendor/lib64/vndk/libbinder.so 2>/dev/null || true
        mount -o bind /system/lib/vndk-sp-"$vndk"/libcutils.so /vendor/lib/libcutils.so    2>/dev/null || true
        mount -o bind /system/lib64/vndk-sp-"$vndk"/libcutils.so /vendor/lib64/libcutils.so 2>/dev/null || true
        mount -o bind /system/lib/vndk-sp-"$vndk"/libcutils.so /vendor/lib/vndk-sp/libcutils.so 2>/dev/null || true
        mount -o bind /system/lib64/vndk-sp-"$vndk"/libcutils.so /vendor/lib64/vndk-sp/libcutils.so 2>/dev/null || true
        log "VNDK: override complete"
    else
        log "VNDK: version unknown, skipping override"
    fi

    # --------------------------------------------------------------------------
    # FIX SPL / KEYMASTER — IMPORTANT FOR ONE UI AND BANKING APPS
    # Keymaster HAL reads ro.build.version.release and ro.product.model
    # On GSI/ported ROM these differ from what keymaster was compiled against
    # Binary-patch the .so to read redirect props instead
    # Without this: keymaster may refuse to initialize, breaking fingerprint unlock
    # --------------------------------------------------------------------------
    log "SPL: fixing keymaster prop redirects"
    local img Arelease spl_val
    img="$(find /dev/block -type l -iname "kernel$(getprop ro.boot.slot_suffix)" 2>/dev/null | grep by-name | head -n 1)"
    [ -z "$img" ] && img="$(find /dev/block -type l -iname "boot$(getprop ro.boot.slot_suffix)" 2>/dev/null | grep by-name | head -n 1)"

    if [ -n "$img" ] && command -v getSPL > /dev/null 2>&1; then
        Arelease="$(getSPL "$img" android)"
        spl_val="$(getSPL "$img" spl)"
        [ -n "$Arelease" ] && setprop ro.keymaster.xxx.release "$Arelease"
        [ -n "$spl_val"   ] && setprop ro.keymaster.xxx.security_patch "$spl_val"
        setprop ro.keymaster.xxx.vbmeta_state unlocked
        setprop ro.keymaster.xxx.verifiedbootstate orange
        log "SPL: release=$Arelease spl=$spl_val"
    fi

    if [ "$(getprop ro.product.cpu.abi)" = "armeabi-v7a" ]; then
        setprop ro.keymaster.mod 'AOSP on ARM32'
    else
        setprop ro.keymaster.mod 'AOSP on ARM64'
    fi
    setprop ro.keymaster.brn Android

    for f in \
        /vendor/lib64/hw/android.hardware.keymaster@3.0-impl-qti.so \
        /vendor/lib/hw/android.hardware.keymaster@3.0-impl-qti.so \
        /vendor/bin/teed \
        /vendor/lib/libkeymaster3device.so \
        /vendor/lib64/libkeymaster3device.so \
        /vendor/lib/libMcTeeKeymaster.so \
        /vendor/lib64/libMcTeeKeymaster.so \
        /vendor/lib/hw/libMcTeeKeymaster.so \
        /vendor/lib64/hw/libMcTeeKeymaster.so; do
        [ ! -f "$f" ] && continue
        local ctxt2 b2
        ctxt2="$(ls -lZ "$f" | grep -oE 'u:object_r:[^:]*:s0')"
        b2="/mnt/draw/$(echo "$f" | tr / _)"
        cp -a "$f" "$b2"
        sed -i \
            -e 's/ro.build.version.release/ro.keymaster.xxx.release/g' \
            -e 's/ro.build.version.security_patch/ro.keymaster.xxx.security_patch/g' \
            -e 's/ro.product.model/ro.keymaster.mod/g' \
            -e 's/ro.product.brand/ro.keymaster.brn/g' \
            "$b2"
        chcon "$ctxt2" "$b2"
        mount -o bind "$b2" "$f"
        log "SPL: patched $f"
    done

    # --------------------------------------------------------------------------
    # SAMSUNG KEYLAYOUT — THIS IS VERY IMPORTANT FOR ONE UI
    # One UI uses Samsung-specific key event names in keylayout files
    # Without these: volume keys, back gesture, power button may not work
    # --------------------------------------------------------------------------
    log "Keylayout: checking for Samsung vendor"
    if getprop ro.vendor.build.fingerprint | grep -qiE '^samsung/'; then
        log "Keylayout: Samsung vendor detected, injecting keylayout files"
        cp -a /system/usr/keylayout /mnt/draw/keylayout 2>/dev/null || true

        # Samsung GPIO keys (power, volume)
        [ -f /system/phh/samsung-gpio_keys.kl ] && \
            cp /system/phh/samsung-gpio_keys.kl /mnt/draw/keylayout/gpio_keys.kl && \
            chmod 0644 /mnt/draw/keylayout/gpio_keys.kl

        # Samsung touchscreen (back gesture, swipe)
        [ -f /system/phh/samsung-sec_touchscreen.kl ] && \
            cp /system/phh/samsung-sec_touchscreen.kl /mnt/draw/keylayout/sec_touchscreen.kl && \
            chmod 0644 /mnt/draw/keylayout/sec_touchscreen.kl

        # Samsung touchkey (capacitive back/menu keys)
        [ -f /system/phh/samsung-sec_touchkey.kl ] && \
            cp /system/phh/samsung-sec_touchkey.kl /mnt/draw/keylayout/sec_touchkey.kl && \
            chmod 0644 /mnt/draw/keylayout/sec_touchkey.kl

        mount -o bind /mnt/draw/keylayout /system/usr/keylayout 2>/dev/null || true
        restorecon -R /system/usr/keylayout 2>/dev/null || true
        log "Keylayout: Samsung injection done"
    fi

    # --------------------------------------------------------------------------
    # DT2W KEYLAYOUT FIX — IMPORTANT FOR INFINIX HOT 50 (X6882)
    # Transsion kernel sends key 183 (F13) for double-tap wake event
    # Android input system must map F13 -> WAKEUP or screen won't wake
    # --------------------------------------------------------------------------
    log "Keylayout: patching mtk-tpd.kl for DT2W (key 183 F13 -> WAKEUP)"
    if [ -f /system/usr/keylayout/mtk-tpd.kl ]; then
        cp -a /system/usr/keylayout/mtk-tpd.kl /mnt/draw/mtk-tpd.kl
        sed -i 's/key 183\s*F13/key 183   WAKEUP/g' /mnt/draw/mtk-tpd.kl
        chmod 0644 /mnt/draw/mtk-tpd.kl
        mount -o bind /mnt/draw/mtk-tpd.kl /system/usr/keylayout/mtk-tpd.kl 2>/dev/null || true
        log "Keylayout: mtk-tpd.kl patched"
    fi

    # --------------------------------------------------------------------------
    # SAMSUNG VENDOR OVERLAY WIPE — THIS IS VERY IMPORTANT FOR ONE UI
    # Samsung vendor ships overlays that conflict with AOSP/GSI system
    # These overlays override colors, fonts, and layout in ways that break UI
    # Wipe them and replace with system/mystic/vo if it exists
    # --------------------------------------------------------------------------
    if getprop ro.vendor.build.fingerprint | grep -qiE '^samsung/'; then
        log "Overlay: wiping Samsung vendor overlays"
        mount -o bind /mnt/draw/empty_dir /vendor/overlay 2>/dev/null || true
        [ -d /system/mystic/vo ] && \
            mount -o bind /system/mystic/vo /vendor/overlay 2>/dev/null || true
        log "Overlay: Samsung vendor overlay wiped"
    fi

    # --------------------------------------------------------------------------
    # SAMSUNG SYSFS PERMISSIONS — IMPORTANT FOR ONE UI
    # Samsung HALs (TSP, backlight, FOD, charging) run as non-root
    # but sysfs nodes default to root:root — fix ownership so HALs can write
    # Without this: fingerprint overlay (FOD), ear detect, wireless charging may fail
    # --------------------------------------------------------------------------
    if getprop ro.vendor.build.fingerprint | grep -qiE '^samsung/'; then
        log "Samsung: fixing sysfs permissions"

        for f in \
            /sys/class/lcd/panel/actual_mask_brightness \
            /sys/class/lcd/panel/mask_brightness \
            /sys/class/lcd/panel/device/backlight/panel/brightness \
            /sys/class/backlight/panel0-backlight/brightness; do
            [ ! -e "$f" ] && continue
            chcon u:object_r:sysfs_lcd_writable:s0 "$f" 2>/dev/null || true
            chmod 0644 "$f"
            chown system:system "$f"
        done

        if [ -e /sys/class/sec/tsp/cmd ]; then
            chcon u:object_r:sysfs_ss_writable:s0 \
                /sys/class/sec/tsp/cmd \
                /sys/class/sec/tsp/cmd_list \
                /sys/class/sec/tsp/cmd_result \
                /sys/class/sec/tsp/cmd_status \
                /sys/class/sec/tsp/ear_detect_enable 2>/dev/null || true
            chown system \
                /sys/class/sec/tsp/cmd \
                /sys/class/sec/tsp/cmd_list \
                /sys/class/sec/tsp/cmd_result \
                /sys/class/sec/tsp/cmd_status \
                /sys/class/sec/tsp/ear_detect_enable 2>/dev/null || true
        fi

        if [ -e /sys/class/sec/tsp/input/enabled ]; then
            chown system:system /sys/class/sec/tsp/input/enabled
            chcon u:object_r:sysfs_ss_writable:s0 /sys/class/sec/tsp/input/enabled 2>/dev/null || true
        fi

        if [ -e /sys/class/camera/flash/rear_flash ]; then
            chown system:system /sys/class/camera/flash/rear_flash
            chcon u:object_r:sysfs_camera_writable:s0 /sys/class/camera/flash/rear_flash 2>/dev/null || true
        fi

        # Samsung FOD (fingerprint on display) — mask brightness max
        cat /sys/class/backlight/*/max_brightness 2>/dev/null | \
            sort -n | tail -n 1 > /sys/class/lcd/panel/mask_brightness 2>/dev/null || true

        log "Samsung: sysfs permissions fixed"
    fi

    # --------------------------------------------------------------------------
    # FINGERPRINT SPOOF — VERY IMPORTANT FOR ONE UI
    # Copies vendor build identity props to system namespace
    # Required so system_server, Settings, and Samsung Knox see correct device
    # Also sets ro.product.first_api_level from VNDK so SDK checks pass
    # --------------------------------------------------------------------------
    log "Fingerprint: spoofing system props from vendor"
    copyprop ro.build.fingerprint        ro.vendor.build.fingerprint
    copyprop ro.bootimage.build.fingerprint ro.vendor.build.fingerprint
    copyprop ro.system.build.fingerprint ro.vendor.build.fingerprint
    copyprop ro.product.device           ro.vendor.product.device
    copyprop ro.product.system.device    ro.vendor.product.device
    copyprop ro.product.name             ro.vendor.product.name
    copyprop ro.product.brand            ro.vendor.product.brand
    copyprop ro.product.model            ro.vendor.product.model
    copyprop ro.product.manufacturer     ro.vendor.product.manufacturer
    [ -n "$vndk" ] && resetprop ro.product.first_api_level "$vndk"
    log "Fingerprint: spoof complete"

    # --------------------------------------------------------------------------
    # VIBRATOR SYSFS SETUP
    # MTK vibrator node needs correct permissions for app access
    # Without this: haptic feedback silent, notification vibration broken
    # --------------------------------------------------------------------------
    log "Vibrator: setting up sysfs permissions"
    for vib_node in \
        /sys/class/timed_output/vibrator/enable \
        /sys/bus/platform/drivers/mtk_vibrator/vibrator0/enable \
        /sys/devices/platform/mtk_vibrator/vibrate; do
        [ ! -e "$vib_node" ] && continue
        chown system:system "$vib_node"
        chmod 0660 "$vib_node"
        chcon u:object_r:sysfs_vibrator:s0 "$vib_node" 2>/dev/null || true
        log "Vibrator: configured $vib_node"
    done

    # --------------------------------------------------------------------------
    # NFC CONFIG FIX — Samsung/Huawei NFC uses different conf paths
    # Bind mount vendor NFC config to the path system expects
    # --------------------------------------------------------------------------
    if getprop ro.vendor.build.fingerprint | grep -iqE 'huawei|honor'; then
        log "NFC: applying Huawei NFC config fix"
        local p
        p=/product/etc/nfc/libnfc_nxp_*_*.conf
        mount -o bind "$p" /system/etc/libnfc-nxp.conf 2>/dev/null ||
            mount -o bind /product/etc/libnfc-nxp.conf /system/etc/libnfc-nxp.conf 2>/dev/null || true
    fi

    # --------------------------------------------------------------------------
    # FRP NODE PERMISSIONS
    # Factory Reset Protection partition needs system read/write access
    # --------------------------------------------------------------------------
    local frp_node
    frp_node="$(getprop ro.frp.pst)"
    if [ -n "$frp_node" ]; then
        chown -h system:system "$frp_node" 2>/dev/null || true
        chmod 0660 "$frp_node" 2>/dev/null || true
        log "FRP: fixed perms on $frp_node"
    fi

    # --------------------------------------------------------------------------
    # MISC PROPS
    # ro.control_privapp_permissions=log — don't hard-fail on priv-app violations
    # vendor.display.res_switch_en=1     — enable display resolution switching
    # persist.sys.draw.ril_force_cognitive — already set during RIL patch
    # --------------------------------------------------------------------------
    resetprop ro.control_privapp_permissions log
    setprop vendor.display.res_switch_en 1

    log "=============================="
    log "DRAW setup complete"
    log "=============================="
}

# =============================================================================
# DISPATCH
# =============================================================================
case "$CMD" in
    setup)           do_setup ;;
    dt2w_enable)     do_dt2w_enable ;;
    dt2w_disable)    do_dt2w_disable ;;
    otg_enable)      do_otg_enable ;;
    otg_disable)     do_otg_disable ;;
    audio_fx_disable) do_audio_fx_disable ;;
    audio_fx_enable)  do_audio_fx_enable ;;
    backlight_scale) do_backlight_scale ;;
    secure_enable)   do_secure_enable ;;
    *)
        echo "Usage: $0 {setup|dt2w_enable|dt2w_disable|otg_enable|otg_disable|audio_fx_disable|audio_fx_enable|backlight_scale|secure_enable}"
        exit 1
        ;;
esac
