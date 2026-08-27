#!/bin/bash
# 戒色打卡菜单栏组件 —— 一键安装
# 用法：bash install.sh

set -u
# 只在系统真有这个 locale 时才设，否则会退化成 C，导致 bash 3.2 把全角字符
# 误吃进变量名（表现为 "VAR?: unbound variable"）
if locale -a 2>/dev/null | grep -qi '^en_US.UTF-*8$'; then
  export LC_ALL=en_US.UTF-8
fi
HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN="discipline.5m.sh"
CFGDIR="$HOME/.config/gongchen-discipline"
CFG="$CFGDIR/config"

bold(){ printf "\033[1m%s\033[0m\n" "$1"; }
ok(){   printf "  \033[32m✓\033[0m %s\n" "$1"; }
warn(){ printf "  \033[33m!\033[0m %s\n" "$1"; }
die(){  printf "  \033[31m✗\033[0m %s\n" "$1"; exit 1; }

echo
bold "戒色打卡 · 菜单栏组件安装"
echo

# ── 1. 依赖 ──────────────────────────────────────────────
bold "1／4  检查依赖"
command -v curl >/dev/null || die "缺 curl（macOS 应该自带，系统异常）"
command -v jq   >/dev/null || die "缺 jq。装一下：brew install jq"
ok "curl、jq 都在"

# ── 2. SwiftBar ──────────────────────────────────────────
echo
bold "2／4  检查 SwiftBar"
if [ ! -d "/Applications/SwiftBar.app" ]; then
  warn "还没装 SwiftBar（菜单栏组件的宿主，免费开源）"
  echo
  echo "  装法二选一："
  echo "    brew install --cask swiftbar"
  echo "    或从 https://github.com/swiftbar/SwiftBar/releases 下载"
  echo
  read -r -p "  装好后按回车继续，或直接回车跳过检查： " _
fi
[ -d "/Applications/SwiftBar.app" ] && ok "SwiftBar 已安装" || warn "没检测到 SwiftBar，稍后自己装也行"

PLUGDIR="$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true)"
if [ -z "$PLUGDIR" ] || [ ! -d "$PLUGDIR" ]; then
  PLUGDIR="$HOME/SwiftBar"
  warn "没读到 SwiftBar 的插件目录，先用默认：$PLUGDIR"
  echo "  （首次打开 SwiftBar 时它会让你选一个文件夹，选这个即可）"
  mkdir -p "$PLUGDIR"
else
  ok "插件目录：$PLUGDIR"
fi

# ── 3. 配置 ──────────────────────────────────────────────
echo
bold "3／4  填同步信息"
echo

DEF_API=""
[ -f "$CFG" ] && DEF_API="$(. "$CFG"; echo "${API_BASE:-}")"

echo "  ① 你的生活规划系统网址（Cloudflare Pages 那个）"
echo "     例如 https://plan.gongchen.cc 或 https://xxx.pages.dev"
[ -n "$DEF_API" ] && echo "     直接回车沿用上次：$DEF_API"
read -r -p "     网址： " API_IN
[ -z "$API_IN" ] && API_IN="$DEF_API"
[ -z "$API_IN" ] && die "网址不能为空"
API_IN="${API_IN%/}"
case "$API_IN" in http://*|https://*) ;; *) API_IN="https://$API_IN" ;; esac

echo
echo "  ② 同步密钥"
echo "     在网页里：设置 → 云端同步，把那串密钥复制过来"
echo "     （输入时不显示，直接粘贴后回车。密钥只写进本机配置文件，不会外传）"
read -r -s -p "     密钥： " KEY_IN
echo
[ ${#KEY_IN} -lt 8 ] && die "密钥至少 8 位，看着不像对的"

mkdir -p "$CFGDIR"
umask 077
cat > "$CFG" <<EOF
# 生活规划系统 · 戒色打卡组件配置
# 本文件含密钥，权限已设为仅本人可读
API_BASE="$API_IN"
SYNC_KEY="$KEY_IN"
EOF
chmod 600 "$CFG"
ok "配置已写入 ${CFG} (权限 600)"

# ── 4. 装插件并自检 ───────────────────────────────────────
echo
bold "4／4  安装插件并连一次云端"
cp "$HERE/$PLUGIN" "$PLUGDIR/$PLUGIN"
chmod +x "$PLUGDIR/$PLUGIN"
ok "插件已放到 $PLUGDIR/$PLUGIN"

echo
echo "  连接测试："
if OUT="$("$PLUGDIR/$PLUGIN" test 2>&1)"; then
  echo "$OUT" | sed 's/^/    /'
  ok "云端连通"
else
  echo "$OUT" | sed 's/^/    /'
  echo
  die "连不上。核对：网址对不对、密钥有没有粘全、网页里同步是不是真开着"
fi

# ── 收尾 ─────────────────────────────────────────────────
echo
bold "装好了"
echo
echo "  打开 SwiftBar（或菜单栏点它 → Refresh All），菜单栏会出现 🛡 和天数。"
echo "  点开有「今日已坚持 ✓」和「破戒重置」，5 分钟自动刷新一次。"
echo
echo "  修改配置：open -e \"$CFG\""
echo "  手动自检：\"$PLUGDIR/$PLUGIN\" test"
echo
[ -d "/Applications/SwiftBar.app" ] && open -a SwiftBar 2>/dev/null || true
