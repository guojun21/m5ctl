# m5ctl — 你在这里的工作是远程操控用户的 Mac

这个仓库本身几乎没有要改的代码。用户用它开 Claude 云端 session,目的是让你**从云端容器控制他的 Mac(默认机器名 m5pro)干活**。
默认用中文回答。

## 开工第一步

1. SessionStart hook 已自动跑过 `scripts/bootstrap.sh`。输出里有 `[m5ctl] 就绪 …` 就说明能用。
   不通就重跑 `bash scripts/bootstrap.sh`,按它打印的 `[m5ctl]` 提示办;要登录链接或公钥,原样交给用户。
2. **读目标机上的私有说明:`m5cat .config/m5ctl/PRIVATE.md`**。机器地址、其他机器的账号、云 GPU 实例、登录态怎么恢复、
   手头项目的目录和铁律都在那里——这些是用户的私人环境信息,**不要写回本仓库**(本仓库是公开的)。

## 链路

```
云端容器 (Linux, 临时) ──Tailscale userspace, SOCKS5 localhost:1055──▶ 目标 Mac($M5_HOST,默认 m5pro)
                                                       ssh 别名 `m5`,ControlMaster 复用连接
```

## 命令(全部在 PATH 里)

| 命令 | 作用 |
|---|---|
| `m5 <命令…>` | 在目标机上执行任意命令,只回传输出。单个带管道/重定向的字符串原样交给远端 shell:`m5 'ps aux \| grep node'` |
| `m5 -` | 交互 shell(Claude 一般不用) |
| `m5ls [路径]` / `m5tree [路径] [深度]` / `m5cat <文件…>` | 看目录 / 树 / 读文件 |
| `m5grep <模式> [路径…]` / `m5find <模式> [路径…]` | 远端 rg / fd(默认搜整个家目录,尽量给路径) |
| `cmd \| m5write <文件>` / `m5sed <sed脚本> <文件…>` | 写文件 / 原地改 |
| `m5pull <远端> <本地>` / `m5push <本地> <远端>` | rsync 传文件 |
| `m5du [路径]` | 磁盘占用 |
| `ohand <命令>` / `ohand status` | 经 orangeHand.app 在目标机的 **GUI 会话**里执行(见下) |
| `osess stats / ls / grep / brief / show / path / summary` | 查目标机上的 Claude/Codex/Cursor session;`osess summary <id>` 取交接摘要(接手别的 session 从这开始) |
| `dt <实例> '<命令>' [profile]` | 在阿里云 DSW 实例终端里跑命令(后端是目标机上的 `dswrun`,实例列表见 PRIVATE.md) |

### 路径规则(重要)
- 写**相对路径**(相对目标机家目录)或绝对路径:`m5ls Downloads`、`m5cat Library/LaunchAgents/x.plist`。
- **不要写不带引号的 `~/xxx`**:`~` 会先被容器里的 shell 展开成 `/root/xxx`。要用就加引号 `m5ls '~/xxx'`。
- 在 `m5 '…'` 的单引号字符串里 `~`、`$HOME` 由远端展开,没问题。

### m5 还是 ohand?
- SSH 会话**够不到 login Keychain 和 TCC 授权**。凡是要钥匙串 / 登录态的(`gh`、浏览器 cookie、`security find-generic-password`)、
  要屏幕录制/辅助功能/自动化的(`screencapture`、`osascript` 控 GUI),走 `ohand`。
  例:`m5 'gh auth status'` 会报 token 无效,`ohand 'gh auth status'` 正常。
- 其余普通读写/编译/跑脚本用 `m5`,更快。
- 长任务用 `ohand --timeout 600 '…'`,或 `m5 'nohup … > /tmp/x.log 2>&1 &'` 后台跑再轮询。

### 云 GPU 机(dt)通用规矩
- 长任务写成机上脚本 `(setsid nohup bash x.sh > log 2>&1 < /dev/null &)` 起,`dt` 只负责起和看日志。
- 借卡前后按机器上的协议暂停/恢复占卡程序,并登记使用者(具体见 PRIVATE.md)。

## 注意
- 延迟:走 Tailscale DERP 中继,单次往返约 0.3s。批量操作尽量合成一条 `m5 '…'`,别循环调几十次。
- 容器会"重启但保留磁盘":tailscaled 进程没了、SSH 报 `Connection closed by UNKNOWN port 65535` 时,重跑 bootstrap 即可(节点身份在盘上)。
- 目标机离线(`tailscale status` 里 offline)多半是 Mac 睡眠/合盖,告诉用户,别空等。
- macOS 没有 GNU `timeout`,远端别用;需要超时就在容器侧包 `timeout N m5 …`。`sed -i` 要写 `sed -i ''`(`m5sed` 已处理)。
- 这是用户的主力机:删除、覆盖、kill 进程、改系统设置、推代码、发消息等不可逆或对外的操作,先跟用户确认。
- 不要把 session transcript、执行日志、钥匙串内容、token 原样打印到对话里;需要时只取回答问题所需的最小信息。
- **本仓库公开**:改脚本后 commit + push 前,确认没有写进 IP、用户名以外的账号、实例 ID、路径里的私人项目名等;这类信息放 PRIVATE.md。
