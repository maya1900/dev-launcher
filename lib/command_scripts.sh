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
    write_command_header "$name" "$desc"
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
    write_command_header "$name" "$desc"
    printf '%s\n' "$command_line"
  } > "$script"

  chmod +x "$script"
}

write_command_header() {
  local name="$1"
  local desc="$2"

  printf '#!/usr/bin/env bash\n'
  printf '# desc: %s\n' "$desc"
  printf '# usage: dev c x %s [args...]\n\n' "$name"
  printf 'set -euo pipefail\n\n'
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

  echo "⚠️ 常用命令已存在: $name → $script"
  confirm_yes
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
