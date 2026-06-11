# dev-launcher

`dev` 是一个跨平台的小工具，用来快速进入项目目录、在桌面文件管理器中打开文件夹，以及通过简单配置执行项目命令。

## 功能

- 目录和项目分开展示。
- 可以进入已配置目录，也可以直接进入任意文件夹路径。
- `-d` 参数会在 Finder、Explorer 或 Linux 文件管理器中打开文件夹。
- 用 `dev x <名称>` 执行项目命令。
- 用 `dev c` 管理常用命令脚本，支持查看、执行、添加、编辑和删除。
- 支持新增和删除配置，不用手工编辑 `dev.conf`。
- 名称重复或路径重复时会先询问是否覆盖。
- 支持 macOS、Windows Git Bash/MSYS/Cygwin、WSL 和 Linux。

## 文件

```text
dev.sh    Bash 主实现
dev.cmd   Windows cmd/PowerShell 入口，需要 PATH 里有 bash
dev.conf  本地配置文件
commands/ 常用命令脚本目录
```

## 安装

### macOS / Linux / WSL

把 `dev.sh` 放到一个稳定位置，赋予可执行权限，并把它暴露成 `dev`：

```bash
chmod +x dev.sh
ln -s "$(pwd)/dev.sh" "$HOME/.local/bin/dev"
```

如果你想让 `dev o <name>` 和 `dev <path>` 在当前终端里直接 `cd`，把下面这行加到 `~/.zshrc` 或 `~/.bashrc`：

```bash
eval "$("$HOME/.local/bin/dev" shell-init)"
```

改完后重新加载 shell：

```bash
source ~/.zshrc
```

### Windows

先安装 Git for Windows，保证 `bash` 在 `PATH` 里可用，然后把这个目录加到 `PATH`。在 cmd 或 PowerShell 里直接用 `dev.cmd`：

```powershell
dev version
dev --help
```

如果要在当前 shell 里切目录，建议使用 Git Bash，并加载 shell 集成：

```bash
eval "$(dev shell-init)"
```

`cmd.exe` 和 PowerShell 不能被外部进程直接修改当前目录，所以在那里执行 `dev o <name>` 时会打印目标路径。需要 `cd` 行为时，用 Git Bash。

`dev.cmd` 会把参数透传给 Bash。复杂的空格、引号或特殊字符参数在 `cmd.exe` / PowerShell 下可能被重新解析；这类场景建议直接使用 Git Bash。

## 配置

`dev.conf` 每行一条记录。新版本写入 `v2` 编码格式，每个字段用 base64 保存，路径和命令参数中可以包含 `|`：

```text
v2|base64(name)|base64(path)|base64(arg1)|base64(arg2)...
```

旧版 `name|path|command` 记录仍可读取，方便兼容已有配置：

```text
name|path|command
```

示例：

```text
# 短名称|项目路径|启动命令
claw|/Users/mayang/projects/OpenClaw-Admin|npm run dev:all
docs|/Users/mayang/projects/reference|open .
```

命令正好是 `open .` 的条目会显示为目录，其它条目会显示为项目。

注意：`dev x <名称>` 会在项目目录中执行 `dev.conf` 的命令字段。请把 `dev.conf` 当作受信任的可执行配置，不要从不可信来源导入，也不要把可被他人静默修改的同步文件直接作为配置文件。

你可以用下面这个环境变量覆盖配置文件位置：

```bash
DEV_CONFIG_FILE=/path/to/dev.conf dev
```

## 用法

显示已配置条目：

```bash
dev
```

显示帮助：

```bash
dev --help
```

显示版本号：

```bash
dev version
dev --version
dev -v
```

进入已配置目录或项目路径：

```bash
dev o docs
dev open docs
```

进入任意文件夹路径：

```bash
dev /tmp
dev ~/projects/reference
```

在桌面文件管理器中打开目录：

```bash
dev o docs -d
dev /tmp -d
```

执行项目命令：

```bash
dev x claw
dev run claw
```

`dev claw` 不再执行项目命令。项目执行统一用 `dev x claw`，语义更明确。

## 常用命令

常用命令保存在 `commands/*.sh`，每个脚本名就是调用名称。例如 `commands/kill-port.sh` 可以用 `kill-port` 调用。

列出常用命令：

```bash
dev c
dev cmd list
```

查看命令内容：

```bash
dev c show kill-port
dev c kill-port
```

执行命令：

```bash
dev c x kill-port 3000
dev cmd run kill-port 3000
```

添加一行命令：

```bash
dev c add ports -d "查看 3000 端口占用" -- lsof -i tcp:3000
```

添加一个可编辑脚本：

```bash
dev c add my-command
dev c add my-command -d "我的常用命令"
```

编辑和删除：

```bash
dev c edit my-command
dev c del my-command
```

你可以用下面这个环境变量覆盖常用命令目录：

```bash
DEV_COMMANDS_DIR=/path/to/commands dev c
```

## 新增条目

把当前目录作为目录条目加入，名称默认用当前文件夹名，命令默认是 `open .`：

```bash
dev add
```

给当前目录起一个自定义名字：

```bash
dev add docs
```

添加一个指定目录：

```bash
dev add ~/projects/reference
```

给当前目录指定自定义命令：

```bash
dev add -- npm run dev
```

添加一个带名称、路径和命令的项目：

```bash
dev add claw ~/projects/OpenClaw-Admin npm run dev:all
```

如果名称或路径已经存在，`dev add` 会先询问是否覆盖。

## 删除条目

从 `dev.conf` 中删除一条配置：

```bash
dev del docs
dev rm docs
```

这里只会删除配置，不会删除真实文件夹。

## 平台行为

打开目录时会按平台选择：

- macOS: `open`
- Windows Git Bash / MSYS / Cygwin: `explorer.exe`，然后 `cmd.exe`
- WSL: `explorer.exe`，然后 `wslview`，然后 `xdg-open`
- Linux / Unix: `xdg-open`

测试或自定义启动器时，可以覆盖打开命令：

```bash
DEV_OPEN_CMD=echo dev o docs -d
```

## 许可证

MIT。见 [LICENSE](./LICENSE)。
