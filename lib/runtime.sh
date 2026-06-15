release_config_lock() {
  if [ -n "${_CONFIG_LOCK_DIR:-}" ]; then
    rm -f "$_CONFIG_LOCK_DIR/pid" "$_CONFIG_LOCK_DIR/created"
    rmdir "$_CONFIG_LOCK_DIR" 2>/dev/null || true
    _CONFIG_LOCK_DIR=""
  fi
}

cleanup() {
  if [ -n "${_CLEANUP_TMP_FILE:-}" ]; then
    rm -f "$_CLEANUP_TMP_FILE"
    _CLEANUP_TMP_FILE=""
  fi

  release_config_lock
}

cleanup_and_exit() {
  cleanup
  exit 130
}

acquire_config_lock() {
  local lock_dir="${CONFIG_FILE}.lock"
  local attempts=0 pid created now age

  while ! mkdir "$lock_dir" 2>/dev/null; do
    pid=""
    created=""
    [ -f "$lock_dir/pid" ] && pid="$(cat "$lock_dir/pid" 2>/dev/null || true)"
    [ -f "$lock_dir/created" ] && created="$(cat "$lock_dir/created" 2>/dev/null || true)"
    now="$(date +%s 2>/dev/null || printf 0)"
    age=0
    if [[ "$created" =~ ^[0-9]+$ ]] && [ "$now" -gt 0 ]; then
      age=$((now - created))
    fi

    if { [ -z "$pid" ] && [ "$attempts" -ge 10 ]; } || { [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; } || { [ "$age" -gt "$CONFIG_LOCK_STALE_SECONDS" ]; }; then
      rm -f "$lock_dir/pid" "$lock_dir/created"
      rmdir "$lock_dir" 2>/dev/null || true
      continue
    fi

    attempts=$((attempts + 1))
    if [ "$attempts" -ge 100 ]; then
      error "获取配置锁超时: $lock_dir"
      return 1
    fi
    sleep 0.1
  done

  _CONFIG_LOCK_DIR="$lock_dir"
  printf '%s\n' "$$" > "$lock_dir/pid" 2>/dev/null || true
  date +%s > "$lock_dir/created" 2>/dev/null || true
}

show_version() {
  printf '%s\n' "$VERSION"
}

platform() {
  local os

  if [ -n "$_PLATFORM" ]; then
    printf '%s\n' "$_PLATFORM"
    return
  fi

  os="${DEV_PLATFORM:-$(uname -s 2>/dev/null || printf unknown)}"

  case "$os" in
    mac|darwin|Darwin*) _PLATFORM="mac" ;;
    win|windows|Windows*|MINGW*|MSYS*|CYGWIN*) _PLATFORM="win" ;;
    wsl|WSL*) _PLATFORM="wsl" ;;
    Linux*)
      if grep -qi microsoft /proc/version 2>/dev/null; then
        _PLATFORM="wsl"
      else
        _PLATFORM="linux"
      fi
      ;;
    *) _PLATFORM="unix" ;;
  esac

  printf '%s\n' "$_PLATFORM"
}

expand_home() {
  local input="$1"

  case "$input" in
    "~") printf '%s\n' "$HOME" ;;
    "~/"*) printf '%s/%s\n' "$HOME" "${input#~/}" ;;
    *) printf '%s\n' "$input" ;;
  esac
}

to_posix_path() {
  local input
  input="$(expand_home "$1")"

  case "$(platform)" in
    win)
      case "$input" in
        [A-Za-z]:\\*|[A-Za-z]:/*|\\\\*)
          if command -v cygpath >/dev/null 2>&1; then
            cygpath -u "$input"
            return
          fi
          ;;
      esac
      ;;
  esac

  printf '%s\n' "$input"
}

to_native_path() {
  local input="$1"

  case "$(platform)" in
    win)
      if command -v cygpath >/dev/null 2>&1; then
        cygpath -w "$input"
      else
        printf '%s\n' "$input"
      fi
      ;;
    wsl)
      if command -v wslpath >/dev/null 2>&1; then
        wslpath -w "$input"
      else
        printf '%s\n' "$input"
      fi
      ;;
    *)
      printf '%s\n' "$input"
      ;;
  esac
}

canonical_dir() {
  local input="$1"
  local path
  path="$(to_posix_path "$input")"

  if [ -d "$path" ]; then
    cd "$path" && pwd -P
  else
    return 1
  fi
}

open_directory() {
  local path="$1"
  local native

  if [ ! -d "$path" ]; then
    error "文件夹不存在: $path"
    return 1
  fi

  echo "📂 $path"

  if [ -n "${DEV_OPEN_CMD:-}" ]; then
    "$DEV_OPEN_CMD" "$path"
    return
  fi

  case "$(platform)" in
    mac)
      command -v open >/dev/null 2>&1 || { error "找不到 open 命令"; return 1; }
      open "$path"
      ;;
    win)
      native="$(to_native_path "$path")"
      if command -v explorer.exe >/dev/null 2>&1; then
        explorer.exe "$native"
      elif command -v cmd.exe >/dev/null 2>&1; then
        cmd.exe /c start "" "$native"
      else
        error "找不到 explorer.exe 或 cmd.exe"
        return 1
      fi
      ;;
    wsl)
      native="$(to_native_path "$path")"
      if command -v explorer.exe >/dev/null 2>&1; then
        explorer.exe "$native"
      elif command -v wslview >/dev/null 2>&1; then
        wslview "$path"
      elif command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$path" >/dev/null 2>&1 &
      else
        error "找不到 explorer.exe、wslview 或 xdg-open"
        return 1
      fi
      ;;
    *)
      command -v xdg-open >/dev/null 2>&1 || { error "找不到 xdg-open 命令"; return 1; }
      xdg-open "$path" >/dev/null 2>&1 &
      ;;
  esac
}

parse_target_args() {
  PARSED_OPEN_DESKTOP=0
  PARSED_TARGET=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -d|--directory)
        PARSED_OPEN_DESKTOP=1
        ;;
      --)
        shift
        while [ "$#" -gt 0 ]; do
          PARSED_TARGET="${PARSED_TARGET:+$PARSED_TARGET }$1"
          shift
        done
        break
        ;;
      *)
        PARSED_TARGET="${PARSED_TARGET:+$PARSED_TARGET }$1"
        ;;
    esac
    shift
  done
}

cmd_resolve_dir() {
  local mode="$1"
  local missing_message="$2"
  local not_found_message="$3"
  local show_usage="$4"
  local path
  shift 4

  parse_target_args "$@"
  if [ -z "$PARSED_TARGET" ]; then
    error "$missing_message"
    [ "$show_usage" -eq 1 ] && usage
    return 1
  fi

  case "$mode" in
    target)
      path="$(resolve_target_dir "$PARSED_TARGET")" || {
        error "$not_found_message: $PARSED_TARGET"
        return 1
      }
      ;;
    path)
      path="$(canonical_dir "$PARSED_TARGET")" || {
        error "$not_found_message: $PARSED_TARGET"
        return 1
      }
      ;;
  esac

  if [ "$PARSED_OPEN_DESKTOP" -eq 1 ]; then
    open_directory "$path"
  else
    printf '%s\n' "$path"
  fi
}

cmd_open() {
  cmd_resolve_dir target "缺少名称或文件夹路径" "未找到项目或文件夹" 1 "$@"
}

cmd_path() {
  cmd_resolve_dir path "缺少文件夹路径" "未找到文件夹路径" 0 "$@"
}

cmd_shell_init() {
  cat <<EOF
function dev() {
  local dev_bin="$SCRIPT_FILE"
  local should_cd=0
  local arg target target_path

  if [[ "\${1:-}" == "o" || "\${1:-}" == "open" ]]; then
    should_cd=1
    for arg in "\${@:2}"; do
      if [[ "\$arg" == "-d" || "\$arg" == "--directory" ]]; then
        should_cd=0
        break
      fi
    done

    if [[ "\$should_cd" -eq 1 ]]; then
      target="\$("\$dev_bin" "\$@")" || return \$?
      cd "\$target" || return
      pwd
      return
    fi
  fi

  target_path="\${1:-}"
  case "\$target_path" in
    "~") target_path="\$HOME" ;;
    "~/"*) target_path="\$HOME/\${target_path#~/}" ;;
  esac

  if [[ -n "\$target_path" && -d "\$target_path" ]]; then
    should_cd=1
    for arg in "\${@:2}"; do
      if [[ "\$arg" == "-d" || "\$arg" == "--directory" ]]; then
        should_cd=0
        break
      fi
    done

    if [[ "\$should_cd" -eq 1 ]]; then
      cd "\$target_path" || return
      pwd
      return
    fi

    "\$dev_bin" o "\$target_path" -d
    return
  fi

  "\$dev_bin" "\$@"
}
EOF
}
