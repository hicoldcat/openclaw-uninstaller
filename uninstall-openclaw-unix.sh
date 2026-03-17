#!/usr/bin/env bash
set -u

TARGET="openclaw"
DRY_RUN=0
AUTO_YES=0
OFFICIAL_OK=0
PATTERN='openclaw|openclaw-gateway|claw-gateway|openclawd'
OS_NAME="$(uname -s 2>/dev/null || printf 'unknown')"
IS_MACOS=0
IS_LINUX=0

declare -a CMD_PATHS=()
declare -a PROCESS_LIST=()
declare -a SERVICE_LIST=()
declare -a FILE_LIST=()
declare -a PACKAGE_LIST=()
declare -a PATH_HINTS=()
declare -a SHELL_HINTS=()

case "$OS_NAME" in
  Darwin) IS_MACOS=1 ;;
  Linux) IS_LINUX=1 ;;
esac

usage() {
  cat <<'EOF'
Usage: ./uninstall-openclaw-unix.sh [--dry-run|-n] [--yes|-y] [--help|-h]

Options:
  --dry-run, -n  Preview actions without modifying the system
  --yes, -y      Skip confirmation prompt
  --help, -h     Show this help message
EOF
}

for arg in "$@"; do
  case "$arg" in
    --dry-run|-n) DRY_RUN=1 ;;
    --yes|-y) AUTO_YES=1 ;;
    --help|-h) usage; exit 0 ;;
  esac
done

step() { printf "\n==> [%s] %s\n" "$1" "$2"; }
info() { printf " - %s\n" "$1"; }
warn() { printf " ! %s\n" "$1"; }
cmd_exists() { command -v "$1" >/dev/null 2>&1; }

contains_item() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    [ "$item" = "$needle" ] && return 0
  done
  return 1
}

add_unique() {
  local array_name="$1"
  local value="$2"
  set +u
  eval "local existing=(\"\${${array_name}[@]}\")"
  set -u
  contains_item "$value" "${existing[@]}" && return 0
  eval "${array_name}+=(\"\$value\")"
}

run_cmd() {
  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] $*"
    return 0
  fi
  info "running: $*"
  "$@" || true
}

remove_if_exists() {
  local p="$1"
  if [ -e "$p" ] || [ -L "$p" ]; then
    if [ -w "$p" ]; then
      run_cmd rm -rf "$p"
    else
      run_cmd sudo rm -rf "$p"
    fi
  fi
}

scan_commands() {
  local path
  if cmd_exists "$TARGET"; then
    path="$(command -v "$TARGET" 2>/dev/null)"
    [ -n "$path" ] && add_unique CMD_PATHS "$path"
  fi

  while IFS= read -r path; do
    [ -n "$path" ] && add_unique CMD_PATHS "$path"
  done < <(which -a "$TARGET" 2>/dev/null || true)
}

scan_processes() {
  local line
  while IFS= read -r line; do
    [ -n "$line" ] && add_unique PROCESS_LIST "$line"
  done < <(pgrep -af "$PATTERN" 2>/dev/null || true)
}

scan_services() {
  local svc
  if [ "$IS_MACOS" -eq 1 ] && cmd_exists brew; then
    for svc in openclaw openclaw-gateway claw-gateway; do
      brew services list 2>/dev/null | grep -E "^${svc}[[:space:]]" >/dev/null 2>&1 && add_unique SERVICE_LIST "brew service: $svc"
    done
  fi

  if [ "$IS_LINUX" -eq 1 ] && cmd_exists systemctl; then
    for svc in openclaw openclaw-gateway claw-gateway openclawd; do
      systemctl list-unit-files 2>/dev/null | grep -E "^${svc}(\.service)?[[:space:]]" >/dev/null 2>&1 && add_unique SERVICE_LIST "systemd service: $svc"
    done
  fi
}

scan_files() {
  local p
  for p in \
    "$HOME/.openclaw" \
    "$HOME/.config/openclaw" \
    "$HOME/.cache/openclaw" \
    "$HOME/.local/bin/openclaw" \
    "$HOME/bin/openclaw" \
    "$HOME/.openclaw/bin/openclaw" \
    "/usr/local/bin/openclaw"
  do
    ([ -e "$p" ] || [ -L "$p" ]) && add_unique FILE_LIST "$p"
  done

  if [ "$IS_MACOS" -eq 1 ]; then
    for p in \
      "$HOME/Library/Application Support/openclaw" \
      "$HOME/Library/Caches/openclaw" \
      "$HOME/Library/Logs/openclaw" \
      "/opt/homebrew/bin/openclaw" \
      "/Applications/OpenClaw.app"
    do
      ([ -e "$p" ] || [ -L "$p" ]) && add_unique FILE_LIST "$p"
    done

    for p in "$HOME/Library/LaunchAgents"/com.openclaw.*.plist "/Library/LaunchDaemons"/com.openclaw.*.plist; do
      [ -e "$p" ] && add_unique FILE_LIST "$p"
    done
  fi

  if [ "$IS_LINUX" -eq 1 ]; then
    for p in \
      "/usr/bin/openclaw" \
      "$HOME/.local/share/openclaw" \
      "$HOME/.local/share/applications/openclaw.desktop" \
      "/usr/share/applications/openclaw.desktop" \
      "/opt/openclaw"
    do
      ([ -e "$p" ] || [ -L "$p" ]) && add_unique FILE_LIST "$p"
    done

    for p in /etc/systemd/system/openclaw*.service; do
      [ -e "$p" ] && add_unique FILE_LIST "$p"
    done
  fi
}

scan_packages() {
  local pkg
  for pkg in openclaw @openclaw/cli @openclaw/openclaw; do
    cmd_exists npm && npm list -g --depth=0 "$pkg" >/dev/null 2>&1 && add_unique PACKAGE_LIST "npm: $pkg"
    cmd_exists pnpm && pnpm list -g --depth=0 "$pkg" >/dev/null 2>&1 && add_unique PACKAGE_LIST "pnpm: $pkg"
    cmd_exists yarn && yarn global list --pattern "$pkg" 2>/dev/null | grep -F "$pkg" >/dev/null 2>&1 && add_unique PACKAGE_LIST "yarn: $pkg"
  done
}

scan_env_hints() {
  local old_ifs path_entry rc_file
  old_ifs="$IFS"
  IFS=':'
  for path_entry in ${PATH:-}; do
    case "$path_entry" in
      *openclaw*|*OpenClaw*) add_unique PATH_HINTS "$path_entry" ;;
    esac
  done
  IFS="$old_ifs"

  for rc_file in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile" "$HOME/.zshrc" "$HOME/.zprofile" "$HOME/.config/fish/config.fish"; do
    if [ -f "$rc_file" ] && grep -nEi 'openclaw|OpenClaw' "$rc_file" >/dev/null 2>&1; then
      add_unique SHELL_HINTS "$rc_file"
    fi
  done
}

scan_all() {
  CMD_PATHS=()
  PROCESS_LIST=()
  SERVICE_LIST=()
  FILE_LIST=()
  PACKAGE_LIST=()
  PATH_HINTS=()
  SHELL_HINTS=()
  scan_commands
  scan_processes
  scan_services
  scan_files
  scan_packages
  scan_env_hints
}

print_section() {
  local title="$1"
  shift
  local items=("$@")
  printf "\n%s\n" "$title"
  if [ "${#items[@]}" -eq 0 ]; then
    info "none detected"
    return
  fi
  local item
  for item in "${items[@]}"; do
    info "$item"
  done
}

print_summary() {
  set +u
  step "1/6" "扫描当前环境并展示待卸载内容"
  print_section "[commands]" "${CMD_PATHS[@]}"
  print_section "[processes]" "${PROCESS_LIST[@]}"
  print_section "[services]" "${SERVICE_LIST[@]}"
  print_section "[packages]" "${PACKAGE_LIST[@]}"
  print_section "[files]" "${FILE_LIST[@]}"
  print_section "[path hints]" "${PATH_HINTS[@]}"
  print_section "[shell config hints]" "${SHELL_HINTS[@]}"
  set -u
}

confirm_uninstall() {
  local answer
  if [ "$DRY_RUN" -eq 1 ]; then
    info "dry-run mode: preview complete, no changes were made"
    exit 0
  fi

  if [ "$AUTO_YES" -eq 1 ]; then
    info "auto-confirm enabled, continuing uninstall"
    return
  fi

  printf "\nProceed with uninstall? [y/N]: "
  read -r answer
  case "$answer" in
    y|Y|yes|YES) ;;
    *) info "uninstall cancelled by user"; exit 0 ;;
  esac
}

print_path_guidance() {
  set +u
  if [ "${#PATH_HINTS[@]}" -eq 0 ] && [ "${#SHELL_HINTS[@]}" -eq 0 ]; then
    set -u
    return
  fi

  step "6/6" "PATH 和 shell 配置手动清理说明"
  if [ "${#PATH_HINTS[@]}" -gt 0 ]; then
    warn "PATH 中仍存在与 OpenClaw 相关的目录，请从环境变量 PATH 删除这些条目："
    local item
    for item in "${PATH_HINTS[@]}"; do
      info "$item"
    done
  fi

  if [ "${#SHELL_HINTS[@]}" -gt 0 ]; then
    warn "请打开以下 shell 配置文件，删除 openclaw 相关的 export、alias 或 PATH 语句："
    local file
    for file in "${SHELL_HINTS[@]}"; do
      info "$file"
    done
  fi

  info "修改后请重新打开 Terminal，或执行 'exec $SHELL' 让配置生效。"
  set -u
}

step "0/6" "流程说明"
info "1) 扫描安装、进程、服务、包和残留文件"
info "2) 把扫描结果列出来，让你确认是否继续"
info "3) 优先尝试官方卸载命令"
info "4) 如仍残留，再停止进程/服务并执行兜底卸载"
info "5) 清理残留并重新验证"
info "6) 如果 PATH 或 shell 配置还有残留，告诉你去哪里删除"
[ "$DRY_RUN" -eq 1 ] && info "当前为预览模式，不会真正修改系统"

scan_all
set +u
if [ "${#CMD_PATHS[@]}" -eq 0 ] && [ "${#PROCESS_LIST[@]}" -eq 0 ] && [ "${#SERVICE_LIST[@]}" -eq 0 ] && [ "${#PACKAGE_LIST[@]}" -eq 0 ] && [ "${#FILE_LIST[@]}" -eq 0 ]; then
  step "1/6" "扫描当前环境并展示待卸载内容"
  info "未检测到 openclaw，已跳过卸载。"
  set -u
  print_path_guidance
  exit 0
fi
set -u

print_summary
confirm_uninstall

step "2/6" "优先尝试官方卸载命令"
if cmd_exists "$TARGET"; then
  run_cmd "$TARGET" uninstall --all --yes
  scan_all
  set +u
  if [ "${#CMD_PATHS[@]}" -eq 0 ] && [ "${#PROCESS_LIST[@]}" -eq 0 ] && [ "${#SERVICE_LIST[@]}" -eq 0 ]; then
    OFFICIAL_OK=1
    info "official uninstall completed successfully"
  else
    warn "official uninstall finished but traces still remain"
  fi
  set -u
else
  info "official cli not found, skip direct uninstall"
fi

step "3/6" "执行兜底卸载动作"
if [ "$OFFICIAL_OK" -eq 1 ]; then
  info "skip process/service fallback because official uninstall already removed runtime traces"
else
  [ "${#PROCESS_LIST[@]}" -gt 0 ] && run_cmd pkill -f "$PATTERN"
  [ "${#PROCESS_LIST[@]}" -gt 0 ] && run_cmd sudo pkill -f "$PATTERN"

  if [ "$IS_MACOS" -eq 1 ] && cmd_exists brew; then
    run_cmd brew services stop openclaw
    run_cmd brew services stop openclaw-gateway
    run_cmd brew services stop claw-gateway
  fi

  if [ "$IS_LINUX" -eq 1 ] && cmd_exists systemctl; then
    for svc in openclaw openclaw-gateway claw-gateway openclawd; do
      run_cmd sudo systemctl stop "$svc"
      run_cmd sudo systemctl disable "$svc"
    done
  fi
fi

for pkg in openclaw @openclaw/cli @openclaw/openclaw; do
  cmd_exists npm && run_cmd npm uninstall -g "$pkg"
  cmd_exists pnpm && run_cmd pnpm remove -g "$pkg"
  cmd_exists yarn && run_cmd yarn global remove "$pkg"
done

if [ "$OFFICIAL_OK" -ne 1 ]; then
  if [ "$IS_MACOS" -eq 1 ] && cmd_exists brew; then
    run_cmd brew uninstall openclaw
    run_cmd brew uninstall --cask openclaw
  fi

  if [ "$IS_LINUX" -eq 1 ]; then
    cmd_exists apt-get && run_cmd sudo apt-get remove -y openclaw
    cmd_exists dnf && run_cmd sudo dnf remove -y openclaw
    cmd_exists yum && run_cmd sudo yum remove -y openclaw
    cmd_exists pacman && run_cmd sudo pacman -Rns --noconfirm openclaw
    cmd_exists zypper && run_cmd sudo zypper -n rm openclaw
    cmd_exists snap && run_cmd sudo snap remove openclaw
    cmd_exists flatpak && run_cmd flatpak uninstall -y openclaw
  fi
fi

step "4/6" "清理残留文件"
for item in "${FILE_LIST[@]}"; do
  remove_if_exists "$item"
done

step "5/6" "最终验证"
scan_all
set +u
print_section "[remaining commands]" "${CMD_PATHS[@]}"
print_section "[remaining processes]" "${PROCESS_LIST[@]}"
print_section "[remaining services]" "${SERVICE_LIST[@]}"
print_section "[remaining packages]" "${PACKAGE_LIST[@]}"
print_section "[remaining files]" "${FILE_LIST[@]}"

if [ "${#CMD_PATHS[@]}" -gt 0 ] || [ "${#PROCESS_LIST[@]}" -gt 0 ] || [ "${#SERVICE_LIST[@]}" -gt 0 ] || [ "${#PACKAGE_LIST[@]}" -gt 0 ] || [ "${#FILE_LIST[@]}" -gt 0 ]; then
  warn "仍检测到部分残留，请参考上面的列表继续手动处理。"
fi
set -u

print_path_guidance
echo "卸载流程执行完成。"
