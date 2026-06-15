is_folder_entry() {
  [ "$1" = "open ." ]
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

confirm_yes() {
  local answer

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

  echo "⚠️ 已存在相同名称或目录:"
  echo "   当前: $old_name → $old_path ($old_cmd)"
  echo "   新的: $new_name → $new_path ($new_cmd)"
  confirm_yes
}

is_config_passthrough_line() {
  local line="$1"
  [[ "$line" =~ ^[[:space:]]*# || -z "$line" ]]
}

config_entry_path_key() {
  canonical_dir "$ENTRY_PATH" 2>/dev/null || to_posix_path "$ENTRY_PATH"
}

create_config_tmp_file() {
  _CLEANUP_TMP_FILE=""

  _CLEANUP_TMP_FILE="$(mktemp "${CONFIG_FILE}.XXXXXX")" || {
    error "创建临时文件失败"
    return 1
  }
}

commit_config_tmp_file() {
  local tmp_file="$1"

  mv "$tmp_file" "$CONFIG_FILE" || {
    error "更新配置文件失败: $CONFIG_FILE"
    rm -f "$tmp_file"
    _CLEANUP_TMP_FILE=""
    return 1
  }

  _CLEANUP_TMP_FILE=""
}

discard_config_tmp_file() {
  local tmp_file="$1"

  rm -f "$tmp_file"
  _CLEANUP_TMP_FILE=""
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

  create_config_tmp_file || return 1
  tmp_file="$_CLEANUP_TMP_FILE"

  while IFS= read -r line || [ -n "$line" ]; do
    if is_config_passthrough_line "$line"; then
      printf '%s\n' "$line" >> "$tmp_file"
      continue
    fi

    parse_config_line "$line" || {
      printf '%s\n' "$line" >> "$tmp_file"
      continue
    }
    existing_path="$(config_entry_path_key)"
    if [ "$ENTRY_NAME" = "$entry_name" ] || [ "$existing_path" = "$entry_path" ]; then
      if [ "$written" -eq 0 ]; then
        printf '%s\n' "$new_line" >> "$tmp_file"
        written=1
      fi
      continue
    fi

    printf '%s\n' "$line" >> "$tmp_file"
  done < "$CONFIG_FILE"

  [ "$written" -eq 0 ] && printf '%s\n' "$new_line" >> "$tmp_file"
  commit_config_tmp_file "$tmp_file"
}

delete_entry() {
  local target="$1"
  local tmp_file line removed=0

  [ -f "$CONFIG_FILE" ] || {
    error "配置文件不存在: $CONFIG_FILE"
    return 1
  }

  create_config_tmp_file || return 1
  tmp_file="$_CLEANUP_TMP_FILE"

  while IFS= read -r line || [ -n "$line" ]; do
    if is_config_passthrough_line "$line"; then
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
    commit_config_tmp_file "$tmp_file" || return 1
    return 0
  fi

  discard_config_tmp_file "$tmp_file"
  return 1
}
