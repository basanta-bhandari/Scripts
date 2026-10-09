#!/usr/bin/env bash
#
# debloat-wizard.sh — Interactive ADB debloat WIZARD for low-storage Android phones
# (built with the Samsung Galaxy M01 Core / SM-M013F in mind, MT6739, 1-2GB RAM)
#
# What it does:
#   1. Detects connected ADB devices (unauthorized/offline ones are shown but not selectable)
#   2. Enumerates EVERY app on the device that has a launcher icon — user-installed apps,
#      Samsung apps (Members, Max, Internet...), Google apps, everything user-facing —
#      and asks you individually whether to remove each one.
#      Pure OS internals (no icon) are skipped; critical components (launcher, keyboard,
#      dialer, camera...) are hard-protected and never offered.
#   3. Each app is annotated: [known-safe bloat], [CAUTION: reason], [user-installed] or [system app]
#      Known invisible bloat (Facebook stubs, Bixby agent etc.) is added to the queue too.
#   4. Removes accepted packages via 'pm uninstall --user 0' (reversible, no root),
#      reporting Success/Failure per package.
#   5. Offers a cleanup pass (app caches, thumbnails, log buffer).
#   6. Offers to reboot the phone at the end to settle the changes.
#
# Requires: adb (Android platform-tools). On CachyOS: sudo pacman -S --needed android-tools android-udev

set -uo pipefail

# ---------- risk annotations ----------

# Packages tagged as known-safe bloat (low risk for almost anyone)
SAFE_BLOAT=(
  "com.samsung.android.bixby.agent"
  "com.samsung.android.bixby.service"
  "com.samsung.android.bixbyvision.framework"
  "com.samsung.android.visionintelligence"
  "com.samsung.android.app.spage"           # Samsung Free / Bixby Home feed
  "com.samsung.android.game.gamehome"
  "com.samsung.android.game.gametools"
  "com.sec.android.app.samsungapps"         # Galaxy Store
  "com.samsung.android.MtpApplication"
  "com.samsung.android.oneconnect"          # SmartThings
  "com.samsung.android.app.watchmanager"
  "com.samsung.android.beaconmanager"
  "com.facebook.appmanager"                 # Facebook preload stub/updater
  "com.facebook.services"
  "com.facebook.system"
  "com.google.android.apps.tachyon"         # Duo/Meet
  "com.google.android.apps.podcasts"
  "com.google.android.apps.wellbeing"
  "com.google.android.apps.magazines"
  "com.google.android.videos"
  "com.google.android.music"
  "com.google.android.apps.youtube.music"
  "com.google.android.apps.youtube.mango"   # YouTube Go (discontinued)
  "com.google.android.apps.googleassistant" # Assistant Go
  "com.google.android.feedback"
  "com.google.android.apps.docs"
  "com.microsoft.skydrive"
)

# Riskier items get individual caution notes
DEEP_PKG=(
  "com.google.android.gm"                    # Gmail
  "com.google.android.gm.lite"               # Gmail GO variant
  "com.google.android.apps.maps"             # Maps
  "com.google.android.apps.mapslite"         # Maps GO variant
  "com.google.android.apps.searchlite"       # IS Google Search on Go phones
  "com.google.android.apps.photosgo"         # may be the ONLY gallery app!
  "com.android.chrome"                       # browser — keep ONE browser only
  "com.sec.android.app.sbrowser"             # Samsung Internet — keep ONE browser only
  "com.sec.android.app.music"                # Samsung Music/Members-era media app
  "com.samsung.android.voc"                  # Samsung Members
  "com.samsung.android.email.provider"       # loses unsynced local mail
  "com.samsung.android.calendar"             # loses unsynced local events
  "com.samsung.android.app.reminder"         # loses unsynced reminders
  "com.samsung.android.svoiceime"            # can leave NO KEYBOARD if it's active
  "com.google.android.marvin.talkback"       # accessibility screen reader
  "com.samsung.android.svcagent"
  "com.samsung.android.kidsinstaller"
  "com.samsung.android.themestore"
  "com.samsung.android.livestickers"
)

declare -A TAGS
for p in "${SAFE_BLOAT[@]}"; do TAGS[$p]="known-safe bloat"; done
DEEP_NOTES=(
  "Gmail" "Gmail Go" "Maps" "Maps Go" "this is Google Search on Go devices"
  "may be the ONLY gallery app" "browser - keep only ONE browser" "Samsung Internet - keep only ONE browser"
  "Samsung music app" "Samsung Members" "loses unsynced local mail/data" "loses unsynced local events"
  "loses unsynced reminders" "if this is the ACTIVE keyboard there is no other keyboard"
  "accessibility/screen reader" "Samsung service agent" "kids-mode installer" "theme store" "AR stickers"
)
if [[ ${#DEEP_PKG[@]} -ne ${#DEEP_NOTES[@]} ]]; then
  echo "INTERNAL WARNING: DEEP_PKG/DEEP_NOTES length mismatch (${#DEEP_PKG[@]} vs ${#DEEP_NOTES[@]}) — some notes may be missing." >&2
fi
for i in "${!DEEP_PKG[@]}"; do TAGS[${DEEP_PKG[$i]}]="CAUTION: ${DEEP_NOTES[$i]:-risky}"; done

# ---------- never touch these ----------

PROTECTED=(
  "com.google.android.gms"
  "com.google.android.gsf"
  "com.android.vending"
  "com.google.android.packageinstaller"
  "com.google.android.permissioncontroller"
  "com.android.systemui"
  "com.samsung.android.incallui"
  "com.android.phone"
  "com.android.providers.telephony"
  "com.android.providers.contacts"
  "com.sec.android.app.launcher"            # One UI Home (the home screen!)
  "com.android.settings"
  "com.samsung.android.honeyboard"          # Samsung Keyboard (One UI 2.x+)
  "com.sec.android.inputmethod.beta"        # Samsung Keyboard (older builds)
  "com.sec.android.app.camera"
  "com.sec.android.app.clockpackage"        # Clock/alarms
  "com.samsung.android.dialer"
  "com.samsung.android.contacts"
  "com.samsung.android.messaging"
  "com.samsung.android.sm.devicesecurity"   # Device care core
  "com.samsung.android.providers.media"     # media storage provider
  "com.android.externalstorage"             # storage access framework
)

# Anything starting with these prefixes is off-limits too (keyboards/IME variants etc.)
PROTECTED_PREFIX=(
  "com.sec.android.inputmethod."
  "com.android.inputmethod"
  "com.google.android.inputmethod"          # Gboard
)

is_protected() {
  local pkg="$1" p
  for p in "${PROTECTED[@]}"; do
    [[ "$pkg" == "$p" ]] && return 0
  done
  for p in "${PROTECTED_PREFIX[@]}"; do
    [[ "$pkg" == "$p"* ]] && return 0
  done
  return 1
}

# ---------- helpers ----------

die() { echo "ERROR: $*" >&2; exit 1; }

confirm() {
  local prompt="$1"
  read -r -p "$prompt [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

REMOVED_COUNT=0
FAILED_COUNT=0
FAILED_PKGS=()

adb_uninstall() {
  local pkg="$1" out
  if is_protected "$pkg"; then
    echo "  SKIP (protected): $pkg"
    return
  fi
  printf '  Removing %s ... ' "$pkg"
  out=$(adb -s "$DEVICE_SERIAL" shell pm uninstall --user 0 "$pkg" 2>&1 | tr -d '\r')
  if [[ "$out" == *Success* ]]; then
    echo "OK"
    REMOVED_COUNT=$((REMOVED_COUNT + 1))
  else
    echo "FAILED (${out:-no output})"
    FAILED_COUNT=$((FAILED_COUNT + 1))
    FAILED_PKGS+=("$pkg")
  fi
}

device_label() {
  adb -s "$1" shell getprop ro.product.model 2>/dev/null | tr -d '\r'
}

# ---------- 0. sanity checks ----------

command -v adb >/dev/null 2>&1 || die "adb not found. Install it first (CachyOS/Arch): sudo pacman -S --needed android-tools android-udev"

if [[ ! -e /usr/lib/udev/rules.d/51-android.rules && ! -e /etc/udev/rules.d/51-android.rules ]]; then
  echo "NOTE: android-udev rules not found yet. If the phone later shows as 'no permissions', run:"
  echo "      sudo pacman -S --needed android-udev   then unplug/replug the cable"
  echo ""
fi

# ---------- 1. detect & confirm device ----------

echo "== Step 1: Detecting connected devices =="
mapfile -t DEVLINES < <(adb devices | tail -n +2 | grep -v '^$')

if [[ ${#DEVLINES[@]} -eq 0 ]]; then
  die "No devices found. Plug in the phone, enable USB debugging, and accept the prompt on-screen."
fi

DEVICE_SERIAL=""
if [[ ${#DEVLINES[@]} -eq 1 ]]; then
  DEVICE_SERIAL=$(awk '{print $1}' <<< "${DEVLINES[0]}")
  STATE=$(awk '{print $2}' <<< "${DEVLINES[0]}")
  [[ "$STATE" == "unauthorized" ]] && die "Device found but unauthorized. Check the phone screen for the USB debugging prompt."
  if [[ "$STATE" != "device" ]]; then
    HINT=""
    [[ "${DEVLINES[0]}" == *"no permissions"* ]] && HINT=" (On CachyOS: sudo pacman -S android-udev, then replug the cable.)"
    die "Device state is '$STATE', expected 'device'.$HINT"
  fi

  MODEL=$(device_label "$DEVICE_SERIAL")
  MANUF=$(adb -s "$DEVICE_SERIAL" shell getprop ro.product.manufacturer | tr -d '\r')
  ANDROID_VER=$(adb -s "$DEVICE_SERIAL" shell getprop ro.build.version.release | tr -d '\r')

  echo ""
  echo "Found: $MANUF ${MODEL:-unknown} (Android $ANDROID_VER) — serial $DEVICE_SERIAL"
  confirm "Is this the phone you want to debloat?" || die "Aborted — not the right device."
else
  echo "Multiple devices found (only ones in 'device' state are selectable):"
  i=1
  declare -A IDX_TO_SERIAL
  usable=0
  for line in "${DEVLINES[@]}"; do
    serial=$(awk '{print $1}' <<< "$line")
    state=$(awk '{print $2}' <<< "$line")
    if [[ "$state" == "device" ]]; then
      model=$(device_label "$serial")
      echo "  [$i] $serial — ${model:-unknown}"
      IDX_TO_SERIAL[$i]="$serial"
      usable=$((usable + 1))
    else
      echo "  [$i] $serial — not selectable (state: $state)"
    fi
    i=$((i + 1))
  done
  (( usable > 0 )) || die "No usable devices — everything is unauthorized/offline/no-permissions."
  read -r -p "Pick a number: " pick
  DEVICE_SERIAL="${IDX_TO_SERIAL[$pick]:-}"
  [[ -z "$DEVICE_SERIAL" ]] && die "Invalid selection."
fi

echo ""

# ---------- 2. enumerate apps & build the wizard queue ----------

echo "== Step 2: Enumerating apps on device =="

mapfile -t INSTALLED < <(adb -s "$DEVICE_SERIAL" shell pm list packages | sed 's/^package://' | tr -d '\r' | sort)
[[ ${#INSTALLED[@]} -gt 0 ]] || die "Could not read package list from device."

declare -A THIRDPARTY
while IFS= read -r p; do
  [[ -n "$p" ]] && THIRDPARTY["$p"]=1
done < <(adb -s "$DEVICE_SERIAL" shell pm list packages -3 | sed 's/^package://' | tr -d '\r')
THIRD_COUNT=${#THIRDPARTY[@]}

echo "  Total packages installed: ${#INSTALLED[@]} ($THIRD_COUNT user-installed)"
echo "  Detecting which ones are real apps with a launcher icon (takes ~10-30s)..."

# One batched round-trip: the loop runs ON the phone, so this stays fast.
mapfile -t LAUNCHABLE < <(printf '%s\n' "${INSTALLED[@]}" \
  | adb -s "$DEVICE_SERIAL" shell 'while read -r p; do case "$(cmd package resolve-activity --brief -c android.intent.category.LAUNCHER "$p" 2>/dev/null)" in */*) printf "%s\n" "$p";; esac; done' \
  | tr -d '\r' | sort)

if [[ ${#LAUNCHABLE[@]} -lt 3 ]]; then
  echo "  WARNING: launcher detection returned nothing useful — falling back to user-installed apps only."
  LAUNCHABLE=()
  while IFS= read -r p; do [[ -n "$p" ]] && LAUNCHABLE+=("$p"); done < <(printf '%s\n' "${!THIRDPARTY[@]}" | sort)
fi

# Queue = every launchable app + every KNOWN-LISTED package that's installed but
# has no icon (invisible bloat like Facebook stubs / Bixby agents), minus protected.
declare -A IN_QUEUE
WIZARD_QUEUE=()
add_to_queue() {
  local pkg="$1"
  [[ -z "$pkg" ]] && return 0
  [[ -n "${IN_QUEUE[$pkg]:-}" ]] && return 0
  is_protected "$pkg" && return 0
  IN_QUEUE[$pkg]=1
  WIZARD_QUEUE+=("$pkg")
}

for p in "${LAUNCHABLE[@]}"; do add_to_queue "$p"; done
for p in "${SAFE_BLOAT[@]}"; do
  is_installed=0
  for inst in "${INSTALLED[@]}"; do [[ "$inst" == "$p" ]] && { add_to_queue "$p"; break; }; done
done
for p in "${DEEP_PKG[@]}"; do
  for inst in "${INSTALLED[@]}"; do [[ "$inst" == "$p" ]] && { add_to_queue "$p"; break; }; done
done

mapfile -t WIZARD_QUEUE < <(printf '%s\n' "${WIZARD_QUEUE[@]}" | sort)

TOTAL=${#WIZARD_QUEUE[@]}
[[ $TOTAL -eq 0 ]] && die "Nothing to ask about — every visible app is protected or none were detected."

echo ""
echo "== Step 3: The interrogation =="
echo "I will now ask about each of the $TOTAL apps individually."
echo "  y = mark for removal   n / Enter = keep it   q = stop asking and continue"
echo ""
read -r -p "Ready? [y/N] " go
[[ "$go" =~ ^[Yy]$ ]] || die "Aborted by user."

TO_REMOVE=()
asked=0
for pkg in "${WIZARD_QUEUE[@]}"; do
  asked=$((asked + 1))
  kind="system app"
  [[ -n "${THIRDPARTY[$pkg]:-}" ]] && kind="user-installed"
  tag="${TAGS[$pkg]:-}"
  echo ""
  printf '[%d/%d] %s\n' "$asked" "$TOTAL" "$pkg"
  printf '        (%s%s%s)\n' "$kind" "${tag:+ | }" "$tag"
  read -r -p "        Remove? [y/N/q] " ans
  case "$ans" in
    y|Y) TO_REMOVE+=("$pkg") ;;
    q|Q) echo "Stopping questions early."; break ;;
  esac
done

# ---------- 3. execute removals ----------

if [[ ${#TO_REMOVE[@]} -gt 0 ]]; then
  echo ""
  echo "== Step 4: About to remove ${#TO_REMOVE[@]} package(s) =="
  printf '  - %s\n' "${TO_REMOVE[@]}"
  if confirm "Proceed?"; then
    for pkg in "${TO_REMOVE[@]}"; do
      adb_uninstall "$pkg"
    done
  else
    echo "Skipped removal."
  fi
else
  echo ""
  echo "No packages marked for removal."
fi

# ---------- 4. beyond-apps cleanup ----------

echo ""
echo "== Step 5: Non-app cleanup =="
echo "Clears regenerable caches, thumbnail junk, and the log buffer."
echo "(Photos, videos, downloads, chats are NEVER touched.)"
if confirm "Run the non-app cleanup pass?"; then

  echo "  - Trimming all app caches (safe, regenerates automatically)..."
  adb -s "$DEVICE_SERIAL" shell "pm trim-caches 999999999999" 2>&1 | sed 's/^/    /'

  echo "  - Clearing thumbnail cache..."
  adb -s "$DEVICE_SERIAL" shell "rm -rf /sdcard/DCIM/.thumbnails/*" 2>&1 | sed 's/^/    /'

  echo "  - Clearing system log buffer..."
  adb -s "$DEVICE_SERIAL" shell "logcat -c" 2>&1 | sed 's/^/    /'

  echo "  Done with non-app cleanup."
else
  echo "Skipped non-app cleanup."
fi

# ---------- 5. summary + reboot ----------

echo ""
echo "== Done =="
echo "Uninstalled OK: $REMOVED_COUNT package(s)."
if [[ $FAILED_COUNT -gt 0 ]]; then
  echo "Failed (${FAILED_COUNT}) — usually 'not installed' or vendor-blocked, nothing broken:"
  printf '  - %s\n' "${FAILED_PKGS[@]}"
fi
echo ""
echo "Check remaining storage: Settings > Battery and device care > Storage"
echo "Removed something you actually wanted? Reinstall from Play Store or:"
echo "  adb shell cmd package install-existing <package>"
echo ""

read -r -p "Reboot the phone now to settle all changes? [Y/n] " rb
if [[ ! "$rb" =~ ^[Nn]$ ]]; then
  echo "Rebooting phone..."
  adb -s "$DEVICE_SERIAL" reboot && echo "Reboot command sent."
else
  echo "Skipped reboot."
fi
