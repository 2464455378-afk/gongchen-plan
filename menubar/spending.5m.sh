#!/bin/bash
# <bitbar.title>今日花销</bitbar.title>
# <bitbar.version>v1.0</bitbar.version>
# <bitbar.author>gongchen</bitbar.author>
# <bitbar.desc>与「生活规划系统」云端同步联动的记账菜单栏组件</bitbar.desc>
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
  echo "💰 未配置"; echo "---"; echo "先运行 menubar/install.sh | color=orange"; exit 0
fi
. "$CFG"
if [ -z "${API_BASE:-}" ] || [ -z "${SYNC_KEY:-}" ]; then
  echo "💰 配置不全"; echo "---"; echo "config 缺 API_BASE 或 SYNC_KEY | color=orange"; exit 0
fi
API="${API_BASE%/}/api/data?key=${SYNC_KEY}"

# ─────────────────────── 工具 ───────────────────────

fetch_blob(){ curl -fsS --max-time 8 "$API" 2>/dev/null; }

compute_today(){
  local tz
  tz=$(printf '%s' "$1" | jq -r '(.data // {} | .tz) // empty' 2>/dev/null | jq -r '. // empty' 2>/dev/null)
  if [ -n "$tz" ]; then TZ="$tz" date +%F; else date +%F; fi
}

# 取出某个 localStorage 键（它们都是 JSON 字符串），第二参为默认值
getkey(){ printf '%s' "$1" | jq -r --arg k "$2" --arg d "$3" '((.data // {} | .[$k]) // $d)' 2>/dev/null; }

# 千分位 + 两位小数
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

push(){  # $1=blob  $2=新的 fin_tx(JSON字符串)  $3=新的 fin_lastCur(JSON字符串)
  local nb
  nb=$(printf '%s' "$1" | jq -c --arg tx "$2" --arg cur "$3" --argjson ts "$(now_ms)" \
    '.data = ((.data // {}) | .fin_tx = $tx | .fin_lastCur = $cur) | .ts = $ts') || return 1
  curl -fsS --max-time 8 -X PUT -H 'content-type: application/json' \
    --data-binary "$nb" "$API" >/dev/null 2>&1
}

notify(){ /usr/bin/osascript -e "display notification \"$2\" with title \"$1\"" >/dev/null 2>&1; }

# ─────────────────────── 动作 ───────────────────────

case "${1:-}" in
  add)
    CAT="${2:-其他}"
    blob=$(fetch_blob) || { notify "记账失败" "连不上云端"; exit 1; }
    today=$(compute_today "$blob")
    lastcur=$(getkey "$blob" fin_lastCur '"CNY"' | jq -r '. // "CNY"')
    [ "$lastcur" != "USD" ] && lastcur="CNY"
    hint=$([ "$lastcur" = "USD" ] && echo '$' || echo '¥')

    raw=$(/usr/bin/osascript -e "display dialog \"记一笔【${CAT}】\n\n直接输金额，默认 ${hint}。可加备注和币种：\n  35          →  ${hint}35\n  35 星巴克   →  带备注\n  \\\$12 咖啡   →  指定美元\" with title \"今日花销\" default answer \"\" buttons {\"取消\",\"记下\"} default button \"记下\"" 2>/dev/null) || exit 0
    case "$raw" in *"button returned:记下"*) ;; *) exit 0 ;; esac
    text=$(printf '%s' "$raw" | sed 's/.*text returned:%//; s/.*text returned://; s/, button returned.*//')

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

    if [ "$(printf '%s' "$parsed" | jq -r '.err')" = "true" ]; then
      notify "没记下" "金额格式看不懂：${text}"; exit 0
    fi
    amt=$(printf '%s' "$parsed" | jq -r '.amount')
    cur=$(printf '%s' "$parsed" | jq -r '.cur')
    note=$(printf '%s' "$parsed" | jq -r '.note')
    if [ "$(printf '%s' "$parsed" | jq -r 'if .amount > 0 then "y" else "n" end')" != "y" ]; then
      notify "没记下" "金额要大于 0"; exit 0
    fi

    txs=$(getkey "$blob" fin_tx '[]')
    newtx=$(printf '%s' "$txs" | jq -c --arg id "$(newid)" --arg d "$today" --argjson a "$amt" \
      --arg c "$CAT" --arg n "$note" --arg cu "$cur" \
      '. + [{id:$id,date:$d,amount:$a,type:"expense",cat:$c,note:$n,cur:$cu}]')

    if push "$blob" "$newtx" "$(printf '%s' "$cur" | jq -R .)"; then
      notify "已记账 ✓" "${CAT} $(money "$amt" "$cur")${note:+ · $note}"
    else
      notify "记账失败" "写入云端出错"
    fi
    exit 0
    ;;

  undo)
    blob=$(fetch_blob) || { notify "撤销失败" "连不上云端"; exit 1; }
    txs=$(getkey "$blob" fin_tx '[]')
    last=$(printf '%s' "$txs" | jq -c 'if length>0 then .[-1] else null end')
    [ "$last" = "null" ] && { notify "没有可撤销的" "账本是空的"; exit 0; }
    la=$(printf '%s' "$last" | jq -r '.amount'); lc=$(printf '%s' "$last" | jq -r '.cur // "CNY"')
    lcat=$(printf '%s' "$last" | jq -r '.cat'); ln=$(printf '%s' "$last" | jq -r '.note')
    ans=$(/usr/bin/osascript -e "display dialog \"删除最近一笔？\n\n${lcat}  $(money "$la" "$lc")${ln:+  ·  ${ln}}\" with title \"撤销记账\" buttons {\"取消\",\"删除\"} default button \"取消\" with icon caution" 2>/dev/null)
    case "$ans" in *"button returned:删除"*) ;; *) exit 0 ;; esac
    newtx=$(printf '%s' "$txs" | jq -c '.[0:-1]')
    lastcur=$(getkey "$blob" fin_lastCur '"CNY"')
    if push "$blob" "$newtx" "$lastcur"; then notify "已删除" "${lcat} $(money "$la" "$lc")"
    else notify "删除失败" "写入云端出错"; fi
    exit 0
    ;;

  test)
    echo "API : $API_BASE"
    if b=$(fetch_blob); then
      echo "连接: OK"
      echo "今天: $(compute_today "$b")"
      echo "笔数: $(getkey "$b" fin_tx '[]' | jq 'length')"
      echo "预算: $(getkey "$b" fin_budget '""' | jq -r '. // ""')"
    else echo "连接: 失败"; exit 1; fi
    exit 0
    ;;
esac

# ─────────────────────── 渲染 ───────────────────────

blob=$(fetch_blob)
if [ -z "$blob" ]; then
  echo "💰 —"; echo "---"; echo "连不上云端 | color=orange"
  echo "刷新 | refresh=true"; echo "打开生活规划系统 | href=$API_BASE"; exit 0
fi

today=$(compute_today "$blob")
month="${today:0:7}"
txs=$(getkey "$blob" fin_tx '[]')
bcur=$(getkey "$blob" fin_budgetCur '"CNY"' | jq -r '. // "CNY"')
[ "$bcur" != "USD" ] && bcur="CNY"
budget=$(getkey "$blob" fin_budget '""' | jq -r '. // ""')
case "$budget" in ''|*[!0-9.]*) budget=0 ;; esac

sum(){ printf '%s' "$txs" | jq -r --arg p "$1" --arg c "$2" \
  '[.[] | select(.type=="expense" and (.date // "" | startswith($p)) and ((.cur // "CNY")==$c))
   | .amount] | add // 0'; }

tCNY=$(sum "$today" CNY); tUSD=$(sum "$today" USD)
mCNY=$(sum "$month" CNY); mUSD=$(sum "$month" USD)
mBC=$([ "$bcur" = "USD" ] && echo "$mUSD" || echo "$mCNY")

# 菜单栏标题：今日支出，有几种货币显示几种
title=""
[ "$(printf '%s>0\n' "$tCNY" | bc -l 2>/dev/null)" = "1" ] && title="$(money "$tCNY" CNY)"
if [ "$(printf '%s>0\n' "$tUSD" | bc -l 2>/dev/null)" = "1" ]; then
  [ -n "$title" ] && title="$title · $(money "$tUSD" USD)" || title="$(money "$tUSD" USD)"
fi
[ -z "$title" ] && title="$(money 0 "$bcur")"

over=$(printf '%s>%s\n' "$mBC" "${budget:-0}" | bc -l 2>/dev/null)
if [ "${budget:-0}" != "0" ] && [ "$over" = "1" ]; then
  echo "💰 $title | color=#d9534f"
else
  echo "💰 $title"
fi

echo "---"
echo "今日支出  $title | size=14"

mline="$(money "$mCNY" CNY)"
[ "$(printf '%s>0\n' "$mUSD" | bc -l 2>/dev/null)" = "1" ] && mline="$mline · $(money "$mUSD" USD)"
echo "本月支出  $mline | size=13"

if [ "${budget:-0}" != "0" ]; then
  remain=$(printf '%s-%s\n' "$budget" "$mBC" | bc -l)
  day=$((10#${today:8:2}))
  dim=$(TZ=UTC date -j -v1d -v"${today:5:2}"m -v"${today:0:4}"y -v+1m -v-1d +%d 2>/dev/null || echo 30)
  avg=$(printf 'scale=2;%s/%s\n' "$mBC" "$day" | bc -l)
  proj=$(printf 'scale=2;%s*%s\n' "$avg" "$((10#$dim))" | bc -l)
  if [ "$over" = "1" ]; then
    echo "已超预算  $(money "${remain#-}" "$bcur") | color=#d9534f size=13"
  else
    echo "剩余预算  $(money "$remain" "$bcur") | color=#5cb85c size=13"
  fi
  echo "日均 $(money "$avg" "$bcur")  ·  本月预计 $(money "$proj" "$bcur") | color=gray size=11"
else
  echo "未设月预算 | color=gray size=11"
fi

echo "---"
echo "记一笔"
for c in "${CATS[@]}"; do
  echo "--$c | bash=\"$SELF\" param1=add param2=$c terminal=false refresh=true"
done

todaycount=$(printf '%s' "$txs" | jq -r --arg d "$today" '[.[]|select(.type=="expense" and .date==$d)]|length')
if [ "$todaycount" -gt 0 ]; then
  echo "今日明细 ($todaycount 笔)"
  printf '%s' "$txs" | jq -r --arg d "$today" \
    '.[] | select(.type=="expense" and .date==$d) | "--\(.cat)\(if (.note//"")!="" then " · "+.note else "" end)  \(if (.cur//"CNY")=="USD" then "$" else "¥" end)\(.amount) | font=Menlo size=12"'
  echo "---"
  echo "删除最近一笔 | bash=\"$SELF\" param1=undo terminal=false refresh=true"
else
  echo "今天还没记账 | color=gray size=12"
fi

echo "---"
echo "打开生活规划系统 | href=$API_BASE"
echo "立即刷新 | refresh=true"
