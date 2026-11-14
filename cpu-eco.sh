#!/bin/bash
# Профили питания CPU для драйвера amd-pstate-epp. Без аргументов показывает состояние.
# Использование: ./cpu-eco.sh [0|1|2|3|4 [МГц]] [--persist]   (запускать от root)
#   0  как сейчас по умолчанию: governor performance, EPP performance, boost вкл
#   1  powersave + EPP balance_performance, boost вкл   (с него и начни)
#   2  powersave + EPP balance_power, boost вкл
#   3  powersave + EPP balance_power, boost выкл        (частота не выше базовой)
#   4  powersave + EPP balance_performance, boost вкл, потолок частоты МГц (по умолчанию 4200):
#      промежуточный режим между 1 и 3, например: ./cpu-eco.sh 4 4000
# Без --persist действует до перезагрузки. С --persist ставит systemd-юнит cpu-eco.service,
# а "0 --persist" убирает юнит. Всё обратимо: достаточно вернуть режим 0.

SYS=${SYS:-/sys}; UNIT_DIR=${UNIT_DIR:-/etc/systemd/system}
CPU="$SYS/devices/system/cpu"

LEVEL=""; PERSIST=0; FREQ=""
for a in "$@"; do
    case "$a" in
        --persist) PERSIST=1 ;;
        [0-4]) LEVEL=$a ;;
        [0-9][0-9][0-9][0-9]) FREQ=$a ;;
        *) echo "неизвестный аргумент: $a (см. шапку скрипта)"; exit 1 ;;
    esac
done

status() {
    local p="$CPU/cpu0/cpufreq"
    echo "драйвер : $(cat "$p/scaling_driver" 2>/dev/null || echo ?)"
    echo "governor: $(cat "$p/scaling_governor" 2>/dev/null || echo ?)"
    echo "EPP     : $(cat "$p/energy_performance_preference" 2>/dev/null || echo недоступен)" \
         "(варианты: $(cat "$p/energy_performance_available_preferences" 2>/dev/null || echo -))"
    echo "boost   : $(cat "$CPU/cpufreq/boost" 2>/dev/null || echo недоступен)"
    echo "макс. частота политики: $(( $(cat "$p/scaling_max_freq" 2>/dev/null || echo 0) / 1000 )) МГц"
    if [ -f "$UNIT_DIR/cpu-eco.service" ]; then
        echo "автозапуск: $(sed -n 's/^ExecStart=//p' "$UNIT_DIR/cpu-eco.service")"
    else
        echo "автозапуск: нет (после перезагрузки вернётся режим 0)"
    fi
}

apply() {  # governor epp boost [макс. МГц; пусто = без потолка]
    local p bad=0
    for p in "$CPU"/cpu[0-9]*/cpufreq; do
        echo "$1" > "$p/scaling_governor" 2>/dev/null || bad=1
        if [ -n "$4" ]; then echo $(( $4 * 1000 )) > "$p/scaling_max_freq" 2>/dev/null || echo "[ПРЕДУПРЕЖДЕНИЕ] потолок $4 МГц не выставился" >&2
        elif [ -r "$p/cpuinfo_max_freq" ]; then cat "$p/cpuinfo_max_freq" > "$p/scaling_max_freq" 2>/dev/null; fi
        # EPP меняется только после смены governor; если драйвер его не поддерживает, пропускаем
        [ -e "$p/energy_performance_preference" ] && { echo "$2" > "$p/energy_performance_preference" 2>/dev/null || true; }
    done
    [ $bad -eq 1 ] && echo "[ПРЕДУПРЕЖДЕНИЕ] governor $1 выставился не везде" >&2
    if [ -e "$CPU/cpufreq/boost" ]; then
        echo "$3" > "$CPU/cpufreq/boost" 2>/dev/null || echo "[ПРЕДУПРЕЖДЕНИЕ] boost $3 не выставился" >&2
    fi
}

if [ -z "$LEVEL" ]; then status; exit 0; fi
if [ -n "$FREQ" ] && [ "$LEVEL" != 4 ]; then echo "частота задаётся только для режима 4"; exit 1; fi
[ "$LEVEL" = 4 ] && FREQ=${FREQ:-4200}
[ "$EUID" -eq 0 ] || { echo "[ERROR] запускать от root"; exit 1; }

case $LEVEL in
    0) apply performance performance 1 ;;
    1) apply powersave balance_performance 1 ;;
    2) apply powersave balance_power 1 ;;
    3) apply powersave balance_power 0 ;;
    4) apply powersave balance_performance 1 "$FREQ" ;;
esac
echo "режим $LEVEL применён:"
status

if [ $PERSIST -eq 1 ]; then
    if [ "$LEVEL" = 0 ]; then
        command -v systemctl >/dev/null 2>&1 && systemctl disable cpu-eco.service >/dev/null 2>&1
        rm -f "$UNIT_DIR/cpu-eco.service"
        echo "автозапуск убран"
    else
        me=$(readlink -f "$0")
        cat > "$UNIT_DIR/cpu-eco.service" << EOF
[Unit]
Description=CPU power profile (cpu-eco $LEVEL)

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$me $LEVEL${FREQ:+ $FREQ}

[Install]
WantedBy=multi-user.target
EOF
        if command -v systemctl >/dev/null 2>&1; then
            systemctl daemon-reload
            systemctl enable cpu-eco.service >/dev/null 2>&1
        fi
        echo "автозапуск: $UNIT_DIR/cpu-eco.service ($me $LEVEL${FREQ:+ $FREQ}), скрипт должен остаться на этом месте"
    fi
fi
exit 0
