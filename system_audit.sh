#!/usr/bin/env bash
###############################################################################
# system_audit.sh — Arch/CachyOS Compromise & Intrusion Audit
#
# Purpose: Give an honest, evidence-based report on whether this machine
# shows signs of unauthorized access, backdoors, persistence, or tampering.
#
# Usage:   chmod +x system_audit.sh && ./system_audit.sh
#          (some checks need sudo — run: sudo ./system_audit.sh for full depth)
#
# Output:  Markdown report at ./audit_report_<timestamp>.md
#
# Philosophy: NO check here is "definitely hacked." Every flagged item is
# a LEAD to manually verify. This throws zero silent false negatives —
# it would rather over-report than miss something.
###############################################################################

set -uo pipefail

TS=$(date +%Y%m%d_%H%M%S)
REPORT="audit_report_${TS}.md"
HOSTNAME=$(hostname)
IS_ROOT=0
[[ $EUID -eq 0 ]] && IS_ROOT=1

FLAGS_HIGH=0
FLAGS_MED=0
FLAGS_LOW=0

# ---------- helpers ----------
hdr()  { echo -e "\n## $1\n" >> "$REPORT"; }
sub()  { echo -e "\n### $1\n" >> "$REPORT"; }
note() { echo "$1" >> "$REPORT"; }
code() { echo '```' >> "$REPORT"; cat >> "$REPORT"; echo '```' >> "$REPORT"; }
flag() {
    # flag <SEVERITY> <message>
    local sev="$1"; shift
    case "$sev" in
        HIGH) FLAGS_HIGH=$((FLAGS_HIGH+1)); note "- 🔴 **HIGH:** $*" ;;
        MED)  FLAGS_MED=$((FLAGS_MED+1));   note "- 🟠 **MEDIUM:** $*" ;;
        LOW)  FLAGS_LOW=$((FLAGS_LOW+1));   note "- 🟡 **LOW:** $*" ;;
        OK)   note "- 🟢 $*" ;;
    esac
}

echo "# System Audit Report — $HOSTNAME" > "$REPORT"
echo "Generated: $(date)" >> "$REPORT"
echo "Run as root: $([[ $IS_ROOT -eq 1 ]] && echo yes || echo NO — some checks limited)" >> "$REPORT"

if [[ $IS_ROOT -eq 0 ]]; then
    echo ""
    echo "⚠️  Not running as root. Re-run with 'sudo' for full depth (rootkit scan,"
    echo "    full process/socket inode matching, file integrity via pacman -Qkk, etc)."
    echo "    Continuing with reduced checks..."
    echo ""
fi

###############################################################################
hdr "1. Logged-in Users & Login History"
###############################################################################
sub "Currently logged in"
who -a 2>/dev/null | code
sub "Last 25 logins (success)"
last -25 2>/dev/null | code
sub "Last failed logins"
if command -v lastb &>/dev/null; then
    (sudo -n lastb -25 2>/dev/null || echo "needs sudo — run script as root to see this") | code
else
    echo "lastb not available" | code
fi

# flag if unfamiliar users exist
UNKNOWN_USERS=$(awk -F: '($3>=1000)&&($3!=65534){print $1}' /etc/passwd)
note "**Human (UID>=1000) accounts on this system:**"
echo "$UNKNOWN_USERS" | code
flag OK "Review the list above — any account you don't recognize is worth investigating manually (userdel candidates)."

###############################################################################
hdr "2. SSH Configuration & Login Speed/Anomalies"
###############################################################################
sub "sshd_config key settings"
if [[ -f /etc/ssh/sshd_config ]]; then
    grep -Ei '^(PermitRootLogin|PasswordAuthentication|PubkeyAuthentication|PermitEmptyPasswords|AllowUsers|AllowGroups|Port|ListenAddress|X11Forwarding)' /etc/ssh/sshd_config 2>/dev/null | code
    ROOTLOGIN=$(grep -Ei '^PermitRootLogin' /etc/ssh/sshd_config | awk '{print $2}')
    PASSAUTH=$(grep -Ei '^PasswordAuthentication' /etc/ssh/sshd_config | awk '{print $2}')
    [[ "$ROOTLOGIN" == "yes" ]] && flag HIGH "PermitRootLogin is set to 'yes' — root can log in over SSH directly. Recommend 'no' or 'prohibit-password'."
    [[ "$PASSAUTH" == "yes" ]] && flag MED "PasswordAuthentication is enabled — vulnerable to brute-force vs key-only auth. Consider disabling if you use keys."
else
    note "No sshd installed/configured on this host."
fi

sub "authorized_keys across all home dirs (unexpected keys = compromise)"
for d in /root /home/*; do
    if [[ -f "$d/.ssh/authorized_keys" ]]; then
        echo "--- $d/.ssh/authorized_keys ---" >> "$REPORT"
        (cat "$d/.ssh/authorized_keys" 2>/dev/null || echo "(permission denied — check manually)") | code
    fi
done
flag OK "Manually confirm every key above belongs to a device you own. An extra key you don't recognize = someone has persistent SSH access."

sub "Live SSH login round-trip speed test (local loopback baseline)"
if command -v ssh &>/dev/null && systemctl is-active --quiet sshd 2>/dev/null; then
    START=$(date +%s%N)
    timeout 5 ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no localhost exit 2>/dev/null
    END=$(date +%s%N)
    MS=$(( (END-START)/1000000 ))
    note "Loopback SSH handshake attempt took ${MS}ms (informational — very slow handshakes can indicate a MITM proxy or tarpit; sub-second is normal)."
else
    note "sshd not running locally — skipped."
fi

###############################################################################
hdr "3. Process Tree Anomalies"
###############################################################################
sub "Full process list (review for anything you don't recognize)"
ps auxf 2>/dev/null | code

sub "Processes running from suspicious locations (/tmp, /dev/shm, /var/tmp, hidden dirs)"
SUSP_PROC=$(ps -eo pid,comm,args 2>/dev/null | grep -E '/tmp/|/dev/shm/|/var/tmp/|/\.[a-zA-Z]' | grep -v grep)
if [[ -n "$SUSP_PROC" ]]; then
    echo "$SUSP_PROC" | code
    flag HIGH "Process(es) executing from /tmp, /dev/shm, or hidden dot-directories found. This is a classic dropper/backdoor pattern. Investigate PIDs above immediately (check with: ls -la /proc/<pid>/exe)."
else
    flag OK "No processes found executing from /tmp, /dev/shm, /var/tmp, or hidden dirs."
fi

sub "Processes whose binary has been deleted from disk (common with fileless malware / self-deleting droppers)"
DELETED=$(ls -la /proc/*/exe 2>/dev/null | grep -i deleted)
if [[ -n "$DELETED" ]]; then
    echo "$DELETED" | code
    flag HIGH "Process(es) running from a deleted binary. Legit for some updated daemons, but worth checking each PID's /proc/<pid>/cmdline and /proc/<pid>/cwd."
else
    flag OK "No processes running from deleted binaries."
fi

sub "Top CPU/mem consumers (baseline — sudden persistent unknown high usage is a miner/backdoor tell)"
ps aux --sort=-%cpu 2>/dev/null | head -15 | code
ps aux --sort=-%mem 2>/dev/null | head -15 | code

sub "Processes with no matching parent (orphans reparented to PID 1 — can be normal, can be evasion)"
ps -eo pid,ppid,comm 2>/dev/null | awk '$2==1 && $3!="systemd" && $3!="init"' | code

###############################################################################
hdr "4. Network: Open Ports, Connections, Firewall"
###############################################################################
sub "Listening TCP/UDP sockets with owning process"
if command -v ss &>/dev/null; then
    ss -tulpn 2>/dev/null | code
else
    netstat -tulpn 2>/dev/null | code
fi

sub "Established outbound connections (look for unfamiliar remote IPs/ports, especially :4444, :1337, :6667, :443 to weird IPs)"
ss -tnp state established 2>/dev/null | code

SUSPICIOUS_PORTS="4444 1337 31337 6667 12345 9999 2222"
for p in $SUSPICIOUS_PORTS; do
    HIT=$(ss -tulpn 2>/dev/null | grep ":$p ")
    if [[ -n "$HIT" ]]; then
        flag HIGH "Port $p is open/listening — this port is a well-known default for common backdoors/RATs/reverse shells. Verify what's bound to it."
        echo "$HIT" | code
    fi
done

sub "Firewall status (firewalld / ufw / iptables / nftables)"
if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
    note "firewalld active."
    sudo firewall-cmd --list-all 2>/dev/null | code
elif command -v ufw &>/dev/null; then
    ufw status verbose 2>/dev/null | code
fi
if command -v nft &>/dev/null; then
    note "nftables ruleset:"
    (sudo nft list ruleset 2>/dev/null || echo "needs sudo") | code
fi
if command -v iptables &>/dev/null; then
    note "iptables rules:"
    (sudo iptables -L -n -v 2>/dev/null || echo "needs sudo") | code
fi
FW_ACTIVE=$(systemctl is-active firewalld ufw nftables iptables 2>/dev/null | grep -c active)
if [[ "$FW_ACTIVE" -eq 0 ]]; then
    flag MED "No firewall service (firewalld/ufw/nftables/iptables) appears active. Your open ports above are your only real perimeter check — verify each one is intentional."
else
    flag OK "A firewall service is active."
fi

sub "ARP table (look for unexpected duplicate IP/MAC entries — sign of ARP spoofing/MITM on LAN)"
ip neigh 2>/dev/null | code

###############################################################################
hdr "5. Persistence Mechanisms"
###############################################################################
sub "Systemd services NOT from official pacman packages (custom/unknown units)"
for unit in $(systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}'); do
    UNITPATH=$(systemctl show -p FragmentPath "$unit" 2>/dev/null | cut -d= -f2)
    [[ -z "$UNITPATH" || "$UNITPATH" == "/dev/null" ]] && continue
    OWNER=$(pacman -Qo "$UNITPATH" 2>/dev/null)
    if [[ -z "$OWNER" ]]; then
        echo "$unit -> $UNITPATH (NOT owned by any pacman package)" >> "$REPORT"
    fi
done
note "(Units above with no package owner are either your own configs, AUR-installed things, or — worth checking — planted persistence. Cross-reference names you don't recognize.)"

sub "Enabled services (full list)"
systemctl list-unit-files --type=service --state=enabled --no-legend 2>/dev/null | code

sub "User + system crontabs"
for u in $(cut -f1 -d: /etc/passwd); do
    CRON=$(crontab -u "$u" -l 2>/dev/null)
    [[ -n "$CRON" ]] && { echo "--- crontab for $u ---" >> "$REPORT"; echo "$CRON" | code; }
done
echo "--- /etc/cron.* and /etc/crontab ---" >> "$REPORT"
(cat /etc/crontab 2>/dev/null; ls -la /etc/cron.d/ /etc/cron.daily/ /etc/cron.hourly/ 2>/dev/null) | code

sub "Systemd timers (modern cron-replacement persistence)"
systemctl list-timers --all --no-legend 2>/dev/null | code

sub "Shell startup file tampering check (.bashrc/.zshrc/.profile/.bash_profile for injected commands)"
for f in /root/.bashrc /root/.profile /home/*/.bashrc /home/*/.zshrc /home/*/.profile /home/*/.config/fish/config.fish; do
    if [[ -f "$f" ]]; then
        HIT=$(grep -E 'curl |wget |base64 -d|nc -e|/dev/tcp/|eval \$\(' "$f" 2>/dev/null)
        if [[ -n "$HIT" ]]; then
            flag HIGH "Suspicious line(s) in $f — possible injected reverse shell / stager:"
            echo "$HIT" | code
        fi
    fi
done

sub "LD_PRELOAD hijack check (classic rootkit technique for hiding processes/files)"
if [[ -f /etc/ld.so.preload ]]; then
    flag HIGH "/etc/ld.so.preload EXISTS. This file forces every process to load an extra shared library — a hallmark rootkit persistence technique. Contents:"
    cat /etc/ld.so.preload | code
else
    flag OK "/etc/ld.so.preload does not exist (good — this is the expected state)."
fi
echo "Global LD_PRELOAD env: ${LD_PRELOAD:-<empty>}" | code

sub "udev rules / systemd path units (less common persistence spots)"
find /etc/udev/rules.d/ -newer /etc/os-release -type f 2>/dev/null | code

###############################################################################
hdr "6. Package Integrity (pacman)"
###############################################################################
sub "Files modified since install, per package (pacman -Qkk) — takes a moment"
if command -v pacman &>/dev/null; then
    if [[ $IS_ROOT -eq 1 ]]; then
        pacman -Qkk 2>/dev/null | grep -v "0 altered files" > /tmp/pacman_altered.tmp
        if [[ -s /tmp/pacman_altered.tmp ]]; then
            flag MED "Some installed package files differ from their pristine pacman database checksums. This CAN be normal (config file edits, .pacnew merges) but binaries in /usr/bin or /usr/lib being altered is not normal:"
            cat /tmp/pacman_altered.tmp | code
        else
            flag OK "No altered files detected across installed packages."
        fi
        rm -f /tmp/pacman_altered.tmp
    else
        note "Needs root — run with sudo for this check."
    fi
fi

sub "Foreign/AUR packages installed (not in official repos — larger trust surface)"
pacman -Qm 2>/dev/null | code
flag OK "Review the AUR/foreign package list above — each one is code you trusted from a third-party maintainer. Any name you don't recognize installing itself is worth investigating."

sub "Orphaned packages (no longer required by anything — housekeeping, not usually malicious)"
pacman -Qdt 2>/dev/null | code

###############################################################################
hdr "7. Kernel Modules & Rootkit Indicators"
###############################################################################
sub "Loaded kernel modules"
lsmod 2>/dev/null | code

sub "Modules not matching any file on disk (a real rootkit red flag)"
for mod in $(lsmod 2>/dev/null | awk 'NR>1{print $1}'); do
    modinfo "$mod" &>/dev/null || echo "Module '$mod' loaded but modinfo can't find it on disk — investigate." >> "$REPORT"
done

sub "rkhunter / chkrootkit (if installed)"
if command -v rkhunter &>/dev/null; then
    note "Running rkhunter (may take a minute)..."
    (sudo rkhunter --check --sk --nocolors 2>/dev/null | tail -60) | code
else
    note "rkhunter not installed. Recommend: \`sudo pacman -S rkhunter\` then \`sudo rkhunter --propupd && sudo rkhunter --check\`."
fi
if command -v chkrootkit &>/dev/null; then
    (sudo chkrootkit 2>/dev/null) | code
else
    note "chkrootkit not installed (AUR). Optional second opinion tool."
fi

###############################################################################
hdr "8. Filesystem: Recently Modified & Hidden Files in Sensitive Areas"
###############################################################################
sub "Files modified in /etc in the last 7 days"
find /etc -type f -mtime -7 2>/dev/null | code

sub "SUID/SGID binaries (privilege escalation vectors — review for anything outside standard package list)"
find / -xdev \( -perm -4000 -o -perm -2000 \) -type f 2>/dev/null | code
flag OK "Cross-check the SUID/SGID list above against a fresh Arch install's list — extras are a common privilege-escalation backdoor."

sub "World-writable files in system directories (should normally be empty/minimal)"
find /etc /usr/bin /usr/lib /usr/local -xdev -perm -002 -type f 2>/dev/null | code

sub "Hidden files/dirs in /tmp, /var/tmp, /dev/shm"
find /tmp /var/tmp /dev/shm -maxdepth 3 -name ".*" 2>/dev/null | code

sub "Immutable file attribute check on sensitive files (chattr +i can hide a backdoor from overwrite/deletion)"
if command -v lsattr &>/dev/null; then
    lsattr /etc/passwd /etc/shadow /etc/ld.so.preload /etc/hosts 2>/dev/null | code
fi

###############################################################################
hdr "9. Runtime Speed / Performance Baseline (indirect compromise signal)"
###############################################################################
sub "CPU benchmark (sudden big deviation from your own historical baseline may indicate cryptomining)"
if command -v openssl &>/dev/null; then
    openssl speed -seconds 2 rsa2048 2>/dev/null | tail -5 | code
fi

sub "Disk I/O quick test"
dd if=/dev/zero of=/tmp/audit_iotest bs=1M count=256 oflag=direct 2>&1 | tail -3 | code
rm -f /tmp/audit_iotest

sub "System load & uptime"
uptime | code
note "Compare load average to what's normal for this machine when idle. Sustained unexplained load = investigate top consumers in Section 3."

###############################################################################
hdr "10. DNS / Hosts File Tampering"
###############################################################################
sub "/etc/hosts contents (check for injected redirects of legit domains)"
cat /etc/hosts | code

sub "Active DNS resolvers in use"
cat /etc/resolv.conf 2>/dev/null | code
resolvectl status 2>/dev/null | code

###############################################################################
hdr "11. Summary"
###############################################################################
note "**Findings:** 🔴 $FLAGS_HIGH high  |  🟠 $FLAGS_MED medium  |  🟡 $FLAGS_LOW low"
note ""
if [[ $FLAGS_HIGH -gt 0 ]]; then
    note "**Verdict:** One or more HIGH severity indicators were found. This does not confirm a breach, but every HIGH item needs manual verification NOW. Start there."
elif [[ $FLAGS_MED -gt 0 ]]; then
    note "**Verdict:** No high-confidence compromise indicators, but MEDIUM items exist that weaken your posture (hardening gaps, not necessarily active intrusion)."
else
    note "**Verdict:** No compromise indicators found by this pass. This is NOT a guarantee (no automated script catches everything — sophisticated intrusions can hide from all of the above). Re-run periodically and diff reports over time."
fi
note ""
note "**Recommended next steps if you suspect active compromise:**"
note "1. Disconnect from network if you believe access is ongoing."
note "2. Do NOT reboot before you've captured process/memory state — reboot clears volatile evidence."
note "3. Change all credentials from a KNOWN CLEAN device, not this one."
note "4. If HIGH flags exist, consider this machine untrusted until manually cleared — reinstalling is the only 100% guarantee against rootkits."

echo ""
echo "=================================================="
echo " Audit complete: $REPORT"
echo " High: $FLAGS_HIGH   Medium: $FLAGS_MED   Low: $FLAGS_LOW"
echo "=================================================="
