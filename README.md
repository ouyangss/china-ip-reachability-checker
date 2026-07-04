# China IP Reachability Checker

服务器 IP 国内连通性检测 + 自动换 IP Bash 脚本。
本项目运用BOCE（boce.com）的API进行国内连通性PING检测，该API运用需要花费到BOCE官方余额（即波点），请自行注册BOCE账户并获取波点。
通过 【https://www.boce.com/?k=KwKHRgtLPU】 注册可获取1W波点。
IP 国内连通性检测也可以替换为其他同类项目，请自行修改。

## 功能

- 获取当前服务器公网 IPv4
- 可选执行简单 GFW / 出口环境检测
- 使用 Boce API 从中国大陆节点 ping 指定域名或 IP
- 按综合丢包率判断国内连通性
- 连续失败达到阈值后调用换 IP API
- 换 IP 后等待网络恢复并重新获取公网 IP
- 支持可选 Webhook 通知

## 安全说明

公开仓库中的脚本只包含占位配置，没有真实 API Key、换 IP URL、Webhook URL 或服务器 IP。

请勿把以下真实值提交到公开仓库：

- `CHANGE_IP_URL`
- `BOCE_API_KEY`
- `BOCE_HOST` 中的敏感内部地址
- `NOTIFY_WEBHOOK`

建议在生产环境中通过本地私有副本配置这些值。

## 使用方法

```bash
chmod +x check_ip_and_change_enhanced.sh
sudo ./check_ip_and_change_enhanced.sh
```

## 配置项

编辑脚本顶部配置区：

```bash
CHANGE_IP_URL='从运营商处获取的更换IP的URL'
BOCE_API_KEY='填写获取到的API'
BOCE_NODE_IDS='30,31'
BOCE_HOST='需要测试的域名或者ip(一次只能检测一个域名或者ip)'
NOTIFY_WEBHOOK=''
```

## 定时任务示例

例如每 5 分钟检测一次：

```cron
*/5 * * * * /usr/bin/env bash /path/to/check_ip_and_change_enhanced.sh >/dev/null 2>&1
```

## 依赖

- bash
- curl
- python3
- sed
- tr
- mktemp

## 验证脚本语法

```bash
bash -n check_ip_and_change_enhanced.sh
```

## 返回逻辑

Boce 检测返回分三类：

- `0`：国内可达
- `1`：国内不可达，失败计数增加
- `2`：检测异常或结果矛盾，不增加失败计数、不换 IP

为节省 Boce 余额，每轮脚本最多创建一次检测任务、获取一次结果，不做轮询。
