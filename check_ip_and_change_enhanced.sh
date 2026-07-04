#!/usr/bin/env bash

set -euo pipefail

# ============================================================
# 增强版：服务器 IP 国内连通性检测 + 自动换 IP
#
# 功能：
# 1. 获取当前服务器公网 IPv4
# 2. 做简单 GFW / 出口环境检测
# 3. 使用 Boce API 从中国大陆节点 ping 指定域名，按丢包率判断国内连通性
# 4. 连续失败达到阈值后，调用接口更换 IP
# 5. 换 IP 后等待网络恢复，重新获取新 IP 并复测
# 6. 支持可选 Webhook 通知
# ============================================================

# =========================
# 配置区
# =========================

# 填写换 IP 的 API URL。请勿把真实 URL 提交到公开仓库。
CHANGE_IP_URL='从运营商处获取的更换IP的URL'

# Boce ping 检测配置

# 从 BOCE 官网获取 API Key。请勿把真实 Key 提交到公开仓库。
BOCE_API_KEY='填写获取到的API'
# 浏览器访问 https://api.boce.com/v3/node/list?key=申请的key 获取节点 ID
BOCE_NODE_IDS='30,31'
BOCE_HOST='需要测试的域名或者ip(一次只能检测一个域名或者ip)'
BOCE_CREATE_URL='https://api.boce.com/v3/task/create/ping'
BOCE_RESULT_BASE_URL='https://api.boce.com/v3/task/ping'

# Boce 任务创建后等待多久再获取一次结果。
# 为避免消耗余额，每轮脚本只创建一次任务、获取一次结果，不轮询。
BOCE_RESULT_WAIT_SECONDS=8

# 综合丢包率高于该百分比，判定国内不可达
BOCE_PACKET_LOSS_THRESHOLD=70

# curl 超时时间，单位：秒
CURL_TIMEOUT=20

# 连续失败多少次才更换 IP
FAIL_THRESHOLD=3

# 每次失败检测之间等待多久，单位：秒
RETRY_INTERVAL=20

# 换 IP 后等待网络恢复多久，单位：秒
WAIT_AFTER_CHANGE=60

# 状态与日志文件
STATE_DIR='/var/lib/ip_reachability_checker'
STATE_FILE="$STATE_DIR/fail_count"
LOG_FILE='/var/log/ip_reachability_checker.log'

# 可选通知 Webhook。
# 留空则不通知。
# 支持普通 webhook，例如飞书/企业微信/Telegram bot relay 等。
# 请勿把真实 Webhook URL 提交到公开仓库。
NOTIFY_WEBHOOK=''

# 是否启用 GFW 出口环境检测：1 启用，0 禁用
ENABLE_GFW_CHECK=1


# =========================
# 工具函数
# =========================

ensure_dirs() {
    mkdir -p "$STATE_DIR"
    touch "$LOG_FILE" 2>/dev/null || true
}

log() {
    local msg="$1"
    echo "[$(date '+%F %T')] $msg" | tee -a "$LOG_FILE"
}

notify() {
    local msg="$1"

    if [[ -z "$NOTIFY_WEBHOOK" ]]; then
        return 0
    fi

    curl -fsSL \
        --max-time "$CURL_TIMEOUT" \
        -H 'Content-Type: application/json' \
        -X POST \
        -d "$(MSG="$msg" python3 - <<'PY'
import json
import os
print(json.dumps({"text": os.environ.get("MSG", "")}, ensure_ascii=False))
PY
)" \
        "$NOTIFY_WEBHOOK" >/dev/null 2>&1 || true
}

require_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log "缺少命令: $cmd，请先安装。"
        exit 1
    fi
}

read_fail_count() {
    if [[ -f "$STATE_FILE" ]]; then
        local n
        n="$(tr -dc '0-9' < "$STATE_FILE" || true)"
        echo "${n:-0}"
    else
        echo "0"
    fi
}

write_fail_count() {
    local n="$1"
    echo "$n" > "$STATE_FILE"
}

reset_fail_count() {
    write_fail_count 0
}

increase_fail_count() {
    local old
    old="$(read_fail_count)"
    local new=$((old + 1))
    write_fail_count "$new"
    echo "$new"
}

capture_check_rc() {
    local __var_name="$1"
    shift

    if "$@"; then
        printf -v "$__var_name" '%s' 0
    else
        printf -v "$__var_name" '%s' "$?"
    fi
}


# =========================
# 获取公网 IP
# =========================

get_public_ip() {
    local ip=''

    ip="$(curl -4 -fsS --max-time "$CURL_TIMEOUT" https://api.ipify.org || true)"

    if [[ -z "$ip" ]]; then
        ip="$(curl -4 -fsS --max-time "$CURL_TIMEOUT" https://ifconfig.me/ip || true)"
    fi

    if [[ -z "$ip" ]]; then
        ip="$(curl -4 -fsS --max-time "$CURL_TIMEOUT" https://icanhazip.com || true)"
    fi

    ip="$(echo "$ip" | tr -d '[:space:]')"

    if [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        log "获取公网 IP 失败，返回内容: $ip"
        return 1
    fi

    echo "$ip"
}


# =========================
# GFW / 网络环境检测
# =========================

gfw_environment_check() {
    if [[ "$ENABLE_GFW_CHECK" != '1' ]]; then
        log 'GFW / 出口环境检测已禁用。'
        return 0
    fi

    log '开始 GFW / 出口环境检测...'

    local ok=0
    local fail=0

    local urls=(
        'https://www.google.com/generate_204'
        'https://www.gstatic.com/generate_204'
        'https://github.com'
        'https://api.telegram.org'
    )

    local url
    for url in "${urls[@]}"; do
        if curl -fsS -I --max-time "$CURL_TIMEOUT" "$url" >/dev/null 2>&1; then
            log "访问成功: $url"
            ok=$((ok + 1))
        else
            log "访问失败: $url"
            fail=$((fail + 1))
        fi
    done

    log "GFW 检测结果: 成功 $ok 个，失败 $fail 个"

    if (( fail >= 3 )); then
        log '判断: 当前服务器出口可能处于 GFW/受限网络环境。'
    else
        log '判断: 当前服务器出口看起来基本正常。'
    fi
}


# =========================
# 国内连通性检测：Boce API
# =========================
#
# 返回码：
#   0 = 国内可达
#   1 = 国内不可达，综合丢包率高于阈值
#   2 = 检测异常/结果矛盾，不触发换 IP

create_boce_ping_task() {
    local response
    response="$(curl -fsS --max-time "$CURL_TIMEOUT" -G \
        --data-urlencode "key=$BOCE_API_KEY" \
        --data-urlencode "node_ids=$BOCE_NODE_IDS" \
        --data-urlencode "host=$BOCE_HOST" \
        "$BOCE_CREATE_URL" || true)"

    if [[ -z "$response" ]]; then
        log 'Boce 创建 ping 检测任务失败：响应为空。'
        return 1
    fi

    local parse_result
    parse_result="$(BOCE_RESPONSE="$response" python3 - <<'PY'
import json
import os
import sys

raw = os.environ.get('BOCE_RESPONSE', '')
try:
    payload = json.loads(raw)
except Exception as exc:
    print(f'ERR\tJSON 解析失败: {exc}')
    sys.exit(0)

if payload.get('error_code') not in (0, '0', None):
    print(f"ERR\tBoce 返回错误: {payload.get('error') or payload}")
    sys.exit(0)

data = payload.get('data') or {}
task_id = data.get('id') or payload.get('id')
if not task_id:
    print(f'ERR\tBoce 响应中没有任务 id: {payload}')
    sys.exit(0)

print(f'OK\t{task_id}')
PY
)"

    if [[ "$parse_result" == OK$'\t'* ]]; then
        echo "${parse_result#*$'\t'}"
        return 0
    fi

    log "${parse_result#*$'\t'}"
    return 1
}

fetch_boce_ping_result() {
    local task_id="$1"
    curl -fsS --max-time "$CURL_TIMEOUT" \
        "${BOCE_RESULT_BASE_URL}/${task_id}?key=${BOCE_API_KEY}" || true
}

analyze_boce_ping_result() {
    local response="$1"

    BOCE_RESPONSE="$response" BOCE_LOSS_THRESHOLD="$BOCE_PACKET_LOSS_THRESHOLD" python3 - <<'PY'
import json
import os
import sys

raw = os.environ.get('BOCE_RESPONSE', '')
threshold = float(os.environ.get('BOCE_LOSS_THRESHOLD', '70'))

try:
    payload = json.loads(raw)
except Exception as exc:
    print(f'RC=2\nSUMMARY=Boce 结果 JSON 解析失败: {exc}')
    sys.exit(0)

if payload.get('error_code') not in (0, '0', None):
    print(f"RC=2\nSUMMARY=Boce 查询结果接口返回错误: {payload.get('error') or payload}")
    sys.exit(0)

container = payload.get('data') if isinstance(payload.get('data'), dict) else payload
if container.get('done') is False:
    print('RC=3\nSUMMARY=Boce 任务尚未完成')
    sys.exit(0)

items = container.get('list') or payload.get('list') or []
if not isinstance(items, list) or not items:
    print('RC=2\nSUMMARY=Boce 结果为空或缺少 list')
    sys.exit(0)

valid = []
error_nodes = []
for item in items:
    node = item.get('node_name') or str(item.get('node_id') or 'unknown')
    error_code = item.get('error_code')
    error = item.get('error') or ''
    if error_code not in (0, '0', None):
        error_nodes.append(f'{node}: {error or error_code}')
        continue

    transmitted = item.get('packets_transmitted')
    received = item.get('packets_received')
    packet_loss = item.get('packet_loss')

    try:
        transmitted = int(transmitted)
        received = int(received)
    except Exception:
        transmitted = None
        received = None

    try:
        packet_loss = float(packet_loss)
    except Exception:
        packet_loss = None

    if transmitted is not None and transmitted > 0 and received is not None:
        loss = max(0.0, min(100.0, (transmitted - received) * 100.0 / transmitted))
        valid.append((node, transmitted, received, loss))
    elif packet_loss is not None:
        valid.append((node, 0, 0, max(0.0, min(100.0, packet_loss))))
    else:
        error_nodes.append(f'{node}: 缺少丢包数据')

if not valid:
    detail = '; '.join(error_nodes) if error_nodes else '所有节点无有效结果'
    print(f'RC=2\nSUMMARY=Boce 无有效节点结果: {detail}')
    sys.exit(0)

sum_tx = sum(row[1] for row in valid)
sum_rx = sum(row[2] for row in valid)
if sum_tx > 0:
    total_loss = max(0.0, min(100.0, (sum_tx - sum_rx) * 100.0 / sum_tx))
else:
    total_loss = sum(row[3] for row in valid) / len(valid)

node_summary = ', '.join(f'{node} 丢包 {loss:.1f}%' for node, _, _, loss in valid)
if error_nodes:
    node_summary += '; 异常节点: ' + '; '.join(error_nodes)

if total_loss > threshold:
    print(f'RC=1\nSUMMARY=综合丢包率 {total_loss:.1f}% > {threshold:.1f}%，判定国内不可达。节点结果: {node_summary}')
else:
    print(f'RC=0\nSUMMARY=综合丢包率 {total_loss:.1f}% <= {threshold:.1f}%，判定国内可达。节点结果: {node_summary}')
PY
}

check_cn_reachability() {
    local target_ip="$1"

    log "开始通过 Boce 检测国内节点到 $BOCE_HOST 的 ping 连通性（当前公网 IP: $target_ip）"

    local task_id
    if ! task_id="$(create_boce_ping_task)"; then
        log 'Boce 检测任务创建失败，视为检测异常，不触发换 IP。'
        return 2
    fi

    log "Boce ping 检测任务已创建，任务 ID: $task_id"
    log "等待 $BOCE_RESULT_WAIT_SECONDS 秒后获取一次 Boce 检测结果。"
    sleep "$BOCE_RESULT_WAIT_SECONDS"

    local response analysis rc summary
    response="$(fetch_boce_ping_result "$task_id")"
    if [[ -z "$response" ]]; then
        log 'Boce 获取结果失败：响应为空，视为检测异常，不触发换 IP。'
        return 2
    fi

    analysis="$(analyze_boce_ping_result "$response")"
    rc="$(printf '%s\n' "$analysis" | sed -n 's/^RC=//p' | tail -n 1)"
    summary="$(printf '%s\n' "$analysis" | sed -n 's/^SUMMARY=//p' | tail -n 1)"

    log "$summary"

    if [[ "$rc" == '3' ]]; then
        log 'Boce 任务尚未完成；为避免重复调用消耗余额，本轮视为检测异常，不触发换 IP。'
        return 2
    fi

    case "$rc" in
        0) return 0 ;;
        1) return 1 ;;
        *) return 2 ;;
    esac
}


# =========================
# 连续失败确认说明
# =========================
#
# Boce API 调用需要耗费余额，因此脚本不在单次运行内重复创建检测任务。
# 连续失败确认由 STATE_FILE 中的失败计数承担：每次 cron 运行最多创建一次任务、获取一次结果。


# =========================
# 更换 IP
# =========================

change_ip() {
    log '开始调用更换 IP 接口...'

    local http_code
    local resp
    local resp_file
    resp_file="$(mktemp /tmp/ip_change_resp.XXXXXX)"

    http_code="$(curl -fsSL \
        --max-time "$CURL_TIMEOUT" \
        -o "$resp_file" \
        -w '%{http_code}' \
        "$CHANGE_IP_URL" || true)"

    if [[ "$http_code" == '' ]]; then
        log '更换 IP 接口网络请求失败（无法获取 HTTP 状态码）。'
        notify 'IP 连通性检测：更换 IP 接口网络请求失败。'
        rm -f "$resp_file"
        return 1
    fi

    resp="$(sed -e 's/[[:cntrl:]]//g' "$resp_file" 2>/dev/null || true)"
    rm -f "$resp_file"

    log "更换 IP 接口 HTTP 状态码: $http_code，响应内容: ${resp:-（空）}"

    if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
        notify "IP 连通性检测：已调用更换 IP 接口（HTTP $http_code），等待复测验证结果。"
        return 0
    fi

    log "更换 IP 接口返回非 2xx 状态码: $http_code，内容: $resp"
    notify "IP 连通性检测：更换 IP 接口返回异常状态码 $http_code。"
    return 1
}


# =========================
# 换 IP 后轻量验证
# =========================

post_change_recheck() {
    log "换 IP 后等待 $WAIT_AFTER_CHANGE 秒，等待网络恢复..."
    sleep "$WAIT_AFTER_CHANGE"

    local new_ip=''
    if ! new_ip="$(get_public_ip)"; then
        log '换 IP 后重新获取公网 IP 失败。'
        notify 'IP 连通性检测：换 IP 后重新获取公网 IP 失败。'
        return 1
    fi

    log "换 IP 后当前公网 IP: $new_ip"
    log '为避免重复消耗 Boce 余额，本轮不再复测国内连通性；下一次定时任务会重新检测。'
    notify "IP 连通性检测：已调用更换 IP 接口，当前公网 IP：$new_ip。下一次定时任务将复测国内连通性。"
    reset_fail_count
    return 0
}


# =========================
# 主流程
# =========================

main() {
    require_cmd curl
    require_cmd python3
    require_cmd sed
    require_cmd tr
    require_cmd mktemp

    ensure_dirs

    log '========== 开始检测 =========='

    local current_ip=''
    if ! current_ip="$(get_public_ip)"; then
        log '无法获取当前公网 IP，本轮退出。'
        notify 'IP 连通性检测：无法获取当前公网 IP。'
        exit 1
    fi

    log "当前服务器公网 IP: $current_ip"

    gfw_environment_check

    local cn_rc
    capture_check_rc cn_rc check_cn_reachability "$current_ip"

    if (( cn_rc == 0 )); then
        log '当前 IP 国内可达，不需要更换。'
        reset_fail_count
        log '连续失败计数已清零。'
        log '========== 检测结束 =========='
        exit 0
    fi

    if (( cn_rc == 2 )); then
        log '检测异常/结果矛盾，安全起见本轮不换 IP，也不增加失败计数。'
        log '========== 检测结束 =========='
        exit 0
    fi

    local fail_count
    fail_count="$(increase_fail_count)"
    log "当前 IP 国内不可达，连续失败计数: $fail_count/$FAIL_THRESHOLD"

    if (( fail_count < FAIL_THRESHOLD )); then
        log '尚未达到更换 IP 阈值，本轮不换 IP。'
        log '========== 检测结束 =========='
        exit 0
    fi

    log '连续失败计数已达到阈值，开始调用更换 IP 接口。'
    log '为避免重复消耗 Boce 余额，本轮不再做额外确认；连续确认由定时任务失败计数承担。'

    if change_ip; then
        post_change_recheck || true
    else
        log '更换 IP 失败，保留失败计数，等待下次任务继续检测。'
    fi

    log '========== 检测结束 =========='
}

main "$@"
