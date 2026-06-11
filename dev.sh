#!/usr/bin/env bash

set -uo pipefail

VERSION="1.5.1"
CONFIG_HEADER="# 短名称|项目路径|启动命令"
COMMAND_SHOW_LINES=240
CONFIG_LOCK_STALE_SECONDS="${DEV_CONFIG_LOCK_STALE_SECONDS:-3600}"
_PLATFORM=""
_CONFIG_LOCK_DIR=""
_CLEANUP_TMP_FILE=""
ENTRY_FORMAT=""
ENTRY_NAME=""
ENTRY_PATH=""
ENTRY_CMD_TEXT=""
ENTRY_CMD_ARGS=()

resolve_script_path() {
  local source="$1"
  local source_dir

  while [ -L "$source" ]; do
    source_dir="$(cd "$(dirname "$source")" && pwd -P)"
    source="$(readlink "$source")"
    [[ "$source" != /* ]] && source="$source_dir/$source"
  done

  cd "$(dirname "$source")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$source")"
}

SCRIPT_FILE="$(resolve_script_path "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_FILE")" && pwd -P)"
CONFIG_FILE="${DEV_CONFIG_FILE:-$SCRIPT_DIR/dev.conf}"
COMMANDS_DIR="${DEV_COMMANDS_DIR:-$SCRIPT_DIR/commands}"

usage() {
  cat <<'EOF'
用法:
  dev --help                  显示帮助和示例
  dev                         列出已配置项目
  dev <文件夹路径>            进入目录，-d 打开文件夹
  dev open|o <名称|文件夹路径> 进入目录，-d 打开文件夹
  dev run|x <名称>            运行已配置项目命令
  dev add [名称] [路径] [命令] 添加项目或文件夹
  dev del|rm <名称>           删除已配置项目
  dev cmd|c                   列出常用命令
  dev cmd|c show <名称>       查看常用命令脚本
  dev cmd|c run|x <名称> [...] 执行常用命令
  dev cmd|c add <名称> [-d 说明] [-- 命令] 添加常用命令
  dev cmd|c edit <名称>       编辑常用命令
  dev cmd|c del|rm <名称>     删除常用命令
  dev version                 显示版本号
  dev shell-init              输出 bash/zsh 当前终端 cd 集成脚本

示例:
  dev --help                  显示帮助和示例
  dev o ztools                进入 ztools 项目目录
  dev o ztools -d             打开 ztools 文件夹
  dev /tmp                    进入 /tmp
  dev /tmp -d                 打开 /tmp 文件夹
  dev x claw                  进入 claw 项目目录并执行配置命令
  dev c                       列出常用命令
  dev c show kill-port        查看释放端口命令
  dev c x kill-port 3000      释放 3000 端口
  dev c add ports -d "查看 3000 端口占用" -- lsof -i tcp:3000
  dev del ztools              删除 ztools 配置，不删除真实文件夹
  dev add claw ...            重复名称或目录时会询问是否覆盖
  dev add                     添加当前文件夹，名称使用文件夹名，命令为 open .
  dev add -- npm run dev      添加当前文件夹并指定命令
  dev add ztools              添加当前文件夹，名称为 ztools
  dev add ~/projects/ZTools   添加指定文件夹，名称使用文件夹名
  dev add ztools -- npm run dev
  dev add claw ~/projects/app npm run dev
EOF
}

error() {
  printf '❌ %s\n' "$*" >&2
}

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

trap cleanup EXIT
trap cleanup_and_exit INT TERM

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

is_folder_entry() {
  [ "$1" = "open ." ]
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

ensure_config() {
  if [ ! -f "$CONFIG_FILE" ]; then
    printf '%s\n' "$CONFIG_HEADER" > "$CONFIG_FILE" || {
      error "写入配置文件失败: $CONFIG_FILE"
      return 1
    }
  fi
}

config_entries() {
  [ -f "$CONFIG_FILE" ] || return 0
  awk 'NF && $0 !~ /^[[:space:]]*#/' "$CONFIG_FILE"
}

b64_encode_field() {
  printf '%s' "$1" | base64 | tr -d '\n'
}

b64_decode_field() {
  local input="$1"

  if printf '%s' "$input" | base64 --decode 2>/dev/null; then
    return 0
  fi

  if printf '%s' "$input" | base64 -d 2>/dev/null; then
    return 0
  fi

  printf '%s' "$input" | base64 -D 2>/dev/null
}

join_command_display() {
  local arg quoted first=1

  for arg in "$@"; do
    printf -v quoted '%q' "$arg"
    if [ "$first" -eq 1 ]; then
      printf '%s' "$quoted"
      first=0
    else
      printf ' %s' "$quoted"
    fi
  done
}

format_config_entry() {
  local field

  printf 'v2'
  for field in "$@"; do
    printf '|%s' "$(b64_encode_field "$field")"
  done
  printf '\n'
}

parse_config_line() {
  local line="$1"
  local name path cmd
  local -a parts args
  local i decoded

  ENTRY_FORMAT=""
  ENTRY_NAME=""
  ENTRY_PATH=""
  ENTRY_CMD_TEXT=""
  ENTRY_CMD_ARGS=()

  IFS='|' read -r -a parts <<< "$line"
  if [ "${parts[0]:-}" = "v2" ]; then
    [ "${#parts[@]}" -ge 4 ] || return 1
    ENTRY_FORMAT="v2"
    ENTRY_NAME="$(b64_decode_field "${parts[1]}")" || return 1
    ENTRY_PATH="$(b64_decode_field "${parts[2]}")" || return 1

    args=()
    for ((i = 3; i < ${#parts[@]}; i++)); do
      decoded="$(b64_decode_field "${parts[$i]}")" || return 1
      args+=("$decoded")
    done

    ENTRY_CMD_ARGS=("${args[@]}")
    ENTRY_CMD_TEXT="$(join_command_display "${ENTRY_CMD_ARGS[@]}")"
    return 0
  fi

  IFS='|' read -r name path cmd <<< "$line"
  [ -n "${name:-}" ] && [ -n "${path:-}" ] && [ -n "${cmd:-}" ] || return 1
  ENTRY_FORMAT="legacy"
  ENTRY_NAME="$name"
  ENTRY_PATH="$path"
  ENTRY_CMD_TEXT="$cmd"
  read -r -a ENTRY_CMD_ARGS <<< "$cmd"
}

entry_is_folder() {
  [ "${#ENTRY_CMD_ARGS[@]}" -eq 2 ] && [ "${ENTRY_CMD_ARGS[0]}" = "open" ] && [ "${ENTRY_CMD_ARGS[1]}" = "." ]
}

read_project_entry() {
  local target="$1"
  local line

  while IFS= read -r line; do
    parse_config_line "$line" || continue
    if [ "$ENTRY_NAME" = "$target" ]; then
      printf '%s\n' "$line"
      return 0
    fi
  done < <(config_entries)

  return 1
}

project_exists() {
  read_project_entry "$1" >/dev/null
}

project_dir() {
  local target="$1"
  local entry

  entry="$(read_project_entry "$target")" || return 1
  parse_config_line "$entry" || return 1
  canonical_dir "$ENTRY_PATH"
}

resolve_target_dir() {
  local target="$1"

  project_dir "$target" 2>/dev/null || canonical_dir "$target"
}

find_conflict_entry() {
  local target_name="$1"
  local target_path="$2"
  local line existing_path

  while IFS= read -r line; do
    parse_config_line "$line" || continue
    existing_path="$(canonical_dir "$ENTRY_PATH" 2>/dev/null || to_posix_path "$ENTRY_PATH")"
    if [ "$ENTRY_NAME" = "$target_name" ] || [ "$existing_path" = "$target_path" ]; then
      printf '%s\n' "$line"
      return 0
    fi
  done < <(config_entries)

  return 1
}

validate_name() {
  local name="$1"

  if [[ -z "$name" || "$name" == *"|"* ]]; then
    error "名称不能为空，也不能包含 |"
    return 1
  fi
}

validate_cmd() {
  local cmd="$1"

  if [[ -z "$cmd" || "$cmd" == *"|"* ]]; then
    error "命令不能为空，也不能包含 |"
    return 1
  fi
}

validate_path() {
  local path="$1"

  if [ -z "$path" ]; then
    error "路径不能为空"
    return 1
  fi
}

validate_cmd_args() {
  if [ "$#" -eq 0 ]; then
    error "命令不能为空"
    return 1
  fi
}

validate_single_line() {
  local label="$1"
  local value="$2"

  if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
    error "$label 不能包含换行"
    return 1
  fi
}

command_usage() {
  cat <<'EOF'
常用命令用法:
  dev cmd|c                         列出常用命令
  dev cmd|c list|ls                 列出常用命令
  dev cmd|c show <名称>             查看常用命令脚本
  dev cmd|c <名称>                  查看常用命令脚本
  dev cmd|c run|x <名称> [参数...]  执行常用命令
  dev cmd|c add <名称>              创建脚本并打开编辑器
  dev cmd|c add <名称> -d 说明      创建带说明的脚本并打开编辑器
  dev cmd|c add <名称> [-d 说明] -- <命令>
                                   保存一行命令
  dev cmd|c edit <名称>             编辑常用命令
  dev cmd|c del|rm <名称>           删除常用命令

示例:
  dev c
  dev c show kill-port
  dev c x kill-port 3000
  dev c add ports -d "查看 3000 端口占用" -- lsof -i tcp:3000
EOF
}

ensure_commands_dir() {
  if [ ! -d "$COMMANDS_DIR" ]; then
    mkdir -p "$COMMANDS_DIR"
  fi
}

validate_command_name() {
  local name="$1"

  if [[ -z "$name" || "$name" = "." || "$name" = ".." || "$name" == .* || "$name" == */* || "$name" == *\\* ]]; then
    error "命令名称不能为空，不能以 . 开头，也不能包含路径分隔符"
    return 1
  fi

  if [[ ! "$name" =~ ^[A-Za-z0-9._-]+$ ]]; then
    error "命令名称只能包含字母、数字、点、下划线和短横线"
    return 1
  fi
}

command_script_path() {
  local name="$1"
  printf '%s/%s.sh\n' "$COMMANDS_DIR" "$name"
}

resolve_command_script() {
  local name="$1"
  local script

  validate_command_name "$name" || return 1
  script="$(command_script_path "$name")"

  if [ -f "$script" ]; then
    printf '%s\n' "$script"
    return 0
  fi

  return 1
}

read_command_meta() {
  local file="$1"
  local key_regex="$2"

  awk -v key_regex="$key_regex" '
    BEGIN {
      pattern = "^#[[:space:]]*" key_regex ":[[:space:]]*"
    }
    $0 ~ pattern {
      sub(pattern, "")
      print
      exit
    }
  ' "$file"
}

read_command_description() {
  read_command_meta "$1" "(desc|description)"
}

read_command_usage() {
  read_command_meta "$1" "usage"
}

print_command_list() {
  local name_width="$1"
  local empty_message="$2"
  local file command_name desc count=0

  ensure_commands_dir || return 1

  while IFS= read -r file; do
    [ -f "$file" ] || continue
    command_name="$(basename "$file" .sh)"
    desc="$(read_command_description "$file")"

    if [ -n "$desc" ]; then
      printf "  \033[36m%-*s\033[0m → %s\n" "$name_width" "$command_name" "$desc"
    else
      printf "  \033[36m%-*s\033[0m → %s\n" "$name_width" "$command_name" "$file"
    fi

    count=$((count + 1))
  done < <(find "$COMMANDS_DIR" -maxdepth 1 -type f -name '*.sh' -print | sort)

  [ "$count" -eq 0 ] && echo "  $empty_message"
  return 0
}

write_command_template() {
  local name="$1"
  local script="$2"
  local desc="${3:-}"

  validate_single_line "说明" "$desc" || return 1

  {
    printf '#!/usr/bin/env bash\n'
    printf '# desc: %s\n' "$desc"
    printf '# usage: dev c x %s [args...]\n\n' "$name"
    printf 'set -euo pipefail\n\n'
    printf '# 在这里写命令。参数可用 "$1"、"$2" ... 获取。\n'
  } > "$script"

  chmod +x "$script"
}

write_one_line_command() {
  local name="$1"
  local script="$2"
  local desc="$3"
  local command_line="$4"

  validate_single_line "说明" "$desc" || return 1
  validate_single_line "命令" "$command_line" || return 1

  {
    printf '#!/usr/bin/env bash\n'
    printf '# desc: %s\n' "$desc"
    printf '# usage: dev c x %s [args...]\n\n' "$name"
    printf 'set -euo pipefail\n\n'
    printf '%s\n' "$command_line"
  } > "$script"

  chmod +x "$script"
}

open_command_editor() {
  local script="$1"
  local editor="${VISUAL:-${EDITOR:-vi}}"

  if ! $editor "$script"; then
    error "编辑器退出失败: $editor"
    return 1
  fi
}

confirm_command_overwrite() {
  local name="$1"
  local script="$2"
  local answer

  echo "⚠️ 常用命令已存在: $name → $script"
  printf "是否覆盖？输入 y/yes 确认: "

  if ! read -r answer; then
    echo ""
    echo "已取消"
    return 1
  fi

  case "$answer" in
    y|Y|yes|YES) return 0 ;;
    *) echo "已取消"; return 1 ;;
  esac
}

confirm_overwrite() {
  local old_name="$1"
  local old_path="$2"
  local old_cmd="$3"
  local new_name="$4"
  local new_path="$5"
  local new_cmd="$6"
  local answer

  echo "⚠️ 已存在相同名称或目录:"
  echo "   当前: $old_name → $old_path ($old_cmd)"
  echo "   新的: $new_name → $new_path ($new_cmd)"
  printf "是否覆盖？输入 y/yes 确认: "

  if ! read -r answer; then
    echo ""
    echo "已取消"
    return 1
  fi

  case "$answer" in
    y|Y|yes|YES) return 0 ;;
    *) echo "已取消"; return 1 ;;
  esac
}

write_entry() {
  local entry_name="$1"
  local entry_path="$2"
  local replace_conflicts="$3"
  shift 3
  local tmp_file line existing_path written=0 new_line

  new_line="$(format_config_entry "$entry_name" "$entry_path" "$@")"

  ensure_config || return 1

  if [ "$replace_conflicts" != "1" ]; then
    printf '%s\n' "$new_line" >> "$CONFIG_FILE" || {
      error "写入配置文件失败: $CONFIG_FILE"
      return 1
    }
    return
  fi

  tmp_file="$(mktemp "${CONFIG_FILE}.XXXXXX")" || {
    error "创建临时文件失败"
    return 1
  }
  _CLEANUP_TMP_FILE="$tmp_file"

  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^[[:space:]]*# || -z "$line" ]]; then
      printf '%s\n' "$line" >> "$tmp_file"
      continue
    fi

    parse_config_line "$line" || {
      printf '%s\n' "$line" >> "$tmp_file"
      continue
    }
    existing_path="$(canonical_dir "$ENTRY_PATH" 2>/dev/null || to_posix_path "$ENTRY_PATH")"
    if [ "$ENTRY_NAME" = "$entry_name" ] || [ "$existing_path" = "$entry_path" ]; then
      if [ "$written" -eq 0 ]; then
        printf '%s\n' "$new_line" >> "$tmp_file"
        written=1
      fi
      continue
    fi

    printf '%s\n' "$line" >> "$tmp_file"
  done < "$CONFIG_FILE"

  if [ "$written" -eq 0 ]; then
    printf '%s\n' "$new_line" >> "$tmp_file"
  fi

  mv "$tmp_file" "$CONFIG_FILE" || {
    error "更新配置文件失败: $CONFIG_FILE"
    rm -f "$tmp_file"
    tmp_file=""
    _CLEANUP_TMP_FILE=""
    return 1
  }
  tmp_file=""
  _CLEANUP_TMP_FILE=""
}

delete_entry() {
  local target="$1"
  local tmp_file line removed=0

  [ -f "$CONFIG_FILE" ] || {
    error "配置文件不存在: $CONFIG_FILE"
    return 1
  }

  tmp_file="$(mktemp "${CONFIG_FILE}.XXXXXX")" || {
    error "创建临时文件失败"
    return 1
  }
  _CLEANUP_TMP_FILE="$tmp_file"

  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^[[:space:]]*# || -z "$line" ]]; then
      printf '%s\n' "$line" >> "$tmp_file"
      continue
    fi

    parse_config_line "$line" || {
      printf '%s\n' "$line" >> "$tmp_file"
      continue
    }
    if [ "$ENTRY_NAME" = "$target" ]; then
      removed=1
      continue
    fi

    printf '%s\n' "$line" >> "$tmp_file"
  done < "$CONFIG_FILE"

  if [ "$removed" -eq 1 ]; then
    mv "$tmp_file" "$CONFIG_FILE" || {
      error "更新配置文件失败: $CONFIG_FILE"
      rm -f "$tmp_file"
      tmp_file=""
      _CLEANUP_TMP_FILE=""
      return 1
    }
    tmp_file=""
    _CLEANUP_TMP_FILE=""
    return 0
  fi

  rm -f "$tmp_file"
  tmp_file=""
  _CLEANUP_TMP_FILE=""
  return 1
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

cmd_list() {
  local line count

  echo "dev-launcher: 快速进入目录、运行项目命令和调用常用命令。"
  echo ""
  echo "📋 已配置的项目:"
  echo ""
  echo "目录:"
  count=0
  while IFS= read -r line; do
    parse_config_line "$line" || continue
    if entry_is_folder; then
      printf "  \033[36m%-10s\033[0m → %s\n" "$ENTRY_NAME" "$ENTRY_PATH"
      count=$((count + 1))
    fi
  done < <(config_entries)
  [ "$count" -eq 0 ] && echo "  (无)"

  echo ""
  echo "项目:"
  count=0
  while IFS= read -r line; do
    parse_config_line "$line" || continue
    if ! entry_is_folder; then
      printf "  \033[36m%-10s\033[0m → %s  (%s)\n" "$ENTRY_NAME" "$ENTRY_PATH" "$ENTRY_CMD_TEXT"
      count=$((count + 1))
    fi
  done < <(config_entries)
  [ "$count" -eq 0 ] && echo "  (无)"

  echo ""
  echo "常用命令:"
  print_command_list 10 "(无)" || return 1
  echo ""
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

cmd_run() {
  local target="${1:-}"
  local entry path

  if [ -z "$target" ]; then
    error "缺少要运行的项目名称"
    usage
    return 1
  fi

  entry="$(read_project_entry "$target")" || {
    error "未找到项目: $target"
    echo ""
    cmd_list
    return 1
  }

  parse_config_line "$entry" || {
    error "配置记录无法解析: $target"
    return 1
  }

  path="$(canonical_dir "$ENTRY_PATH")" || {
    error "路径不存在: $ENTRY_PATH"
    return 1
  }

  validate_cmd_args "${ENTRY_CMD_ARGS[@]}" || return 1

  cd "$path" || return 1
  echo "📁 $(pwd -P)"
  echo "▶ $ENTRY_CMD_TEXT"
  command "${ENTRY_CMD_ARGS[@]}"
}

cmd_add() {
  local name="" path_arg="" cmd_display abs_path
  local conflict confirmed_conflict current_conflict conflict_name conflict_path conflict_cmd
  local -a cmd_args=("open" ".")

  if [ "$#" -eq 0 ]; then
    path_arg="$PWD"
    name="$(basename "$PWD")"
  elif [ "$1" = "--" ]; then
    path_arg="$PWD"
    name="$(basename "$PWD")"
    shift
    [ "$#" -gt 0 ] && cmd_args=("$@")
  elif [ "$#" -eq 1 ]; then
    if abs_path="$(canonical_dir "$1")"; then
      path_arg="$abs_path"
      name="$(basename "$abs_path")"
    else
      name="$1"
      path_arg="$PWD"
    fi
  elif [ "$2" = "--" ]; then
    if abs_path="$(canonical_dir "$1")"; then
      path_arg="$abs_path"
      name="$(basename "$abs_path")"
    else
      name="$1"
      path_arg="$PWD"
    fi
    shift 2
    [ "$#" -gt 0 ] && cmd_args=("$@")
  else
    name="$1"
    path_arg="$2"
    shift 2
    [ "$#" -gt 0 ] && cmd_args=("$@")
  fi

  validate_name "$name" || return 1
  validate_cmd_args "${cmd_args[@]}" || return 1
  cmd_display="$(join_command_display "${cmd_args[@]}")"

  abs_path="$(canonical_dir "$path_arg")" || {
    error "文件夹不存在: $path_arg"
    return 1
  }
  validate_path "$abs_path" || return 1

  confirmed_conflict=""
  while :; do
    conflict="$(find_conflict_entry "$name" "$abs_path" || true)"
    if [ -n "$conflict" ] && [ "$conflict" != "$confirmed_conflict" ]; then
      parse_config_line "$conflict" || return 1
      conflict_name="$ENTRY_NAME"
      conflict_path="$ENTRY_PATH"
      conflict_cmd="$ENTRY_CMD_TEXT"
      confirm_overwrite "$conflict_name" "$conflict_path" "$conflict_cmd" "$name" "$abs_path" "$cmd_display" || return 1
      confirmed_conflict="$conflict"
    fi

    acquire_config_lock || return 1
    current_conflict="$(find_conflict_entry "$name" "$abs_path" || true)"

    if [ -n "$current_conflict" ] && [ "$current_conflict" != "$confirmed_conflict" ]; then
      release_config_lock
      confirmed_conflict=""
      continue
    fi

    if [ -n "$current_conflict" ]; then
      write_entry "$name" "$abs_path" 1 "${cmd_args[@]}" || {
        release_config_lock
        return 1
      }
      release_config_lock
      echo "✅ 已覆盖: $name → $abs_path ($cmd_display)"
      return
    fi

    write_entry "$name" "$abs_path" 0 "${cmd_args[@]}" || {
      release_config_lock
      return 1
    }
    release_config_lock
    echo "✅ 已添加: $name → $abs_path ($cmd_display)"
    return
  done
}

cmd_delete() {
  local target="${1:-}"

  if [ -z "$target" ]; then
    error "缺少要删除的项目名称"
    usage
    return 1
  fi

  acquire_config_lock || return 1

  if delete_entry "$target"; then
    release_config_lock
    echo "✅ 已删除配置: $target"
  else
    release_config_lock
    error "未找到项目: $target"
    echo ""
    cmd_list
    return 1
  fi
}

cmd_command_list() {
  echo "📋 常用命令:"
  echo ""
  print_command_list 16 "(无，使用 dev c add <名称> 创建)" || return 1
  echo ""
}

cmd_command_show() {
  local target="${1:-}"
  local script desc usage_line

  if [ -z "$target" ]; then
    error "缺少常用命令名称"
    command_usage
    return 1
  fi

  script="$(resolve_command_script "$target")" || {
    error "未找到常用命令: $target"
    echo ""
    cmd_command_list
    return 1
  }

  desc="$(read_command_description "$script")"
  usage_line="$(read_command_usage "$script")"

  echo "📌 $target"
  echo "📄 $script"
  [ -n "$desc" ] && echo "说明: $desc"
  [ -n "$usage_line" ] && echo "用法: $usage_line"
  echo ""
  echo "脚本:"
  sed -n "1,${COMMAND_SHOW_LINES}p" "$script"
}

cmd_command_run() {
  local target="${1:-}"
  local script

  if [ -z "$target" ]; then
    error "缺少要执行的常用命令名称"
    command_usage
    return 1
  fi

  shift
  script="$(resolve_command_script "$target")" || {
    error "未找到常用命令: $target"
    echo ""
    cmd_command_list
    return 1
  }

  echo "▶ $target $*"
  bash "$script" "$@"
}

cmd_command_add() {
  local name="${1:-}"
  local script desc="" command_line=""
  local saw_command_separator=0

  if [ -z "$name" ]; then
    error "缺少常用命令名称"
    command_usage
    return 1
  fi

  shift
  validate_command_name "$name" || return 1
  ensure_commands_dir || return 1
  script="$(command_script_path "$name")"

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -d|--desc)
        shift
        if [ "$#" -eq 0 ]; then
          error "缺少说明内容"
          return 1
        fi
        desc="$1"
        shift
        ;;
      --)
        shift
        saw_command_separator=1
        command_line="$*"
        break
        ;;
      *)
        error "未知参数: $1"
        echo "示例: dev c add ports -d \"查看 3000 端口占用\" -- lsof -i tcp:3000"
        return 1
        ;;
    esac
  done

  if [ "$saw_command_separator" -eq 1 ] && [ -z "$command_line" ]; then
    error "缺少命令内容"
    return 1
  fi

  if [ -f "$script" ]; then
    if [ -z "$command_line" ]; then
      echo "ℹ️ 已存在，将打开编辑器: $script"
      open_command_editor "$script"
      return
    fi

    confirm_command_overwrite "$name" "$script" || return 1
  fi

  if [ -n "$command_line" ]; then
    write_one_line_command "$name" "$script" "$desc" "$command_line" || return 1
    echo "✅ 已保存常用命令: $name → $script"
    return
  fi

  write_command_template "$name" "$script" "$desc" || return 1
  echo "✅ 已创建常用命令: $name → $script"
  open_command_editor "$script"
}

cmd_command_edit() {
  local target="${1:-}"
  local script

  if [ -z "$target" ]; then
    error "缺少常用命令名称"
    command_usage
    return 1
  fi

  script="$(resolve_command_script "$target")" || {
    error "未找到常用命令: $target"
    echo "可以先创建: dev c add $target"
    return 1
  }

  open_command_editor "$script"
}

cmd_command_delete() {
  local target="${1:-}"
  local script

  if [ -z "$target" ]; then
    error "缺少要删除的常用命令名称"
    command_usage
    return 1
  fi

  script="$(resolve_command_script "$target")" || {
    error "未找到常用命令: $target"
    return 1
  }

  rm -f "$script" || {
    error "删除失败: $script"
    return 1
  }

  echo "✅ 已删除常用命令: $target"
}

cmd_commands() {
  local action="${1:-list}"

  case "$action" in
    ""|list|ls)
      cmd_command_list
      ;;
    -h|--help|help)
      command_usage
      ;;
    show|cat)
      shift
      cmd_command_show "${1:-}"
      ;;
    run|x)
      shift
      cmd_command_run "$@"
      ;;
    add)
      shift
      cmd_command_add "$@"
      ;;
    edit|e)
      shift
      cmd_command_edit "${1:-}"
      ;;
    del|rm)
      shift
      cmd_command_delete "${1:-}"
      ;;
    *)
      if resolve_command_script "$action" >/dev/null 2>&1; then
        cmd_command_show "$action"
      else
        error "未知常用命令操作或名称: $action"
        echo ""
        command_usage
        return 1
      fi
      ;;
  esac
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

main() {
  case "${1:-}" in
    "")
      cmd_list
      ;;
    -h|--help)
      usage
      ;;
    version|--version|-v)
      show_version
      ;;
    shell-init)
      cmd_shell_init
      ;;
    add)
      shift
      cmd_add "$@"
      ;;
    del|rm)
      shift
      cmd_delete "${1:-}"
      ;;
    cmd|c)
      shift
      cmd_commands "$@"
      ;;
    open|o)
      shift
      cmd_open "$@"
      ;;
    run|x)
      shift
      cmd_run "${1:-}"
      ;;
    *)
      if [ -d "$(to_posix_path "$1")" ]; then
        cmd_path "$@"
      else
        error "未知命令或文件夹路径: $1"
        echo ""
        usage
        return 1
      fi
      ;;
  esac
}

main "$@"
