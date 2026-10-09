#!/usr/bin/env bash
# tuilauncher — fzf menu for all your TUI apps

if ! command -v fzf &>/dev/null; then
  echo "fzf not found — sudo apt install fzf"
  exit 1
fi

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/tuilauncher"
CONFIG_FILE="$CONFIG_DIR/apps.csv"
SUDO_CACHED=0
# inits stuff
if [ ! -f "$CONFIG_FILE" ]; then
  mkdir -p "$CONFIG_DIR"
  cat <<'EOF' >"$CONFIG_FILE"
Discordo|discordo|go install github.com/ayn2op/discordo@latest|Discord in terminal|Social
btop|btop|sudo apt install -y btop|Resource monitor|System
bluetui|bluetui|cargo install bluetui|Bluetooth manager|System
impala|impala|cargo install impala|WiFi manager|Network
wiremix|wiremix|cargo install wiremix|Audio mixer|Media
yazi|yazi|cargo install --locked yazi-fm yazi-cli|File manager|Files
lazygit|lazygit|sudo apt install -y lazygit|Git UI|Development
neovim|nvim|sudo apt install -y neovim|Text editor|Development
lynx|lynx|sudo apt install -y lynx|Terminal browser (HTML-only)|Web
ncdu|ncdu|sudo apt install -y ncdu|Disk usage analyzer|System
cava|cava|sudo apt install -y cava|Audio visualizer|Media
toot|toot|pip3 install toot|Mastodon TUI|Social
glow|glow|sudo apt install -y glow|Markdown renderer|Text
slides|slides|go install github.com/maaslalani/slides@latest|Terminal presentations|Text
posting|posting|pip3 install posting|HTTP API client|Network
lazydocker|lazydocker|curl -sL https://raw.githubusercontent.com/jesseduffield/lazydocker/master/scripts/install_update_linux.sh | bash|Docker manager|Development
k9s|k9s|curl -sS https://webinstall.dev/k9s | bash|Kubernetes TUI|Development
tig|tig|sudo apt install -y tig|Git log browser|Development
harlequin|harlequin|pip3 install harlequin|SQL IDE in terminal|Development
visidata|vd|sudo apt install -y visidata|CSV/data explorer|Data
newsboat|newsboat|sudo apt install -y newsboat|RSS/Atom reader|Web
navi|navi|bash <(curl -sL https://raw.githubusercontent.com/denisidoro/navi/master/scripts/install)|Cheatsheet runner|Utility
tldr|tldr|sudo apt install -y tldr|Simplified man pages|Utility
zoxide|zoxide|curl -sS https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | bash|Smart cd replacement|Utility
broot|broot|cargo install broot|Tree navigator|Files
tmux|tmux|sudo apt install -y tmux|Terminal multiplexer|System
zellij|zellij|cargo install zellij|Modern tmux alternative|System
taskwarrior|task|sudo apt install -y taskwarrior|Task manager|Productivity
calcurse|calcurse|sudo apt install -y calcurse|Calendar TUI|Productivity
trippy|trip|cargo install trippy|Network diagnostic|Network
bandwhich|bandwhich|cargo install bandwhich|Bandwidth monitor|Network
spotify-tui|spt|cargo install spotify-tui|Spotify TUI|Media
musikcube|musikcube|sudo apt install -y musikcube|Music player|Media
mps-youtube|mpsyt|pip3 install mps-youtube youtube-dl|YouTube in terminal|Media
EOF
  sed -i 's|pip3 install mps-youtube|pip3 install mps-youtube youtube-dl|' "$CONFIG_FILE"
fi

# funcs (main)
cache_sudo() {
  if [ "$SUDO_CACHED" -eq 1 ]; then return; fi
  clear
  echo -e "\e[1;36m[ Sudo Caching Setup ]\e[0m"
  echo "To avoid typing your password repeatedly during package installations,"
  echo "you can securely cache your sudo credentials for this session."
  read -p "Enable sudo caching now? (y/N): " cache_resp

  if [[ "$cache_resp" =~ ^[Yy] ]]; then
    if sudo -v; then
      (while true; do
        sudo -n true >/dev/null 2>&1
        sleep 60
        kill -0 "$$" 2>/dev/null || exit
      done) &
      echo -e "\e[1;32mSudo credentials cached successfully.\e[0m"
    else
      echo -e "\e[1;31mFailed to authenticate sudo.\e[0m"
    fi
  else
    echo -e "\e[1;33mSkipping sudo cache. You may be prompted multiple times.\e[0m"
  fi
  SUDO_CACHED=1
  sleep 1.5
}

build_menu() {
  while IFS='|' read -r name runcmd installcmd desc category; do
    [[ -z "$name" || "$name" == \#* ]] && continue
    printf "%-25s | %s\n" "$name" "$desc"
  done <"$CONFIG_FILE"

  echo "--------------------------|------------------------------------------------"
  printf "%-25s | %s\n" "[34] Install Package" "Select a missing package and install it"
  printf "%-25s | %s\n" "[35] Install All" "Automatically install all missing packages"
  printf "%-25s | %s\n" "[36] Add Custom Tool" "Add a new tool to this launcher persistently"
  printf "%-25s | %s\n" "[00] Quit" "Close TUI Launcher"
}

install_specific() {
  local missing=""
  while IFS='|' read -r name runcmd installcmd desc category; do
    [[ -z "$name" || "$name" == \#* ]] && continue
    if ! command -v "$runcmd" &>/dev/null; then
      missing+="$(printf "%-25s | %s\n" "$name" "$desc")"$'\n'
    fi
  done <"$CONFIG_FILE"

  if [ -z "$missing" ]; then
    echo -e "\n\e[1;32mAll tracked tools are already installed!\e[0m"
    sleep 2
    return
  fi

  local target
  target=$(echo -e "$missing" | sed '/^$/d' | fzf \
    --prompt='  Select to Install > ' \
    --border=rounded \
    --layout=reverse \
    --height=60% \
    --delimiter='\|' \
    --with-nth=1,2)

  [ -z "$target" ] && return

  local app_name
  app_name=$(echo "$target" | cut -d'|' -f1 | sed 's/ *$//')

  local installcmd
  installcmd=$(awk -F'|' -v name="$app_name" '$1 == name {print $3}' "$CONFIG_FILE")

  cache_sudo
  clear
  echo -e "\e[1;36mInstalling $app_name...\e[0m\n"
  eval "$installcmd"
  echo -e "\n\e[1;32mInstallation complete.\e[0m Press Enter to return..."
  read -r
}

install_all() {
  cache_sudo
  clear
  echo -e "\e[1;36m=== Installing All Missing Tools ===\e[0m\n"
  local count=0

  while IFS='|' read -r name runcmd installcmd desc category; do
    [[ -z "$name" || "$name" == \#* ]] && continue
    if command -v "$runcmd" &>/dev/null; then
      echo -e "\e[1;32m[✓]\e[0m $name is already installed, skipping."
    else
      echo -e "\n\e[1;33m[↓]\e[0m Installing $name..."
      eval "$installcmd"
      count=$((count + 1))
    fi
  done <"$CONFIG_FILE"

  echo -e "\n\e[1;32mFinished processing. $count new packages installed.\e[0m Press Enter to return..."
  read -r
}

add_custom() {
  clear
  echo -e "\e[1;36m=== Add Custom TUI Tool ===\e[0m"
  read -p "1. Tool Name (e.g., myapp): " new_name
  read -p "2. Command to run (e.g., myapp-cli): " new_runcmd
  read -p "3. Install command (e.g., apt install myapp): " new_installcmd
  read -p "4. Category (e.g., Utility): " new_category
  read -p "5. Description/Purpose: " new_desc

  if [[ -z "$new_name" || -z "$new_runcmd" || -z "$new_installcmd" ]]; then
    echo -e "\n\e[1;31mError: Name, Run Command, and Install Command are required!\e[0m"
    sleep 2
    return
  fi

  echo -e "\nInterpreting package manager..."
  if [[ "$new_installcmd" =~ (apt|apt-get|pacman|dnf|zypper|apk) ]]; then
    echo "- Detected System Package Manager (${BASH_REMATCH[1]})."
    if [[ "$new_installcmd" != sudo* ]]; then
      echo "- Auto-correcting: Adding 'sudo' for system-level installation."
      new_installcmd="sudo $new_installcmd"
    fi
  elif [[ "$new_installcmd" =~ (cargo|pip|pip3|pipx|go|npm) ]]; then
    echo "- Detected User-Space Package Manager (${BASH_REMATCH[1]}). No sudo needed."
  else
    echo "- Unrecognized/custom install script. Saving exactly as provided."
  fi

  echo "$new_name|$new_runcmd|$new_installcmd|$new_desc|$new_category" >>"$CONFIG_FILE"
  echo -e "\n\e[1;32mSuccessfully added '$new_name' to your launcher!\e[0m"
  sleep 2
}

run_app() {
  local name="$1"
  local runcmd
  runcmd=$(awk -F'|' -v name="$name" '$1 == name {print $2}' "$CONFIG_FILE")

  if [ -z "$runcmd" ]; then return; fi

  if ! command -v "$runcmd" &>/dev/null; then
    echo -e "\n\e[1;31mError: '$runcmd' not found.\e[0m"
    echo "Please use '[34] Install Package' to install it first."
    echo "Press Enter to return..."
    read -r
    return
  fi

  # Launch
  "$runcmd"
}

# MAIN STUFF
while true; do
  SELECTION=$(build_menu | fzf \
    --delimiter='\|' \
    --with-nth=1,2 \
    --prompt='  TUI launcher > ' \
    --height=70% \
    --layout=reverse \
    --border=rounded \
    --preview='echo -e "\e[1;34mPurpose:\e[0m {2}"' \
    --preview-window=up:1:wrap)

  #exit
  [ $? -ne 0 ] && exit 0
  [ -z "$SELECTION" ] && exit 0

  APP_NAME=$(echo "$SELECTION" | cut -d'|' -f1 | sed 's/ *$//')

  if [[ "$APP_NAME" == ---* ]]; then continue; fi

  case "$APP_NAME" in
  "[34] Install Package") install_specific ;;
  "[35] Install All") install_all ;;
  "[36] Add Custom Tool") add_custom ;;
  "[00] Quit") exit 0 ;;
  *) run_app "$APP_NAME" ;;
  esac
done
