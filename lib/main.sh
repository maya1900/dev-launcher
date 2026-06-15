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
