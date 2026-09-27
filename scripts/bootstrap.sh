#!/usr/bin/env bash
# bootstrap.sh — 让一个全新的 Claude 云端容器能控制你 tailnet 里的一台 Mac(默认机器名 m5pro)。幂等,可反复跑。
#
#   1. 装 ssh / nc / rsync(缺才装)
#   2. 下载 tailscale 静态二进制,userspace 模式起 tailscaled(容器里没有真 TUN 路由,
#      出站只允许走 HTTPS 代理,所以用 SOCKS5 localhost:1055 进 tailnet)
#   3. 用 $TS_AUTHKEY 入网;没有就打印登录链接让人点
#   4. 用 $M5_SSH_KEY_B64 还原 SSH 私钥;没有就现生成一把并打印公钥
#   5. 写 ~/.ssh/config(m5 别名 + SOCKS ProxyCommand + ControlMaster)
#   6. 把 bin/ 里的命令装进 PATH
#   7. 连一下目标机,打印一行状态
#
# 环境变量(在云端环境设置里配,不进仓库):
#   TS_AUTHKEY      Tailscale auth key(建议 Reusable + Ephemeral);不设则打印登录链接
#   M5_SSH_KEY_B64  登录目标机的 SSH 私钥,base64 单行;不设则现生成一把并打印公钥
#   M5_HOST         目标机的 tailnet 机器名或 IP,默认 m5pro
#   M5_USER         目标机登录用户,默认 m5pro
#   M5_HOSTKEY      可选,目标机 SSH 主机公钥(如 "ssh-ed25519 AAAA…");设了就严格校验,否则首连信任
#
# 由 .claude/settings.json 的 SessionStart hook 自动调用;手动跑:bash scripts/bootstrap.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
M5_HOST="${M5_HOST:-m5pro}"
M5_USER="${M5_USER:-m5pro}"
TS_SOCK=/var/run/tailscale/tailscaled.sock
TS_LOG=/tmp/tailscaled.log
TS_HOSTNAME="${TS_HOSTNAME:-claude-cloud}"
say() { printf '[m5ctl] %s\n' "$*"; }

# 只在 Linux 云端容器里干活;在 Mac 本地打开这个仓库时什么都不做
if [ "$(uname -s)" != "Linux" ]; then exit 0; fi

# ---------- 1. 基础依赖 ----------
need_pkgs=()
command -v ssh   >/dev/null || need_pkgs+=(openssh-client)
command -v rsync >/dev/null || need_pkgs+=(rsync)
nc -h 2>&1 | grep -q OpenBSD || need_pkgs+=(netcat-openbsd)
if [ ${#need_pkgs[@]} -gt 0 ]; then
  say "安装 ${need_pkgs[*]}"
  (apt-get install -y -qq "${need_pkgs[@]}" >/dev/null 2>&1 \
    || { apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq "${need_pkgs[@]}" >/dev/null 2>&1; }) \
    || say "警告:apt 安装 ${need_pkgs[*]} 失败"
fi

# ---------- 2. tailscale ----------
if ! command -v tailscaled >/dev/null; then
  say "下载 tailscale"
  tmp=$(mktemp -d)
  V=$(curl -fsS "https://pkgs.tailscale.com/stable/?mode=json" | python3 -c 'import sys,json;print(json.load(sys.stdin)["TarballsVersion"])')
  curl -fsSL "https://pkgs.tailscale.com/stable/tailscale_${V}_amd64.tgz" | tar xz -C "$tmp" \
    && install -m755 "$tmp/tailscale_${V}_amd64/tailscale" "$tmp/tailscale_${V}_amd64/tailscaled" /usr/local/bin/
  rm -rf "$tmp"
  command -v tailscaled >/dev/null || { say "错误:tailscale 下载失败(检查环境网络策略是否放行 pkgs.tailscale.com)"; exit 0; }
fi

if ! pgrep -x tailscaled >/dev/null; then
  mkdir -p /var/lib/tailscale "$(dirname "$TS_SOCK")"
  # state 落盘:容器会"重启但保留磁盘"(uptime 归零、tailscaled 进程没了),落盘的节点身份可直接复用免重新认证;
  # 配合 ephemeral auth key,容器彻底回收后节点仍会自动从 tailnet 消失
  nohup tailscaled --tun=userspace-networking \
    --socks5-server=localhost:1055 --outbound-http-proxy-listen=localhost:1056 \
    --state=/var/lib/tailscale/tailscaled.state --socket="$TS_SOCK" >"$TS_LOG" 2>&1 &
  rm -f ~/.ssh/cm/* 2>/dev/null   # 上一次进程留下的 ControlMaster 套接字已失效
  for _ in $(seq 20); do [ -S "$TS_SOCK" ] && break; sleep 0.5; done
fi

ts_state() { tailscale status --json 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin).get("BackendState",""))' 2>/dev/null; }
for _ in $(seq 20); do [ "$(ts_state)" = "Running" ] && break; [ "$(ts_state)" = "NeedsLogin" ] && break; sleep 0.5; done

if [ "$(ts_state)" != "Running" ]; then
  if [ -n "${TS_AUTHKEY:-}" ]; then
    tailscale up --authkey="$TS_AUTHKEY" --hostname="$TS_HOSTNAME" --accept-routes=false --timeout=60s >/tmp/tsup.log 2>&1 \
      || say "错误:tailscale up 失败:$(tail -2 /tmp/tsup.log | tr '\n' ' ')"
  else
    # 已有一个 tailscale up 在等批准就复用它的链接;再起一个会换新链接,之前发给用户的那个就作废了
    pgrep -f '^tailscale up' >/dev/null \
      || nohup tailscale up --hostname="$TS_HOSTNAME" --accept-routes=false >/tmp/tsup.log 2>&1 &
    for _ in $(seq 20); do grep -q 'https://login.tailscale.com' /tmp/tsup.log 2>/dev/null && break; sleep 0.5; done
    url=$(grep -o 'https://login.tailscale.com[^ ]*' /tmp/tsup.log | head -1)
    say "没有 TS_AUTHKEY。请把这个链接发给用户,让其用 Tailscale 账号批准本容器入网:${url:-<见 /tmp/tsup.log>}"
  fi
fi

# ---------- 4. SSH 私钥 ----------
mkdir -p ~/.ssh/cm && chmod 700 ~/.ssh
if [ -n "${M5_SSH_KEY_B64:-}" ]; then
  printf '%s' "$M5_SSH_KEY_B64" | base64 -d > ~/.ssh/id_ed25519 2>/dev/null
  chmod 600 ~/.ssh/id_ed25519
  ssh-keygen -y -f ~/.ssh/id_ed25519 > ~/.ssh/id_ed25519.pub 2>/dev/null \
    || { say "错误:M5_SSH_KEY_B64 解不出有效私钥"; rm -f ~/.ssh/id_ed25519 ~/.ssh/id_ed25519.pub; }
fi
if [ ! -f ~/.ssh/id_ed25519 ]; then
  ssh-keygen -t ed25519 -N "" -C "claude-cloud-container" -f ~/.ssh/id_ed25519 -q
  say "没有 M5_SSH_KEY_B64,已临时生成密钥。请让用户在 $M5_HOST 上执行(仅对本容器有效):"
  say "  echo '$(cat ~/.ssh/id_ed25519.pub)' >> ~/.ssh/authorized_keys"
fi

# ---------- 5. ssh config ----------
if [ -n "${M5_HOSTKEY:-}" ]; then
  printf '%s %s\n' "$M5_HOST" "$M5_HOSTKEY" > ~/.ssh/known_hosts_m5; HKC=yes
else
  touch ~/.ssh/known_hosts_m5; HKC=accept-new
fi
{
  echo "Host m5 $M5_HOST"
  echo "  HostName $M5_HOST"
  echo "  HostKeyAlias $M5_HOST"
  echo "  User $M5_USER"
  echo "  ProxyCommand nc -X 5 -x localhost:1055 %h %p"
  echo "  UserKnownHostsFile ~/.ssh/known_hosts_m5"
  echo "  StrictHostKeyChecking $HKC"
  echo "  ServerAliveInterval 30"
  echo "  ControlMaster auto"
  echo "  ControlPath ~/.ssh/cm/%r@%h:%p"
  echo "  ControlPersist 600"
} > ~/.ssh/config
chmod 600 ~/.ssh/config

# ---------- 6. CLI 进 PATH ----------
chmod +x "$REPO"/bin/*
for f in m5 ohand osess dt; do ln -sf "$REPO/bin/$f" "/usr/local/bin/$f"; done
for f in m5grep m5find m5cat m5ls m5tree m5write m5sed m5pull m5push m5du; do
  ln -sf "$REPO/bin/m5" "/usr/local/bin/$f"
done

# ---------- 7. 自检 ----------
# tailscaled 刚起时到对端的中继路径还没通,首连常失败,所以重试几次
if [ "$(ts_state)" = "Running" ]; then
  ok=0
  for _ in 1 2 3 4; do
    if out=$(timeout 40 ssh -o BatchMode=yes -o ConnectTimeout=30 -o LogLevel=ERROR m5 'echo "$(whoami)@$(scutil --get ComputerName 2>/dev/null || hostname)"' 2>&1); then
      ok=1; break
    fi
    rm -f ~/.ssh/cm/* 2>/dev/null; sleep 5
  done
  if [ $ok = 1 ]; then
    say "就绪:已连上 $M5_HOST ($out)。用法见 CLAUDE.md;机器相关的私有说明先读:m5cat .config/m5ctl/PRIVATE.md"
  else
    say "tailnet 已连,但 SSH 到 $M5_HOST 失败:$(printf '%s' "$out" | tail -1)"
    # 重跑时密钥早已生成,第 4 步不会再打印公钥,这里补上
    if printf '%s' "$out" | grep -q 'Permission denied'; then
      if [ -n "${M5_SSH_KEY_B64:-}" ]; then
        say "M5_SSH_KEY_B64 对应的公钥不在 $M5_HOST 的 ~/.ssh/authorized_keys 里(或 from= 来源限制不匹配)"
      else
        say "本容器的公钥还没加到 $M5_HOST。请让用户在 $M5_HOST 上执行(仅对本容器有效):"
        say "  echo '$(cat ~/.ssh/id_ed25519.pub)' >> ~/.ssh/authorized_keys"
      fi
    fi
  fi
else
  say "tailnet 未连通(state=$(ts_state)),m5 命令暂不可用。连通后重跑:bash $REPO/scripts/bootstrap.sh"
fi
exit 0
