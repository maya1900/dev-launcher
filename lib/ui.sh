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
