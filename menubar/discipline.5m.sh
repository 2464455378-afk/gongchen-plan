#!/bin/bash
# <bitbar.title>戒色打卡</bitbar.title>
# <bitbar.version>v1.0</bitbar.version>
# <bitbar.author>gongchen</bitbar.author>
# <bitbar.desc>与「生活规划系统」云端同步联动的戒色打卡菜单栏组件</bitbar.desc>
# <bitbar.dependencies>curl,jq</bitbar.dependencies>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:$PATH"
export LC_ALL=en_US.UTF-8

CFG="$HOME/.config/gongchen-discipline/config"
SELF="$0"

# ─────────────────────────── 未配置 ───────────────────────────
if [ ! -f "$CFG" ]; then
  echo "🛡 未配置"
  echo "---"
  echo "还没填同步信息 | color=orange"
  echo "请运行 menubar/install.sh 完成配置 | color=gray size=12"
  exit 0
fi

# shellcheck source=/dev/null
. "$CFG"

if [ -z "$API_BASE" ] || [ -z "$SYNC_KEY" ]; then
  echo "🛡 配置不全"
  echo "---"
  echo "config 里缺 API_BASE 或 SYNC_KEY | color=orange"
  echo "编辑配置文件 | bash=\"/usr/bin/open\" param1=\"-e\" param2=\"$CFG\" terminal=false"
  exit 0
fi

API="${API_BASE%/}/api/data?key=${SYNC_KEY}"

# ─────────────────────────── 工具函数 ───────────────────────────

fetch_blob() {
  curl -fsS --max-time 8 "$API" 2>/dev/null
}

# 与网页端 todayKey() 对齐：读云端 tz 设置，没有就用本机时区
compute_today() {
  local blob tz
  blob="$1"
  tz=$(printf '%s' "$blob" | jq -r '(.data // {} | .tz) // empty' 2>/dev/null | jq -r '. // empty' 2>/dev/null)
  if [ -n "$tz" ]; then
    TZ="$tz" date +%F
  else
    date +%F
  fi
}

# 与网页端一致：含首尾的天数差 +1（按 UTC 零点算，避开夏令时）
days_since() {
  local s t
  s=$(TZ=UTC date -j -f "%Y-%m-%d %H:%M:%S" "$1 00:00:00" +%s 2>/dev/null) || { echo 0; return; }
  t=$(TZ=UTC date -j -f "%Y-%m-%d %H:%M:%S" "$2 00:00:00" +%s 2>/dev/null) || { echo 0; return; }
  echo $(( (t - s) / 86400 + 1 ))
}

now_ms() { echo "$(date +%s)000"; }

get_abstain() {
  printf '%s' "$1" | jq -r '((.data // {} | .abstain) // "{}")' 2>/dev/null
}

# 整块读-改-写。PUT 会替换整个 blob，所以必须先取最新的再改，避免抹掉其它模块的数据。
push_abstain() {
  local blob newab ts newblob
  blob="$1"; newab="$2"
  ts=$(now_ms)
  newblob=$(printf '%s' "$blob" | jq -c --arg a "$newab" --argjson ts "$ts" \
    '.data = ((.data // {}) | .abstain = $a) | .ts = $ts' 2>/dev/null) || return 1
  curl -fsS --max-time 8 -X PUT \
    -H 'content-type: application/json' \
    --data-binary "$newblob" "$API" >/dev/null 2>&1
}

notify() {
  /usr/bin/osascript -e "display notification \"$2\" with title \"$1\"" >/dev/null 2>&1
}

# ─────────────────────────── 动作 ───────────────────────────

case "$1" in
  checkin)
    blob=$(fetch_blob) || { notify "打卡失败" "连不上云端，检查网络"; exit 1; }
    ab=$(get_abstain "$blob")
    today=$(compute_today "$blob")
    start=$(printf '%s' "$ab" | jq -r '.start // empty')
    [ -z "$start" ] && start="$today"
    days=$(days_since "$start" "$today")
    best=$(printf '%s' "$ab" | jq -r '.best // 0')
    [ "$days" -gt "$best" ] && best="$days"
    newab=$(printf '%s' "$ab" | jq -c --arg t "$today" --arg s "$start" --argjson b "$best" \
      '.start=$s | .lastCheck=$t | .best=$b | .checkedDates=(((.checkedDates // []) + [$t]) | unique)')
    if push_abstain "$blob" "$newab"; then
      notify "已打卡 ✓" "连续坚持 ${days} 天"
    else
      notify "打卡失败" "写入云端出错，稍后重试"
    fi
    exit 0
    ;;

  reset)
    ans=$(/usr/bin/osascript -e 'display dialog "确定重置？当前连续天数会清零，最长记录会保留。" with title "破戒重置" buttons {"取消","确定重置"} default button "取消" with icon caution' 2>/dev/null)
    case "$ans" in *"确定重置"*) ;; *) exit 0 ;; esac
    blob=$(fetch_blob) || { notify "重置失败" "连不上云端"; exit 1; }
    ab=$(get_abstain "$blob")
    today=$(compute_today "$blob")
    start=$(printf '%s' "$ab" | jq -r '.start // empty')
    if [ -n "$start" ]; then days=$(days_since "$start" "$today"); else days=0; fi
    best=$(printf '%s' "$ab" | jq -r '.best // 0')
    [ "$days" -gt "$best" ] && best="$days"
    newab=$(printf '%s' "$ab" | jq -c --arg t "$today" --argjson b "$best" \
      '.start=$t | .lastCheck=null | .best=$b | .checkedDates=(.checkedDates // [])')
    if push_abstain "$blob" "$newab"; then
      notify "已重置" "从今天重新开始 · 最长记录 ${best} 天"
    else
      notify "重置失败" "写入云端出错"
    fi
    exit 0
    ;;

  test)
    echo "API : $API_BASE"
    echo -n "连接: "
    if b=$(fetch_blob); then
      echo "OK"
      echo "今天: $(compute_today "$b")"
      echo "戒色: $(get_abstain "$b")"
    else
      echo "失败 —— 检查 API_BASE 和 SYNC_KEY 是否正确"
      exit 1
    fi
    exit 0
    ;;
esac

# ─────────────────────────── 渲染菜单栏 ───────────────────────────

blob=$(fetch_blob)
if [ -z "$blob" ]; then
  echo "🛡 —"
  echo "---"
  echo "连不上云端 | color=orange"
  echo "刷新 | refresh=true"
  echo "打开生活规划系统 | href=$API_BASE"
  exit 0
fi

ab=$(get_abstain "$blob")
today=$(compute_today "$blob")
start=$(printf '%s' "$ab" | jq -r '.start // empty')
last=$(printf '%s' "$ab" | jq -r '.lastCheck // empty')
best=$(printf '%s' "$ab" | jq -r '.best // 0')

if [ -n "$start" ]; then days=$(days_since "$start" "$today"); else days=0; fi
[ "$best" -lt "$days" ] && best="$days"

if [ "$last" = "$today" ]; then
  echo "🛡 ${days}"
  checked=1
else
  echo "🛡 ${days} ・ | color=orange"
  checked=0
fi

echo "---"
echo "连续坚持 ${days} 天 | size=14"
echo "最长记录 ${best} 天 | color=gray size=12"
echo "---"

if [ "$checked" = "1" ]; then
  echo "今日已坚持 ✓ | color=green"
else
  echo "今日已坚持 ✓ | bash=\"$SELF\" param1=checkin terminal=false refresh=true"
fi
echo "破戒重置 | bash=\"$SELF\" param1=reset terminal=false refresh=true"

echo "---"
echo "打开生活规划系统 | href=$API_BASE"
echo "立即刷新 | refresh=true"
