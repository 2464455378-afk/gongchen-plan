# 菜单栏组件

两个常驻菜单栏的小工具，和网页端「生活规划系统」共用同一份云端数据。

```
🛡 12        戒色打卡 —— 已打卡
🛡 12 ・     今天还没打卡（橙色）

💰 ¥128.50   今日花销
💰 ¥3,240    超预算时变红
```

## 安装

```bash
brew install --cask swiftbar
bash install.sh
```

安装时填两样：**网址**（如 `https://plan.gongchen.cc`）和**同步密钥**（网页「数据备份 → 云端同步」那串，输入时不回显）。

密钥写在 `~/.config/gongchen-discipline/config`（权限 600），两个插件共用。

装完把插件复制到 SwiftBar 的插件目录（install.sh 会自动做）：

```bash
cp discipline.5m.sh spending.5m.sh ~/SwiftBar/
```

首次打开 SwiftBar 会让你选插件文件夹，选 `~/SwiftBar`。

## 戒色打卡 · discipline.5m.sh

| 菜单项 | 作用 |
|---|---|
| 今日已坚持 ✓ | 打卡，写 `lastCheck` 和 `checkedDates` |
| 破戒重置 | 二次确认后，`start` 归今天，`best` 保留 |

**连续天数 = 今天 − start + 1，和有没有打卡无关。**关机一周回来天数照涨，只有主动「破戒重置」才清零。打卡记的是"哪天打过"，用于日历和统计。

## 今日花销 · spending.5m.sh

| 菜单项 | 作用 |
|---|---|
| 记一笔 → 分类 | 弹窗输金额，写入 `fin_tx` |
| 今日明细 | 列出今天的支出 |
| 删除最近一笔 | 二次确认后删除数组末尾那条 |

**输入格式**（弹窗里）：

```
35            默认币种，无备注
35 星巴克      带备注
$12 咖啡       指定美元
15usd lunch   同上，后缀写法
¥88 打车       指定人民币
```

不写币种就用 `fin_lastCur`（上次用的），和网页端行为一致。记完会更新 `fin_lastCur`。

**统计口径与网页端完全一致**：

- 今日／本月支出按币种分别累加，**两种货币不换算**
- 预算和剩余**只统计 `fin_budgetCur` 那一种货币**
- 日均 = 本月支出 ÷ 当前日数；本月预计 = 日均 × 当月天数

## 怎么和网页联动

网页端本来就有云同步（`functions/api/data.js`，Cloudflare KV）。两个插件走同一个接口：

| | |
|---|---|
| 读 | `GET /api/data?key=…` |
| 写 | 先 `GET` 最新整块 → 只改自己那几个键和 `ts` → `PUT` 回去 |

**为什么先读再写**：`PUT` 会替换整个数据块。只写自己的键会把待办、财务、习惯全抹掉，所以每次动作前必须重新拉最新的。两个插件各自只碰自己的键（`abstain` / `fin_tx`+`fin_lastCur`），互不干扰。

**为什么改 `ts`**：网页端 `cloudSyncOnLoad()` 打开时比较时间戳，云端更新才会覆盖本地。插件写 `Date.now()`，所以你打开网页就能看到。

时区跟网页端对齐：都读云端的 `tz` 设置算"今天"。

## 已知限制

**网页开着的时候用插件操作，可能被覆盖。**

网页只在**打开时**拉一次云端，之后任何操作都会把内存里的旧数据推上去。所以：

> 用插件记完账／打完卡，如果浏览器那个页面还开着，刷新一下再操作网页。

## 常用命令

```bash
# 自检
~/SwiftBar/discipline.5m.sh test
~/SwiftBar/spending.5m.sh test

# 改配置
open -e ~/.config/gongchen-discipline/config

# 改刷新频率：重命名即可
# xxx.5m.sh → xxx.1m.sh（1 分钟）/ 30s.sh / 1h.sh
```

改完在菜单栏点 SwiftBar → Refresh All 生效。

## 开机自启

SwiftBar 已加入登录项。检查：

```bash
osascript -e 'tell application "System Events" to get the name of every login item'
```

## 文件

| 文件 | 说明 |
|---|---|
| `discipline.5m.sh` | 戒色打卡插件 |
| `spending.5m.sh` | 今日花销插件 |
| `install.sh` | 安装脚本 |
| `~/.config/gongchen-discipline/config` | 网址与密钥，权限 600，两个插件共用 |

纯 bash + curl + jq，macOS 全部自带，不依赖 Python/Node。
