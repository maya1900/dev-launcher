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

LIB_DIR="$SCRIPT_DIR/lib"

for lib_name in ui runtime config command_scripts projects main; do
  lib_file="$LIB_DIR/$lib_name.sh"
  if [ ! -f "$lib_file" ]; then
    printf '❌ 缺少库文件: %s\n' "$lib_file" >&2
    exit 1
  fi

  source "$lib_file" || exit 1
done

trap cleanup EXIT
trap cleanup_and_exit INT TERM

main "$@"
