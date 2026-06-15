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
