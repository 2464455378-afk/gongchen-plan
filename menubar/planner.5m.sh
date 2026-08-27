#!/bin/bash
# <bitbar.title>生活规划</bitbar.title>
# <bitbar.version>v1.0</bitbar.version>
# <bitbar.author>gongchen</bitbar.author>
# <bitbar.desc>戒色打卡 + 今日花销，与「生活规划系统」云端同步联动</bitbar.desc>
# <bitbar.dependencies>curl,jq</bitbar.dependencies>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:$PATH"

CFG="$HOME/.config/gongchen-discipline/config"
SELF="$0"
CATS=(餐饮 交通 购物 居住 娱乐 医疗 学习 人情 订阅 其他)

if [ ! -f "$CFG" ]; then
  echo "📋 未配置"; echo "---"; echo "先运行 menubar/install.sh | color=orange"; exit 0
fi
. "$CFG"
if [ -z "${API_BASE:-}" ] || [ -z "${SYNC_KEY:-}" ]; then
  echo "📋 配置不全"; echo "---"; echo "config 缺 API_BASE 或 SYNC_KEY | color=orange"; exit 0
fi
API="${API_BASE%/}/api/data?key=${SYNC_KEY}"

# 调试：记录每一次被调用（含参数），用于排查 SwiftBar 点击是否真的触发脚本
printf '%s  调用: [%s]\n' "$(date '+%H:%M:%S')" "$*" >>"$HOME/.config/gongchen-discipline/dialog.log" 2>/dev/null

# ─────────────────────── 工具 ───────────────────────

fetch_blob(){ curl -fsS --max-time 8 "$API" 2>/dev/null; }

compute_today(){
  local tz
  tz=$(printf '%s' "$1" | jq -r '(.data // {} | .tz) // empty' 2>/dev/null | jq -r '. // empty' 2>/dev/null)
  if [ -n "$tz" ]; then TZ="$tz" date +%F; else date +%F; fi
}
getkey(){ printf '%s' "$1" | jq -r --arg k "$2" --arg d "$3" '((.data // {} | .[$k]) // $d)' 2>/dev/null; }
days_since(){
  local s t
  s=$(TZ=UTC date -j -f "%Y-%m-%d %H:%M:%S" "$1 00:00:00" +%s 2>/dev/null) || { echo 0; return; }
  t=$(TZ=UTC date -j -f "%Y-%m-%d %H:%M:%S" "$2 00:00:00" +%s 2>/dev/null) || { echo 0; return; }
  echo $(( (t - s) / 86400 + 1 ))
}
money(){
  local s; case "$2" in USD) s='$';; *) s='¥';; esac
  printf '%s%s' "$s" "$(printf '%.2f' "${1:-0}" | awk '{n=$0;neg=(n<0);if(neg)n=-n;
    split(sprintf("%.2f",n),a,".");i=a[1];out="";
    while(length(i)>3){out=","substr(i,length(i)-2)out;i=substr(i,1,length(i)-3)}
    printf "%s%s%s.%s",(neg?"-":""),i,out,a[2]}')"
}
b36(){ local n=$1 s="" d c="0123456789abcdefghijklmnopqrstuvwxyz"
  while [ "$n" -gt 0 ]; do d=$((n%36)); s="${c:$d:1}$s"; n=$((n/36)); done; printf '%s' "$s"; }
newid(){ printf '%s%s' "$(b36 "$(date +%s)000")" "$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 4)"; }
now_ms(){ printf '%s000' "$(date +%s)"; }

notify(){ /usr/bin/osascript -e "display notification \"$2\" with title \"$1\"" >/dev/null 2>&1; }

LOG="$HOME/.config/gongchen-discipline/dialog.log"
log(){ printf '%s  %s\n' "$(date '+%H:%M:%S')" "$*" >>"$LOG"; }

# 注意：AppleScript 字符串只认 \" \\ \n \t \r，出现 \$ 之类会整段编译失败(-2741)，
# 所以传进来的文案里绝不能带反斜杠转义。
ask(){ # $1=正文 $2=标题 $3=确认按钮
  local out
  out=$(/usr/bin/osascript 2>>"$LOG" <<OSA
tell me to activate
set r to display dialog "$1" with title "$2" default answer "" buttons {"取消","$3"} default button "$3"
if button returned of r is "$3" then
  return text returned of r
else
  error number -128
end if
OSA
) || { log "ask: 取消或失败"; return 1; }
  printf '%s' "$out"
}
confirm(){ # $1=正文 $2=标题 $3=确认按钮
  local out
  out=$(/usr/bin/osascript 2>>"$LOG" <<OSA
tell me to activate
set r to display dialog "$1" with title "$2" buttons {"取消","$3"} default button "取消" with icon caution
return button returned of r
OSA
)
  [ "$out" = "$3" ]
}

# 整块读-改-写：PUT 会替换整个 blob，必须先取最新的再改，避免抹掉其它模块
push_keys(){ # $1=blob  之后每两个参数为 键名 值(JSON字符串)
  local blob="$1"; shift
  local filter='.data = ((.data // {})' args=() i=0
  while [ $# -ge 2 ]; do
    filter="$filter | .[\"$1\"] = \$v$i"
    args+=(--arg "v$i" "$2"); i=$((i+1)); shift 2
  done
  filter="$filter) | .ts = \$ts"
  local nb
  nb=$(printf '%s' "$blob" | jq -c "${args[@]}" --argjson ts "$(now_ms)" "$filter") || return 1
  curl -fsS --max-time 8 -X PUT -H 'content-type: application/json' \
    --data-binary "$nb" "$API" >/dev/null 2>&1
}

# ─────────────────────── 动作 ───────────────────────

case "${1:-}" in
  checkin)
    blob=$(fetch_blob) || { notify "打卡失败" "连不上云端"; exit 1; }
    ab=$(getkey "$blob" abstain '{}'); today=$(compute_today "$blob")
    start=$(printf '%s' "$ab" | jq -r '.start // empty'); [ -z "$start" ] && start="$today"
    days=$(days_since "$start" "$today"); best=$(printf '%s' "$ab" | jq -r '.best // 0')
    [ "$days" -gt "$best" ] && best="$days"
    newab=$(printf '%s' "$ab" | jq -c --arg t "$today" --arg s "$start" --argjson b "$best" \
      '.start=$s|.lastCheck=$t|.best=$b|.checkedDates=(((.checkedDates // [])+[$t])|unique)')
    if push_keys "$blob" abstain "$newab"; then notify "已打卡 ✓" "连续坚持 ${days} 天"
    else notify "打卡失败" "写入云端出错"; fi
    exit 0 ;;

  reset)
    confirm "确定重置？当前连续天数会清零，最长记录会保留。" "破戒重置" "确定重置" || exit 0
    blob=$(fetch_blob) || { notify "重置失败" "连不上云端"; exit 1; }
    ab=$(getkey "$blob" abstain '{}'); today=$(compute_today "$blob")
    start=$(printf '%s' "$ab" | jq -r '.start // empty')
    if [ -n "$start" ]; then days=$(days_since "$start" "$today"); else days=0; fi
    best=$(printf '%s' "$ab" | jq -r '.best // 0'); [ "$days" -gt "$best" ] && best="$days"
    newab=$(printf '%s' "$ab" | jq -c --arg t "$today" --argjson b "$best" \
      '.start=$t|.lastCheck=null|.best=$b|.checkedDates=(.checkedDates // [])')
    if push_keys "$blob" abstain "$newab"; then notify "已重置" "从今天重新开始 · 最长记录 ${best} 天"
    else notify "重置失败" "写入云端出错"; fi
    exit 0 ;;

  add)
    CAT="${2:-其他}"
    blob=$(fetch_blob) || { notify "记账失败" "连不上云端"; exit 1; }
    today=$(compute_today "$blob")
    lastcur=$(getkey "$blob" fin_lastCur '"CNY"' | jq -r '. // "CNY"')
    [ "$lastcur" != "USD" ] && lastcur="CNY"

    if [ -n "${3:-}" ]; then
      # 预设金额，直接记，不弹窗
      amt="$3"; cur="${4:-$lastcur}"; note=""
    else
      hint=$([ "$lastcur" = "USD" ] && echo 'USD' || echo '人民币')
      text=$(ask "记一笔【${CAT}】·  默认${hint}

直接输金额，也可以带备注和币种：
    35                →  35
    35 星巴克         →  带备注
    12 usd 咖啡       →  指定美元" "今日花销" "记下") || exit 0

      parsed=$(printf '%s' "$text" | jq -Rc --arg def "$lastcur" '
        (. | sub("^\\s+";"") | sub("\\s+$";"")) as $s
        | [$s | capture("^(?<p>[$¥￥])?\\s*(?<n>[0-9]+(\\.[0-9]+)?)\\s*(?<f>[$¥￥]|[Uu][Ss][Dd]|[Cc][Nn][Yy])?\\s*(?<note>.*)$")?] as $ms
        | if ($ms|length) == 0 then {err:true}
          else $ms[0] as $m
          | ((($m.p // "") + ($m.f // "")) | ascii_downcase) as $c
          | {err:false, amount:($m.n|tonumber),
             cur:(if ($c|test("\\$|usd")) then "USD" elif ($c|test("¥|￥|cny")) then "CNY" else $def end),
             note:($m.note | sub("\\s+$";""))}
          end')
      verdict=$(printf '%s' "$parsed" | jq -r '
        if (type != "object") then "bad"
        elif (.err | not | not) then "bad"
        elif ((.amount // 0) <= 0) then "zero"
        else "ok" end')
      case "$verdict" in
        bad)  notify "没记下" "金额格式看不懂：${text}"; exit 0 ;;
        zero) notify "没记下" "金额要大于 0"; exit 0 ;;
      esac
      amt=$(printf '%s' "$parsed" | jq -r '.amount')
      cur=$(printf '%s' "$parsed" | jq -r '.cur')
      note=$(printf '%s' "$parsed" | jq -r '.note')
    fi

    txs=$(getkey "$blob" fin_tx '[]')
    newtx=$(printf '%s' "$txs" | jq -c --arg id "$(newid)" --arg d "$today" --argjson a "$amt" \
      --arg c "$CAT" --arg n "$note" --arg cu "$cur" \
      '. + [{id:$id,date:$d,amount:$a,type:"expense",cat:$c,note:$n,cur:$cu}]')
    if push_keys "$blob" fin_tx "$newtx" fin_lastCur "$(printf '%s' "$cur" | jq -R .)"; then
      notify "已记账 ✓" "${CAT} $(money "$amt" "$cur")${note:+ · $note}"
    else notify "记账失败" "写入云端出错"; fi
    exit 0 ;;

  undo)
    blob=$(fetch_blob) || { notify "撤销失败" "连不上云端"; exit 1; }
    txs=$(getkey "$blob" fin_tx '[]')
    last=$(printf '%s' "$txs" | jq -c 'if length>0 then .[-1] else null end')
    [ "$last" = "null" ] && { notify "没有可撤销的" "账本是空的"; exit 0; }
    la=$(printf '%s' "$last" | jq -r '.amount'); lc=$(printf '%s' "$last" | jq -r '.cur // "CNY"')
    lcat=$(printf '%s' "$last" | jq -r '.cat'); ln=$(printf '%s' "$last" | jq -r '.note')
    confirm "删除最近一笔？\n\n${lcat}    $(money "$la" "$lc")${ln:+    ·    ${ln}}" "撤销记账" "删除" || exit 0
    newtx=$(printf '%s' "$txs" | jq -c '.[0:-1]')
    if push_keys "$blob" fin_tx "$newtx"; then notify "已删除" "${lcat} $(money "$la" "$lc")"
    else notify "删除失败" "写入云端出错"; fi
    exit 0 ;;

  test)
    echo "API : $API_BASE"
    if b=$(fetch_blob); then
      echo "连接: OK"
      echo "今天: $(compute_today "$b")"
      echo "戒色: $(getkey "$b" abstain '{}')"
      echo "笔数: $(getkey "$b" fin_tx '[]' | jq 'length')"
      echo "预算: $(getkey "$b" fin_budget '""' | jq -r '. // ""')"
    else echo "连接: 失败"; exit 1; fi
    exit 0 ;;
esac

# ─────────────────────── 渲染 ───────────────────────

blob=$(fetch_blob)
if [ -z "$blob" ]; then
  echo "📋 —"; echo "---"; echo "连不上云端 | color=orange"
  echo "立即刷新 | refresh=true"; echo "打开生活规划系统 | href=$API_BASE"; exit 0
fi

today=$(compute_today "$blob"); month="${today:0:7}"

# ── 戒色 ──
ab=$(getkey "$blob" abstain '{}')
start=$(printf '%s' "$ab" | jq -r '.start // empty')
last=$(printf '%s' "$ab" | jq -r '.lastCheck // empty')
best=$(printf '%s' "$ab" | jq -r '.best // 0')
if [ -n "$start" ]; then days=$(days_since "$start" "$today"); else days=0; fi
[ "$best" -lt "$days" ] && best="$days"
[ "$last" = "$today" ] && checked=1 || checked=0

# ── 花销 ──
txs=$(getkey "$blob" fin_tx '[]')
bcur=$(getkey "$blob" fin_budgetCur '"CNY"' | jq -r '. // "CNY"'); [ "$bcur" != "USD" ] && bcur="CNY"
budget=$(getkey "$blob" fin_budget '""' | jq -r '. // ""')
case "$budget" in ''|*[!0-9.]*) budget=0 ;; esac
sum(){ printf '%s' "$txs" | jq -r --arg p "$1" --arg c "$2" \
  '[.[] | select(.type=="expense" and (.date // "" | startswith($p)) and ((.cur // "CNY")==$c)) | .amount] | add // 0'; }
tCNY=$(sum "$today" CNY); tUSD=$(sum "$today" USD)
mCNY=$(sum "$month" CNY); mUSD=$(sum "$month" USD)
mBC=$([ "$bcur" = "USD" ] && echo "$mUSD" || echo "$mCNY")
gt(){ [ "$(printf '%s>%s\n' "$1" "$2" | bc -l 2>/dev/null)" = "1" ]; }

tToday="$(money "$tCNY" CNY)"; gt "$tUSD" 0 && tToday="$tToday·$(money "$tUSD" USD)"
over=0; [ "$budget" != "0" ] && gt "$mBC" "$budget" && over=1

# ── 菜单栏标题：一个位置装两件事 ──
dot=""; [ "$checked" = "0" ] && dot="・"
if [ "$over" = "1" ]; then
  echo "🛡${days}${dot}  ${tToday} | color=#d9534f"
elif [ "$checked" = "0" ]; then
  echo "🛡${days}${dot}  ${tToday} | color=#e08b3a"
else
  echo "🛡${days}  ${tToday}"
fi

echo "---"

# ── 戒色区 ──
echo "🛡  戒色 | size=11 color=gray"
echo "连续坚持 ${days} 天　·　最长 ${best} 天 | size=14"
if [ "$checked" = "1" ]; then
  echo "今日已坚持 ✓ | color=#5cb85c"
else
  echo "今日已坚持 ✓ | bash=\"$SELF\" param1=\"checkin\" terminal=false refresh=true"
fi
echo "破戒重置 | bash=\"$SELF\" param1=\"reset\" terminal=false refresh=true"

echo "---"

# ── 花销区 ──
echo "💰  花销 | size=11 color=gray"
echo "今日支出　${tToday} | size=14"
mline="$(money "$mCNY" CNY)"; gt "$mUSD" 0 && mline="$mline · $(money "$mUSD" USD)"
echo "本月支出　${mline} | size=13"

if [ "$budget" != "0" ]; then
  remain=$(printf '%s-%s\n' "$budget" "$mBC" | bc -l)
  day=$((10#${today:8:2}))
  dim=$(TZ=UTC date -j -v1d -v"${today:5:2}"m -v"${today:0:4}"y -v+1m -v-1d +%d 2>/dev/null || echo 30)
  avg=$(printf 'scale=2;%s/%s\n' "$mBC" "$day" | bc -l)
  proj=$(printf 'scale=2;%s*%s\n' "$avg" "$((10#$dim))" | bc -l)
  if [ "$over" = "1" ]; then echo "已超预算　$(money "${remain#-}" "$bcur") | color=#d9534f size=13"
  else echo "剩余预算　$(money "$remain" "$bcur") | color=#5cb85c size=13"; fi
  echo "日均 $(money "$avg" "$bcur")　·　本月预计 $(money "$proj" "$bcur") | color=gray size=11"
else
  echo "未设月预算 | color=gray size=11"
fi

echo "记一笔"
for c in "${CATS[@]}"; do
  echo "--$c"
  for a in 10 20 30 50 100 200; do
    echo "----¥$a | bash=\"$SELF\" param1=\"add\" param2=\"$c\" param3=\"$a\" param4=\"CNY\" terminal=false refresh=true"
  done
  echo "-------"
  for a in 5 10 20 50; do
    echo "----\$$a | bash=\"$SELF\" param1=\"add\" param2=\"$c\" param3=\"$a\" param4=\"USD\" terminal=false refresh=true"
  done
  echo "-------"
  echo "----自定义金额… | bash=\"$SELF\" param1=\"add\" param2=\"$c\" terminal=false refresh=true"
done

cnt=$(printf '%s' "$txs" | jq -r --arg d "$today" '[.[]|select(.type=="expense" and .date==$d)]|length')
if [ "$cnt" -gt 0 ]; then
  echo "今日明细 ($cnt 笔)"
  printf '%s' "$txs" | jq -r --arg d "$today" \
    '.[] | select(.type=="expense" and .date==$d) | "--\(.cat)\(if (.note//"")!="" then " · "+.note else "" end)　\(if (.cur//"CNY")=="USD" then "$" else "¥" end)\(.amount) | size=12"'
  echo "删除最近一笔 | bash=\"$SELF\" param1=\"undo\" terminal=false refresh=true"
else
  echo "今天还没记账 | color=gray size=12"
fi

echo "---"
echo "打开生活规划系统 | href=$API_BASE"
echo "立即刷新 | refresh=true"
