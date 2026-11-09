#!/bin/bash

# ==============================================================================
# PVE Custom Metrics Installer v2 (Web UI + hw-metrics)
#
# Патчи Nodes.pm и pvemanagerlib.js обёрнуты в маркеры:
#   BEGIN pve_custom_metrics ... END pve_custom_metrics
# Повторный запуск вырезает старый блок и вставляет новый (идемпотентно).
# Старый патч без маркеров (версия v1) тоже распознаётся и убирается.
#
# ОТКАТ:    /usr/local/bin/uninstall-pve-metrics.sh (создаётся этим скриптом;
#           вырезает блоки по маркерам, от бэкапов не зависит, после
#           обновления PVE работает так же).
# АВАРИЙНО: apt-get install --reinstall pve-manager proxmox-widget-toolkit
# БЭКАПЫ:   перед каждым запуском копии файлов -> /var/lib/pve-dashboard-backup/
#           (<имя>.<дата>.bak, хранятся 5 последних). Если патч не прошёл
#           проверку, файлы возвращаются в состояние ДО этого запуска.
# ==============================================================================

PM_FILE="/usr/share/perl5/PVE/API2/Nodes.pm"
JS_FILE="/usr/share/pve-manager/js/pvemanagerlib.js"
NAG_FILE="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
CONFIG_FILE="/etc/pve-metrics.conf"
BK="/var/lib/pve-dashboard-backup"
TS=$(date +%Y%m%d-%H%M%S)

if [ "$EUID" -ne 0 ]; then
    echo "[ERROR] Запускать от root"
    exit 1
fi

# ==============================================================================
# 1. Проверка локальных зависимостей
# ==============================================================================
echo "[INFO] Проверка локальных зависимостей..."
MISSING=0
for cmd in jq python3 perl; do
    if ! command -v $cmd >/dev/null 2>&1; then
        echo "  -> [ОШИБКА] Не найден '$cmd'."
        MISSING=1
    fi
done
for cmd in sensors smartctl upsc; do
    if ! command -v $cmd >/dev/null 2>&1; then
        echo "  -> [ПРЕДУПРЕЖДЕНИЕ] Не найден '$cmd'."
    fi
done
for f in "$PM_FILE" "$JS_FILE"; do
    if [ ! -f "$f" ]; then
        echo "  -> [ОШИБКА] Не найден файл $f"
        MISSING=1
    fi
done
if [ $MISSING -eq 1 ]; then
    exit 1
fi

# ==============================================================================
# 2. Настройка (UPS и Web)
# ==============================================================================
echo "[INFO] Настройка параметров (нажмите Enter, чтобы оставить текущее значение)..."

if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

DEFAULT_HOST=${NUT_HOST:-"127.0.0.1"}
DEFAULT_NAME=${UPS_NAME:-"auto"}
DEFAULT_WEB=${WEB_ENABLE:-"yes"}
DEFAULT_PORT=${WEB_PORT:-"9098"}
DEFAULT_WEB_HOSTS=${WEB_HOSTS:-"proxmox.local proxmox2"}

read -p "NUT Host [$DEFAULT_HOST]: " nut_host
nut_host=${nut_host:-$DEFAULT_HOST}

read -p "UPS Name (или 'auto') [$DEFAULT_NAME]: " ups_name
ups_name=${ups_name:-$DEFAULT_NAME}

if [[ "$ups_name" == "auto" || "$ups_name" == "автоопределение" ]]; then
    RESOLVED_NAME=$(HOME=/tmp upsc -l "$nut_host" 2>/dev/null | grep -v "Init SSL" | head -n1)
    if [[ -n "$RESOLVED_NAME" ]]; then ups_name="$RESOLVED_NAME"; fi
fi

read -p "Запускать веб-сервис? (yes/no) [$DEFAULT_WEB]: " web_enable
web_enable=${web_enable:-$DEFAULT_WEB}

if [[ "$web_enable" == "yes" ]]; then
    read -p "Порт веб-сервиса [$DEFAULT_PORT]: " web_port
    web_port=${web_port:-$DEFAULT_PORT}

    read -p "Удаленные хосты (через пробел) [$DEFAULT_WEB_HOSTS]: " web_hosts
    web_hosts=${web_hosts:-$DEFAULT_WEB_HOSTS}
else
    web_port=${DEFAULT_PORT}
    web_hosts=${DEFAULT_WEB_HOSTS}
fi

cat << EOF_CONF > "$CONFIG_FILE"
NUT_HOST="$nut_host"
UPS_NAME="$ups_name"
WEB_ENABLE="$web_enable"
WEB_PORT="$web_port"
WEB_HOSTS="$web_hosts"
EOF_CONF
chmod 644 "$CONFIG_FILE"

# ==============================================================================
# 3. collect-hw-metrics.sh (диски + CPU + UPS -> один JSON, собирается через jq)
# ==============================================================================
echo "[INFO] Создаем collect-hw-metrics.sh..."
cat << 'EOF_COLLECT' > /usr/local/bin/collect-hw-metrics.sh
#!/bin/bash
# COLLECTOR_VERSION=3
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
TMP_FILE="/var/cache/pve-metrics.json.tmp"
OUT_FILE="/var/cache/pve-metrics.json"

NUT_HOST="127.0.0.1"
UPS_NAME="auto"
[ -f /etc/pve-metrics.conf ] && source /etc/pve-metrics.conf

# CPU
cpu_temp=""
if command -v sensors >/dev/null 2>&1; then
    cpu_temp=$(sensors 2>/dev/null | grep -E "Package id 0:|Tctl:" | head -n1 | sed 's/.*: *+//' | awk '{print $1}' | sed 's/[^0-9.].*$//')
fi

# UPS
ups_line=""
if command -v upsc >/dev/null 2>&1; then
    u_name="$UPS_NAME"
    if [[ "$u_name" == "auto" || "$u_name" == "автоопределение" ]]; then
        u_name=$(HOME=/tmp timeout 5 upsc -l "$NUT_HOST" 2>/dev/null | grep -v "Init SSL" | head -n1)
    fi
    if [[ -n "$u_name" ]]; then
        ups_get() { HOME=/tmp timeout 5 upsc "${u_name}@${NUT_HOST}" "$1" 2>/dev/null | grep -v "Init SSL"; }
        u_status=$(ups_get ups.status)
        if [ -n "$u_status" ]; then
            u_charge=$(ups_get battery.charge)
            u_load=$(ups_get ups.load)
            u_runtime=$(ups_get battery.runtime)
            u_test=$(ups_get ups.test.result)
            u_temp=$(ups_get battery.temperature)
            ups_line="Status: $u_status | Charge: ${u_charge}%"
            if [[ "$u_runtime" =~ ^[0-9]+$ ]]; then ups_line+=" | Time left: $((u_runtime / 60))m"; fi
            if [ -n "$u_temp" ]; then ups_line+=" | Temp: ${u_temp}C"; fi
            ups_line+=" | Load: ${u_load}%"
            if [ "$u_test" = "Done and passed" ]; then ups_line+=" | Self-Test: OK"
            elif [ -n "$u_test" ]; then ups_line+=" | Self-Test: $u_test"; fi
        fi
    fi
fi

# Заполненность диска, % (пусто, если определить нельзя).
# Обычные разделы: как df, занято / (занято + доступно).
# Если на диске есть LVM: (данные в смонтированных ФС + реально занятое место
# thin-пулов) / размер диска. ФС на thin-томах отдельно не считаются, они уже в пуле.
disk_use() {
    local dev="/dev/$1" size_b name type mp u a vg lv attr lsize pct esc denom
    local used=0 cap=0 found=0 has_lvm=0
    local -A seen=() thin=() pool=()
    size_b=$(lsblk -dnbo SIZE "$dev" 2>/dev/null | head -n1)
    [[ "$size_b" =~ ^[0-9]+$ ]] || return 0

    if command -v lvs >/dev/null 2>&1; then
        while IFS='|' read -r vg lv attr lsize pct; do
            vg=${vg//[[:space:]]/}; lv=${lv//[[:space:]]/}; attr=${attr//[[:space:]]/}
            esc="${vg//-/--}-${lv//-/--}"      # так имя LV выглядит в lsblk
            case "${attr:0:1}" in
                V) thin[$esc]=1 ;;
                t) pool[$esc]="${lsize//[[:space:]]/}|${pct//[[:space:]]/}" ;;
            esac
        done < <(LC_ALL=C timeout 10 lvs --noheadings --nosuffix --units b --separator '|' \
                    -o vg_name,lv_name,lv_attr,lv_size,data_percent 2>/dev/null)
    fi

    while read -r name type mp; do
        [[ -n "$name" && -z "${seen[$name]:-}" ]] || continue
        seen[$name]=1
        [[ "$type" == lvm ]] && has_lvm=1
        [[ "$mp" == /* && -z "${thin[$name]:-}" ]] || continue
        mp=$(printf '%b' "$mp")
        u=""; a=""
        read -r u a < <(timeout 3 df -B1 --output=used,avail "$mp" 2>/dev/null | tail -n1)
        [[ "$u" =~ ^[0-9]+$ && "$a" =~ ^[0-9]+$ ]] || continue
        used=$((used + u)); cap=$((cap + u + a)); found=1
    done < <(lsblk -nr -o NAME,TYPE,MOUNTPOINT "$dev" 2>/dev/null)

    for esc in "${!pool[@]}"; do
        [[ -n "${seen[${esc}_tdata]:-}" ]] || continue
        lsize=${pool[$esc]%%|*}; pct=${pool[$esc]#*|}
        [[ "$pct" =~ ^[0-9.]+$ ]] || continue
        used=$((used + $(awk -v s="$lsize" -v p="$pct" 'BEGIN{printf "%.0f", s*p/100}')))
        found=1; has_lvm=1
    done

    if (( has_lvm )); then denom=$size_b; else denom=$cap; fi
    (( found && denom > 0 )) || return 0
    awk -v u="$used" -v d="$denom" 'BEGIN{x=u*100/d; i=int(x); if (x>i) i++; if (i>100) i=100; print i}'
}

# Диски
DISKS=()
for dev_name in $(lsblk -d -n -o NAME,TYPE | awk '$2=="disk"{print $1}' | sort); do
    dev="/dev/$dev_name"
    smart_out=$(smartctl -H -A "$dev" 2>/dev/null)
    info_out=$(smartctl -i "$dev" 2>/dev/null)
    [ -z "$info_out" ] && continue
    use=$(disk_use "$dev_name")

    if [[ "$dev_name" == nvme* ]]; then
        model=$(echo "$info_out" | grep -E "Model Number:" | awk -F': ' '{print $2}' | xargs)
        [[ ${#model} -gt 20 ]] && model="${model:0:17}..."
        size=$(echo "$info_out" | grep "Namespace 1 Size/Capacity:" | awk -F'[' '{print $2}' | sed 's/]//g' | awk '{print $1$2}')
        [[ -z "$size" ]] && size=$(echo "$info_out" | grep "Total NVM Capacity:" | awk -F'[' '{print $2}' | sed 's/]//g' | awk '{print $1$2}')
        temp=$(echo "$smart_out" | awk -F': ' '/^Temperature:/{print $2}' | awk '{print $1}' | tr -dc '0-9')
        hours=$(echo "$smart_out" | grep "Power On Hours:" | awk -F': ' '{print $2}' | tr -dc '0-9')
        media_err=$(echo "$smart_out" | grep "Media and Data Integrity Errors:" | awk -F': ' '{print $2}' | tr -dc '0-9')
        if [[ -z "$hours" || "$hours" -gt 300000 ]]; then years="?"; else years=$(awk "BEGIN {printf \"%.1f\", $hours / 8760}"); fi
        crit=$(echo "$smart_out" | grep "Critical Warning:" | awk -F': ' '{print $2}' | xargs)
        if [[ -n "$crit" && "$crit" != "0x00" && "$crit" != "0x0000" ]]; then status="FAIL";
        elif [[ "${media_err:-0}" -gt 0 ]]; then status="BAD!";
        elif [[ "${temp:-0}" -gt 70 ]]; then status="HOT!";
        else status="ОК"; fi
        DISKS+=("$(jq -nc --arg name "$dev_name" --arg model "$model" --arg size "$size" \
            --arg temp "$temp" --arg years "$years" --arg media_err "$media_err" \
            --arg status "$status" --arg use "$use" '$ARGS.named')")
    else
        model=$(echo "$info_out" | grep "Device Model:" | awk -F': ' '{print $2}' | xargs)
        [ -z "$model" ] && model=$(echo "$info_out" | grep -E "Vendor|Product" | awk -F': ' '{print $2}' | xargs | tr ' ' '_')
        [[ ${#model} -gt 20 ]] && model="${model:0:17}..."
        size=$(echo "$info_out" | grep "User Capacity:" | awk -F'[' '{print $2}' | sed 's/]//g' | awk '{print $1$2}')
        temp=$(echo "$smart_out" | grep "Temperature_Celsius" | awk '{print $10}' | head -n1 | tr -dc '0-9')
        hours=$(echo "$smart_out" | grep "Power_On_Hours" | awk '{print $10}' | awk -F'[h.m]' '{print $1}' | tr -dc '0-9')
        realloc=$(echo "$smart_out" | grep "Reallocated_Sector_Ct" | awk '{print $10}' | head -n1 | tr -dc '0-9')
        pending=$(echo "$smart_out" | grep "Current_Pending_Sector" | awk '{print $10}' | head -n1 | tr -dc '0-9')
        crc=$(echo "$smart_out" | grep "UDMA_CRC_Error_Count" | awk '{print $10}' | head -n1 | tr -dc '0-9')
        starts=$(echo "$smart_out" | grep "Start_Stop_Count" | awk '{print $10}' | head -n1 | tr -dc '0-9')
        if [[ -n "$hours" && "$hours" -gt 0 ]]; then
            cutoff=$(( hours - 120 )); [[ $cutoff -lt 0 ]] && cutoff=0
            fresh_err=$(smartctl -l error "$dev" 2>/dev/null | grep "lifetime:" | sed -E 's/.*lifetime:[[:space:]]*([0-9]+).*/\1/' | awk -v cut="$cutoff" '$1 >= cut' | wc -l)
        else fresh_err=0; fi
        if [[ -z "$hours" || "$hours" -gt 300000 ]]; then years="?"; else years=$(awk "BEGIN {printf \"%.1f\", $hours / 8760}"); fi
        health=$(echo "$smart_out" | grep "test result" | awk '{print $6}')
        if [[ "$health" != "PASSED" && -n "$health" ]]; then status="FAIL";
        elif [[ "${pending:-0}" -gt 0 ]]; then status="BAD!";
        elif [[ "${realloc:-0}" -gt 5 ]]; then status="WARN";
        elif [[ "${crc:-0}" -gt 0 ]]; then status="CABLE";
        elif [[ "${temp:-0}" -gt 45 ]]; then status="HOT!";
        else status="ОК"; fi
        DISKS+=("$(jq -nc --arg name "$dev_name" --arg model "$model" --arg size "$size" \
            --arg temp "$temp" --arg years "$years" --arg realloc "$realloc" --arg crc "$crc" \
            --arg fresh_err "$fresh_err" --arg starts "$starts" --arg status "$status" --arg use "$use" '$ARGS.named')")
    fi
done

disks_json=$(printf '%s\n' "${DISKS[@]}" | jq -sc '.')
if jq -nc --arg cpu "$cpu_temp" --arg ups "$ups_line" --argjson disks "$disks_json" \
        '{cpu: $cpu, ups: $ups, disks: $disks}' > "$TMP_FILE"; then
    mv "$TMP_FILE" "$OUT_FILE"
    chmod 644 "$OUT_FILE"
else
    rm -f "$TMP_FILE"
    exit 1
fi
EOF_COLLECT
chmod +x /usr/local/bin/collect-hw-metrics.sh

# ==============================================================================
# 4. hw-metrics.sh (только читает кэш, UPS берёт из него же)
# ==============================================================================
echo "[INFO] Создаем hw-metrics.sh..."
cat << 'EOF_HW' > /usr/local/bin/hw-metrics.sh
#!/bin/bash
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

for cmd in jq df; do
    if ! command -v $cmd >/dev/null 2>&1; then
        echo "=== [ERROR] Утилита '$cmd' не найдена на $(hostname). Установите её. ==="
        exit 1
    fi
done

CACHE_FILE="/var/cache/pve-metrics.json"

if [ ! -f "$CACHE_FILE" ]; then
    echo "=== Ожидание сбора данных ==="
    exit 1
fi

file_time=$(stat -c %Y "$CACHE_FILE")
now=$(date +%s)
age=$((now - file_time))

if [ $age -gt 60 ]; then
    /usr/local/bin/collect-hw-metrics.sh >/dev/null 2>&1 &
    echo -e "=== (Данные устарели, обновление запущено в фоне...) ===\n"
fi

echo -e "=== СТАТУС СИСТЕМЫ $(hostname -f) на $(date '+%d.%m.%Y %H:%M') ==="
echo ""

cpu_temp=$(jq -r '.cpu | select(. != null) // empty' "$CACHE_FILE")
if [[ -n "$cpu_temp" ]]; then echo "CPU: ${cpu_temp}°C"; fi

ups_line=$(jq -r '.ups // empty' "$CACHE_FILE")
if [[ -n "$ups_line" ]]; then echo "UPS: $ups_line"; fi
echo ""

if jq -e '.disks[] | select(.name | startswith("nvme"))' "$CACHE_FILE" >/dev/null 2>&1; then
    fmt_nvme="%-7s | %-20s | %-7s | %-5s | %-5s | %-4s | %-3s | %s\n"
    printf "$fmt_nvme" "Диск   " "Модель              " "Объем  " "Use% " "Темп" "Лет " "Err" "Статус"
    echo   "-----------------------------------------------------------------------------------------------"
    jq -r '.disks[] | select(.name | startswith("nvme")) | [.name, .model, .size, .use, .temp, .years, .media_err, .status] | map(. // "") | join("\u001f")' "$CACHE_FILE" | while IFS=$'\x1f' read -r name model size use temp years media_err status; do
        use_pct="-"; [[ -n "$use" ]] && use_pct="${use}%"
        printf "$fmt_nvme" "$name" "${model:-Unknown}" "${size:-?}" "$use_pct" "${temp:-0}°C" "${years:-0}" "${media_err:-0}" "$status"
    done
    echo   "-----------------------------------------------------------------------------------------------"
fi

if jq -e '.disks[] | select(.name | startswith("sd"))' "$CACHE_FILE" >/dev/null 2>&1; then
    fmt="%-4s | %-20s | %-7s | %-5s | %-5s | %-4s | %-3s | %-3s | %-3s | %-6s | %s\n"
    printf "$fmt" "Диск" "Модель              " "Объем  " "Use% " "Темп" "Лет " "Bad" "CRC" "Err" "Циклы " "Статус"
    echo   "-----------------------------------------------------------------------------------------------"
    jq -r '.disks[] | select(.name | startswith("sd")) | [.name, .model, .size, .use, .temp, .years, .realloc, .crc, .fresh_err, .starts, .status] | map(. // "") | join("\u001f")' "$CACHE_FILE" | while IFS=$'\x1f' read -r name model size use temp years realloc crc fresh_err starts status; do
        use_pct="-"; [[ -n "$use" ]] && use_pct="${use}%"
        printf "$fmt" "$name" "${model:-Unknown}" "${size:-?}" "$use_pct" "${temp:-0}°C" "${years:-0}" "${realloc:-0}" "${crc:-0}" "${fresh_err:-0}" "${starts:--}" "$status"
    done
    echo   "-----------------------------------------------------------------------------------------------"
fi

DF_OUT=$(timeout 3 df -h)
if [[ -n "$DF_OUT" ]]; then
    echo "$DF_OUT" | grep Filesystem
    echo "$DF_OUT" | grep pve | grep -v fuse | grep -v '^[1-9]' | sort -k6
    echo "$DF_OUT" | grep pve | grep -v fuse | grep    '^[1-9]' | sort
fi
echo   "-----------------------------------------------------------------------------------------------"
exit 0
EOF_HW
chmod +x /usr/local/bin/hw-metrics.sh

# ==============================================================================
# 5. Python-сервер hw-metrics-web.py
# ==============================================================================
if [[ "$web_enable" == "yes" ]]; then
    echo "[INFO] Создаем hw-metrics-web.py..."
    cat << 'EOF_WEB' > /usr/local/bin/hw-metrics-web.py
#!/usr/bin/env python3
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import subprocess
import concurrent.futures
import html
import os

CONFIG_FILE = "/etc/pve-metrics.conf"
PORT = 9098
REMOTE_HOSTS = []

if os.path.exists(CONFIG_FILE):
    with open(CONFIG_FILE) as f:
        for line in f:
            if line.startswith("WEB_PORT="):
                PORT = int(line.split("=", 1)[1].strip().strip('"'))
            elif line.startswith("WEB_HOSTS="):
                REMOTE_HOSTS = line.split("=", 1)[1].strip().strip('"').split()

def get_file_content(path):
    try:
        with open(path, 'r') as f:
            return f.read()
    except Exception as e:
        return f"echo 'Error reading {path}: {e}'; exit 1"

def run_local():
    try:
        result = subprocess.run(['/bin/bash', '/usr/local/bin/hw-metrics.sh'], capture_output=True, text=True, timeout=15)
        return result.stdout
    except Exception as e:
        return f"[ERROR LOCAL] {e}"

def run_remote(host, hw_script, collect_script, service_script, timer_script, config_data):
    try:
        # Коллектор нужной версии и свежий кэш на месте?
        check_cache = subprocess.run(
            ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=3", f"root@{host}",
             "test -f /var/cache/pve-metrics.json && grep -q 'COLLECTOR_VERSION=3' /usr/local/bin/collect-hw-metrics.sh"],
            capture_output=True, timeout=8
        )

        if check_cache.returncode != 0:
            provision_script = f"""#!/bin/bash
cat > /etc/pve-metrics.conf << 'EOF_CONFIG'
{config_data}
EOF_CONFIG
chmod 644 /etc/pve-metrics.conf

cat > /usr/local/bin/collect-hw-metrics.sh << 'EOF_COLLECT'
{collect_script}
EOF_COLLECT

cat > /etc/systemd/system/pve-metrics.service << 'EOF_SERVICE'
{service_script}
EOF_SERVICE

cat > /etc/systemd/system/pve-metrics.timer << 'EOF_TIMER'
{timer_script}
EOF_TIMER

chmod +x /usr/local/bin/collect-hw-metrics.sh
systemctl daemon-reload
systemctl enable --now pve-metrics.timer
/usr/local/bin/collect-hw-metrics.sh
"""
            install_res = subprocess.run(
                ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=3", f"root@{host}", "bash -s"],
                input=provision_script, capture_output=True, text=True, timeout=20
            )
            if install_res.returncode != 0:
                return f"[ERROR] Не удалось развернуть коллектор на {host}.\nSTDERR: {install_res.stderr}"

            return f"[WARN] На хосте {host} не было кэша метрик или коллектор устарел.\nКоллектор и systemd таймер установлены/обновлены.\nПожалуйста, обновите страницу через 10-15 секунд."

        else:
            result = subprocess.run(
                ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=3", f"root@{host}", "bash -s"],
                input=hw_script, capture_output=True, text=True, timeout=15
            )
            if result.returncode != 0:
                return f"[ERROR SSH] Код {result.returncode}\nSTDOUT: {result.stdout}\nSTDERR: {result.stderr}"
            return result.stdout

    except subprocess.TimeoutExpired:
        return f"[ERROR SSH] Таймаут подключения к {host}"
    except Exception as e:
        return f"[ERROR SSH] {e}"

class ScriptHandler(BaseHTTPRequestHandler):
    timeout = 10  # пустое соединение (предзагрузка Chrome) закрывается через 10 с

    def do_GET(self):
        if self.path.split('?')[0] != '/':
            self.send_error(404)  # /favicon.ico и прочее не должны запускать опрос хостов
            return
        hw_script = get_file_content("/usr/local/bin/hw-metrics.sh")
        collect_script = get_file_content("/usr/local/bin/collect-hw-metrics.sh")
        service_script = get_file_content("/etc/systemd/system/pve-metrics.service")
        timer_script = get_file_content("/etc/systemd/system/pve-metrics.timer")

        config_data = ""
        if os.path.exists(CONFIG_FILE):
            with open(CONFIG_FILE) as f:
                config_data = f.read()

        tasks = [("local", run_local)]
        for host in REMOTE_HOSTS:
            tasks.append((host, lambda h=host: run_remote(h, hw_script, collect_script, service_script, timer_script, config_data)))

        results = {}
        with concurrent.futures.ThreadPoolExecutor(max_workers=len(tasks)) as executor:
            future_to_name = {executor.submit(fn): name for name, fn in tasks}
            for future in concurrent.futures.as_completed(future_to_name):
                name = future_to_name[future]
                try:
                    results[name] = future.result()
                except Exception as e:
                    results[name] = f"[ERROR FUTURE] {e}"

        output = results.get("local") or ""
        for host in REMOTE_HOSTS:
            remote = results.get(host)
            if remote:
                output += "\n" + remote

        self.send_response(200)
        self.send_header('Content-type', 'text/html; charset=utf-8')
        self.end_headers()

        page = f"""
        <html>
        <head><title>Hardware Metrics</title>
        <link rel="icon" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'><rect width='32' height='32' rx='6' fill='%23121212'/><path d='M3 17h7l3-9 6 17 3-8h7' fill='none' stroke='%2300FF66' stroke-width='2.5' stroke-linecap='round' stroke-linejoin='round'/></svg>">
        </head>
        <body style="background: #121212; color: #00FF66; font-family: monospace; padding: 20px; font-size: 14px;">
        <pre>{html.escape(output)}</pre>
        </body>
        </html>
        """
        self.wfile.write(page.encode('utf-8'))

if __name__ == '__main__':
    server = ThreadingHTTPServer(('0.0.0.0', PORT), ScriptHandler)
    server.serve_forever()
EOF_WEB
    chmod +x /usr/local/bin/hw-metrics-web.py

    echo "[INFO] Настраиваем systemd сервис для веб-сервера..."
    cat << 'EOF_SVC' > /etc/systemd/system/hw-metrics-web.service
[Unit]
Description=Hardware Metrics Web API
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/hw-metrics-web.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF_SVC
    systemctl daemon-reload
    systemctl enable hw-metrics-web.service
    systemctl restart hw-metrics-web.service
fi

# ==============================================================================
# 6. Systemd Timer для сборщика
# ==============================================================================
echo "[INFO] Настраиваем systemd timer (5 минут)..."
cat << 'EOF_UNIT' > /etc/systemd/system/pve-metrics.service
[Unit]
Description=Collect PVE Custom Metrics
[Service]
Type=oneshot
ExecStart=/usr/local/bin/collect-hw-metrics.sh
EOF_UNIT
cat << 'EOF_TIMER' > /etc/systemd/system/pve-metrics.timer
[Unit]
Description=Run PVE Custom Metrics Collector every 5 min
[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
[Install]
WantedBy=timers.target
EOF_TIMER
systemctl daemon-reload
systemctl enable --now pve-metrics.timer

echo "[INFO] Первый сбор метрик..."
/usr/local/bin/collect-hw-metrics.sh || echo "  -> [ПРЕДУПРЕЖДЕНИЕ] Коллектор завершился с ошибкой, проверь вручную."

# ==============================================================================
# 7. Создание uninstall-pve-metrics.sh (до патчинга, чтобы он был даже при аварийном откате)
# ==============================================================================
echo "[INFO] Создаем uninstall-pve-metrics.sh..."
cat << 'EOF_UNINSTALL' > /usr/local/bin/uninstall-pve-metrics.sh
#!/bin/bash

# ==============================================================================
# PVE Custom Metrics Uninstaller v2
# Вырезает наши блоки из Nodes.pm и pvemanagerlib.js по маркерам
# (BEGIN/END pve_custom_metrics), понимает и старый патч v1 без маркеров.
# От старых бэкапов не зависит, работает после любого обновления PVE.
# Аварийный вариант: apt-get install --reinstall pve-manager proxmox-widget-toolkit
# ==============================================================================

PM_FILE="/usr/share/perl5/PVE/API2/Nodes.pm"
JS_FILE="/usr/share/pve-manager/js/pvemanagerlib.js"
NAG_FILE="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
BK="/var/lib/pve-dashboard-backup"
TS=$(date +%Y%m%d-%H%M%S)

if [ "$EUID" -ne 0 ]; then
    echo "[ERROR] Запускать от root"
    exit 1
fi

# Удаленные хосты читаем до удаления конфига
REMOTE_HOSTS=""
[ -f /etc/pve-metrics.conf ] && source /etc/pve-metrics.conf && REMOTE_HOSTS="$WEB_HOSTS"

echo "[INFO] Останавливаем и удаляем сервисы..."
systemctl disable --now pve-metrics.timer hw-metrics-web.service 2>/dev/null
systemctl stop pve-metrics.service 2>/dev/null
rm -f /etc/systemd/system/pve-metrics.service \
      /etc/systemd/system/pve-metrics.timer \
      /etc/systemd/system/hw-metrics-web.service
systemctl daemon-reload

echo "[INFO] Вырезаем наши патчи из файлов Proxmox..."
mkdir -p "$BK"
STRIPPER=$(mktemp)
cat << 'EOF_PY' > "$STRIPPER"
import re, sys
kind, path = sys.argv[1:3]
src = open(path, encoding='utf-8').read()
old = src
if kind == 'pm':
    src = re.sub(r'[ \t]*# BEGIN pve_custom_metrics.*?# END pve_custom_metrics[ \t]*\n', '', src, flags=re.S)
    src = re.sub(r'[ \t]*# pve_custom_metrics\b.*?\n[ \t]*\}\n', '', src, count=1, flags=re.S)
else:
    src = re.sub(r'\n?[ \t]*/\* BEGIN pve_custom_metrics \*/.*?/\* END pve_custom_metrics \*/', '', src, flags=re.S)
    src = re.sub(r"(minHeight:\s*)\d+ /\* pve_custom_metrics_h:(\d+) \*/", r"\g<1>\2", src)
    legacy = re.compile(r"[ \t]*\{\s*itemId:\s*'pve_custom_metrics',.*?\n[ \t]{8}\},\n", re.S)
    if legacy.search(src):
        src = legacy.sub('', src, count=1)
        src = re.sub(r"(Ext\.define\('PVE\.node\.StatusView'.*?minHeight:\s*)415\b", r"\g<1>360", src, count=1, flags=re.S)
if src == old:
    print("  -> %s: наших патчей не найдено, пропускаю" % path)
    sys.exit(3)
open(path, 'w', encoding='utf-8').write(src)
print("  -> %s: патч вырезан" % path)
EOF_PY

FAILED=0
for pair in "pm:$PM_FILE" "js:$JS_FILE"; do
    kind="${pair%%:*}"; f="${pair#*:}"
    cp -p "$f" "$BK/$(basename "$f").before-uninstall.$TS.bak"
    python3 "$STRIPPER" "$kind" "$f"
    rc=$?
    if [ $rc -ne 0 ] && [ $rc -ne 3 ]; then
        echo "  -> [ОШИБКА] не удалось обработать $f, возвращаю как было"
        cp -p "$BK/$(basename "$f").before-uninstall.$TS.bak" "$f"
        FAILED=1
    fi
done
rm -f "$STRIPPER"

if ! PERL_OUT=$(perl -c "$PM_FILE" 2>&1); then
    echo "[ОШИБКА] Nodes.pm не прошёл perl -c после отката:"
    echo "$PERL_OUT" | tail -n 5
    echo "  Верни файл из $BK/Nodes.pm.before-uninstall.$TS.bak или выполни:"
    echo "  apt-get install --reinstall pve-manager"
    FAILED=1
fi

echo "[INFO] Возвращаем nag screen..."
if [ -f "$NAG_FILE" ] && grep -qF 'checked_command: function (orig_cmd) { orig_cmd(); return;' "$NAG_FILE"; then
    sed -i 's/checked_command: function (orig_cmd) { orig_cmd(); return;/checked_command: function (orig_cmd) {/' "$NAG_FILE"
    echo "  -> proxmoxlib.js восстановлен."
else
    echo "  -> nag-патча нет, пропускаю."
fi

echo "[INFO] Удаляем наши скрипты и кэш..."
rm -f /usr/local/bin/collect-hw-metrics.sh \
      /usr/local/bin/hw-metrics.sh \
      /usr/local/bin/hw-metrics-web.py \
      /etc/pve-metrics.conf \
      /var/cache/pve-metrics.json \
      /var/cache/pve-metrics.json.tmp

if [ -n "$REMOTE_HOSTS" ]; then
    read -p "Удалить коллектор и таймер на удаленных хостах ($REMOTE_HOSTS)? (yes/no) [no]: " rm_remote
    if [[ "$rm_remote" == "yes" ]]; then
        for h in $REMOTE_HOSTS; do
            echo "  -> $h"
            ssh -o BatchMode=yes -o ConnectTimeout=3 "root@$h" \
                'systemctl disable --now pve-metrics.timer 2>/dev/null; rm -f /etc/systemd/system/pve-metrics.service /etc/systemd/system/pve-metrics.timer /usr/local/bin/collect-hw-metrics.sh /etc/pve-metrics.conf /var/cache/pve-metrics.json; systemctl daemon-reload' \
                || echo "     [ПРЕДУПРЕЖДЕНИЕ] не удалось подключиться к $h"
        done
    fi
fi

echo "[INFO] Перезапускаем pvedaemon и pveproxy..."
systemctl restart pvedaemon pveproxy

echo "========================================================================"
if [ $FAILED -eq 0 ]; then
    echo "[ ОКИ-ДОКИ! ] Откат завершен, наши патчи вырезаны."
else
    echo "[ ВНИМАНИЕ ] Откат завершен с ошибками, смотри сообщения выше."
fi
echo "Не забудь нажать Ctrl+F5 в браузере!"
echo "========================================================================"
exit $FAILED
EOF_UNINSTALL
chmod +x /usr/local/bin/uninstall-pve-metrics.sh

# ==============================================================================
# 8. Патчинг Nodes.pm и pvemanagerlib.js (маркеры + бэкап + автооткат)
# ==============================================================================
mkdir -p "$BK"

backup() {  # $1 = файл; копия с датой, хранятся 5 последних
    local name; name=$(basename "$1")
    cp -p "$1" "$BK/$name.$TS.bak" || return 1
    ls -1t "$BK/$name".*.bak 2>/dev/null | tail -n +6 | xargs -r rm -f
}
restore() { cp -p "$BK/$(basename "$1").$TS.bak" "$1"; }

abort_restore() {
    echo "[ERROR] $1" >&2
    echo "[INFO] Возвращаем Nodes.pm и pvemanagerlib.js в состояние до этого запуска..." >&2
    restore "$PM_FILE"
    restore "$JS_FILE"
    rm -f "$PATCHER" "$BLOCK_PM" "$BLOCK_JS"
    echo "[INFO] Откат выполнен. Сервисы метрик остались установленными, веб-виджет не изменён." >&2
    exit 1
}

backup "$PM_FILE" && backup "$JS_FILE" || { echo "[ERROR] Не удалось сделать бэкап, патчи не применяю."; exit 1; }
echo "[INFO] Бэкапы: $BK/*.$TS.bak"

PATCHER=$(mktemp); BLOCK_PM=$(mktemp); BLOCK_JS=$(mktemp)

cat << 'EOF_PY' > "$PATCHER"
import re, sys

kind, path, blockfile = sys.argv[1:4]
src = open(path, encoding='utf-8').read()
block = open(blockfile, encoding='utf-8').read()

def fail(msg):
    sys.stderr.write("  -> " + msg + "\n")
    sys.exit(2)

# Блок должен быть сам по себе сбалансирован (защита от опечаток в патче)
for o, c in ('{}', '()', '[]'):
    if block.count(o) != block.count(c):
        fail("внутренняя ошибка: в патче не сходятся %s%s" % (o, c))

if kind == 'pm':
    # 1) наш блок с маркерами (вместе с хвостовым переводом строки)
    src = re.sub(r'[ \t]*# BEGIN pve_custom_metrics.*?# END pve_custom_metrics[ \t]*\n', '', src, flags=re.S)
    # 2) старый патч v1 без маркеров
    src = re.sub(r'[ \t]*# pve_custom_metrics\b.*?\n[ \t]*\}\n', '', src, count=1, flags=re.S)
    m = re.search(r"^[ \t]*my \$dinfo = df\('/', 1\);", src, flags=re.M)
    if not m:
        fail("Nodes.pm: не найден якорь \"my $dinfo = df('/', 1);\" (изменилась версия PVE?)")
    if not block.endswith('\n'):
        block += '\n'
    src = src[:m.start()] + block + src[m.start():]

elif kind == 'js':
    # 1) наш блок (вместе с ведущим переводом строки)
    src = re.sub(r'\n?[ \t]*/\* BEGIN pve_custom_metrics \*/.*?/\* END pve_custom_metrics \*/', '', src, flags=re.S)
    # 2) возврат высоты, если мы её меняли
    src = re.sub(r"(minHeight:\s*)\d+ /\* pve_custom_metrics_h:(\d+) \*/", r"\g<1>\2", src)
    # 3) старый патч v1 без маркеров: виджет + высота 415 -> 360
    legacy = re.compile(r"[ \t]*\{\s*itemId:\s*'pve_custom_metrics',.*?\n[ \t]{8}\},\n", re.S)
    if legacy.search(src):
        src = legacy.sub('', src, count=1)
        src = re.sub(r"(Ext\.define\('PVE\.node\.StatusView'.*?minHeight:\s*)415\b", r"\g<1>360", src, count=1, flags=re.S)
        sys.stderr.write("  -> найден и убран старый патч v1 (без маркеров)\n")
    # высота панели статуса: поднимаем до 415, запоминая исходное значение
    m = re.search(r"(Ext\.define\('PVE\.node\.StatusView'.*?minHeight:\s*)(\d+)", src, flags=re.S)
    if m:
        if int(m.group(2)) < 415:
            src = src[:m.start(2)] + "415 /* pve_custom_metrics_h:%s */" % m.group(2) + src[m.end(2):]
    else:
        sys.stderr.write("  -> [ПРЕДУПРЕЖДЕНИЕ] minHeight у PVE.node.StatusView не найден, высоту не меняю\n")
    # виджет после элемента 'version'
    m = re.search(r"\{\s*itemId:\s*'version',.*?textField:\s*'pveversion',.*?\},", src, flags=re.S)
    if not m:
        fail("pvemanagerlib.js: не найден элемент itemId:'version' / textField:'pveversion' (изменилась версия PVE?)")
    src = src[:m.end()] + "\n" + block.rstrip('\n') + src[m.end():]
else:
    fail("неизвестный тип " + kind)

open(path, 'w', encoding='utf-8').write(src)
EOF_PY

# --- Nodes.pm ---------------------------------------------------------------
echo "[INFO] Патчим Nodes.pm..."
cat << 'EOF_BLOCK' > "$BLOCK_PM"
        # BEGIN pve_custom_metrics
        if (open(my $pvm_fh, '<', '/var/cache/pve-metrics.json')) {
            local $/;
            my $pvm_json = <$pvm_fh>;
            close($pvm_fh);
            if (defined $pvm_json) {
                # файл читается байтами, а JSON-кодировщик PVE ждёт символы:
                # без decode кириллица (статус "ОК") уходит в браузер двойным UTF-8
                utf8::decode($pvm_json);
                $res->{custom_metrics} = $pvm_json;
            }
        }
        # END pve_custom_metrics
EOF_BLOCK
python3 "$PATCHER" pm "$PM_FILE" "$BLOCK_PM" || abort_restore "Не удалось пропатчить Nodes.pm"
if ! PERL_OUT=$(perl -c "$PM_FILE" 2>&1); then
    echo "$PERL_OUT" | tail -n 5 >&2
    abort_restore "Nodes.pm не прошёл perl -c"
fi
grep -q 'BEGIN pve_custom_metrics' "$PM_FILE" && grep -q 'END pve_custom_metrics' "$PM_FILE" \
    || abort_restore "В Nodes.pm после патча нет наших маркеров"

# --- pvemanagerlib.js -------------------------------------------------------
echo "[INFO] Патчим pvemanagerlib.js..."
cat << 'EOF_BLOCK' > "$BLOCK_JS"
        /* BEGIN pve_custom_metrics */
        {
            itemId: 'pve_custom_metrics',
            colspan: 2,
            printBar: false,
            title: gettext('Hardware Metrics'),
            textField: 'custom_metrics',
            minHeight: 60,
            margin: '0 0 0 0',
            renderer: function(v) {
                if (!v) return '';
                try {
                    var obj = JSON.parse(v);
                    var hl = function(txt, color) {
                        return '<span style="color:' + color + '; font-weight:bold">' + txt + '</span>';
                    };
                    var html = '<div style="font-family: monospace; font-size: 12px;">';
                    if (obj.cpu) {
                        // пороги CPU: >=80 оранжевый, >=90 красный
                        var c = parseFloat(obj.cpu);
                        var cs = 'CPU: ' + obj.cpu + '&deg;C';
                        if (c >= 90) cs = hl(cs, '#d32f2f'); else if (c >= 80) cs = hl(cs, '#e65100');
                        html += cs + '<br>';
                    }
                    if (obj.disks && obj.disks.length) {
                        // статус диска считает коллектор; 'OK' (лат.) и 'ОК' (кир.) = норма, всё остальное красным
                        var d = obj.disks.map(function(x) {
                            var t = x.name + ':' + x.temp + '&deg;C';
                            var ok = !x.status || x.status === 'OK' || x.status === '\u041e\u041a';
                            return ok ? t : hl(t + ' ' + x.status, '#d32f2f');
                        }).join(', ');
                        html += 'Disks: ' + d + '<br>';
                    }
                    if (obj.ups) {
                        // UPS не на сети (OB, LB и т.п.) красным
                        var us = 'UPS: ' + obj.ups;
                        html += /Status: OL/.test(obj.ups) ? us : hl(us, '#d32f2f');
                    }
                    html += '</div>';
                    return html;
                } catch (e) { return v; }
            }
        },
        /* END pve_custom_metrics */
EOF_BLOCK
python3 "$PATCHER" js "$JS_FILE" "$BLOCK_JS" || abort_restore "Не удалось пропатчить pvemanagerlib.js"
if command -v node >/dev/null 2>&1; then
    node --check "$JS_FILE" >/dev/null 2>&1 || abort_restore "pvemanagerlib.js не прошёл node --check"
else
    echo "  -> node не установлен, синтаксис JS проверить нечем (проверены только маркеры и баланс скобок в блоке)"
fi
grep -q 'BEGIN pve_custom_metrics' "$JS_FILE" && grep -q 'END pve_custom_metrics' "$JS_FILE" \
    || abort_restore "В pvemanagerlib.js после патча нет наших маркеров"

rm -f "$PATCHER" "$BLOCK_PM" "$BLOCK_JS"

# ==============================================================================
# 9. Nag Screen (необязательно: при неудаче только предупреждение, ничего не откатываем)
# ==============================================================================
echo "[INFO] Отключаем Nag Screen..."
NAG_ORIG='checked_command: function (orig_cmd) {'
NAG_DONE='checked_command: function (orig_cmd) { orig_cmd(); return;'
if [ ! -f "$NAG_FILE" ]; then
    echo "  -> [ПРЕДУПРЕЖДЕНИЕ] $NAG_FILE не найден, nag-патч пропущен."
elif grep -qF "$NAG_DONE" "$NAG_FILE"; then
    echo "  -> уже отключён."
elif grep -qF "$NAG_ORIG" "$NAG_FILE"; then
    backup "$NAG_FILE"
    sed -i "s/checked_command: function (orig_cmd) {/checked_command: function (orig_cmd) { orig_cmd(); return;/" "$NAG_FILE"
    if grep -qF "$NAG_DONE" "$NAG_FILE"; then
        echo "  -> применён."
    else
        restore "$NAG_FILE"
        echo "  -> [ПРЕДУПРЕЖДЕНИЕ] nag-патч не применился, файл возвращён как был."
    fi
else
    echo "  -> [ПРЕДУПРЕЖДЕНИЕ] Не найдено место для nag-патча в $NAG_FILE (версия изменилась?)."
    echo "     Остальные патчи установлены, на метрики это не влияет."
fi

# ==============================================================================
# 10. Завершение
# ==============================================================================
echo "[INFO] Перезапускаем pveproxy и pvedaemon..."
systemctl restart pvedaemon pveproxy

echo "========================================================================"
echo "[ ОКИ-ДОКИ! ] Установка завершена."
echo "Утилита: hw-metrics.sh"
if [[ "$web_enable" == "yes" ]]; then
    echo "Веб-интерфейс доступен на порту $web_port"
fi
echo "Откат: uninstall-pve-metrics.sh (лежит в /usr/local/bin, по маркерам, от бэкапов не зависит)"
echo "Не забудь нажать Ctrl+F5 в браузере!"
echo "========================================================================"
exit 0
