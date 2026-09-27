# m5ctl

用这个仓库开 Claude Code 云端 session(claude.ai/code),Claude 就能通过 Tailscale + SSH 直接操控你 tailnet 里的一台 Mac。

```
Claude 云端容器 ──Tailscale(userspace, SOCKS5)──▶ 你的 Mac ──▶ (再跳) tailnet 里的其他机器
     m5 / m5ls / m5grep / ohand / osess / dt …
```

云端容器出站只允许走 HTTPS 代理、没有可用的 TUN 路由,所以 tailscaled 跑在 userspace 模式,SSH 经它的 SOCKS5 代理进 tailnet;
SSH 开 ControlMaster 复用连接,抵消中继延迟。

## 内容

| 路径 | 说明 |
|---|---|
| `bin/m5` | 主命令;`m5grep m5find m5cat m5ls m5tree m5write m5sed m5pull m5push m5du` 都是它的 symlink,按命令名分发 |
| `bin/ohand` | 把命令交给 Mac 上的 orangeHand.app(常驻 GUI 会话的执行代理),能用钥匙串 / TCC 权限 |
| `bin/osess` | 查询 Mac 上的 AI session(后端是 Mac 上的 `~/.local/bin/_osess.py`) |
| `bin/dt` | 在阿里云 DSW 实例上跑命令(后端是 Mac 上的 `~/.local/bin/dswrun`) |
| `scripts/bootstrap.sh` | 幂等初始化:装 tailscale、入网、还原密钥、写 ssh config、装 CLI、自检 |
| `.claude/settings.json` | SessionStart hook,session 一启动自动跑 bootstrap |
| `CLAUDE.md` | 给 Claude 的操作手册 |

`ohand` / `osess` / `dt` 依赖 Mac 上的配套程序,没有的话只用 `m5` 系列即可。

## 一次性配置

在 claude.ai 云端环境设置里(session 标题栏的云环境菜单 → Edit):

**网络策略**:要能访问 `pkgs.tailscale.com`、`controlplane.tailscale.com`、`*.tailscale.com`(DERP 中继)。

**环境变量**(机密只放这里,不要提交进仓库,也不要贴到聊天里):

| 变量 | 必需 | 说明 |
|---|---|---|
| `TS_AUTHKEY` | 建议 | Tailscale admin → Settings → Keys 生成,勾 **Reusable** + **Ephemeral**。不设则每次 session 打印登录链接让你点 |
| `M5_SSH_KEY_B64` | 建议 | 登录 Mac 的 SSH 私钥(base64 单行),生成方法见下。不设则每次现生成一把,要你手动加公钥 |
| `M5_HOST` | 否 | Mac 的 tailnet 机器名或 IP,默认 `m5pro` |
| `M5_USER` | 否 | Mac 上的登录用户,默认 `m5pro` |
| `M5_HOSTKEY` | 否 | Mac 的 SSH 主机公钥(`cut -d' ' -f1,2 /etc/ssh/ssh_host_ed25519_key.pub`),设了就严格校验防中间人 |

生成 `M5_SSH_KEY_B64`(在 Mac 上):
```bash
ssh-keygen -t ed25519 -N "" -C claude-cloud -f ~/.ssh/claude_cloud
echo "from=\"100.64.0.0/10\" $(cat ~/.ssh/claude_cloud.pub)" >> ~/.ssh/authorized_keys   # 只允许 tailnet 来源
base64 < ~/.ssh/claude_cloud | tr -d '\n' | pbcopy                                       # 粘进环境变量
```

Mac 侧前提:系统设置里打开「远程登录」;装了 Tailscale 并登录同一个 tailnet;`rg`、`fd` 在 `/opt/homebrew/bin` 或 `~/.local/bin`。
想让 Claude 一直能连,别让 Mac 用电池时合盖(会睡眠掉线)。

### 私有说明
机器相关、不宜公开的信息(其他机器账号、云实例、项目目录、恢复步骤)写在 Mac 上的 `~/.config/m5ctl/PRIVATE.md`,
CLAUDE.md 会让 Claude 开工先读它。

## 手动用法

```bash
bash scripts/bootstrap.sh        # 重新初始化 / 查看状态
m5 whoami
m5ls Downloads                   # 相对路径 = Mac 家目录下
m5grep -l TODO Projects/foo
m5 'ps aux | grep -i node | head'
ohand status                     # orangeHand 权限自检
ohand 'gh repo list --limit 5'   # 需要钥匙串的命令
m5pull Downloads/foo.zip /tmp/   # 拉文件回容器
```
