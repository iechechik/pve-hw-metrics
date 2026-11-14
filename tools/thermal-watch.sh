#!/bin/bash
# Замер нагрева: температура CPU, вентилятор, частота, нагрузка и самый активный процесс.
# Использование: ./thermal-watch.sh [секунд=600] [интервал=3]
# В конце: максимум, сколько времени было горячо и какие процессы грели в эти моменты.
# Запускать, пока идёт обычная работа (или дождаться момента, когда вентилятор ускоряется).

DUR=${1:-600}; STEP=${2:-3}; SYS=${SYS:-/sys}; HOT=80

hw() {  # путь hwmon по имени чипа
    local h
    for h in "$SYS"/class/hwmon/hwmon*; do
        [ "$(cat "$h/name" 2>/dev/null)" = "$1" ] && { echo "$h"; return; }
    done
}
CPU_HW=$(hw k10temp); [ -z "$CPU_HW" ] && CPU_HW=$(hw coretemp)
FAN_HW=""
for h in "$SYS"/class/hwmon/hwmon*; do
    ls "$h"/fan*_input >/dev/null 2>&1 && { FAN_HW=$h; break; }
done
CPUF="$SYS/devices/system/cpu"

echo "процессор : $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | xargs)"
echo "драйвер   : $(cat $CPUF/cpu0/cpufreq/scaling_driver 2>/dev/null || echo ?)," \
     "governor $(cat $CPUF/cpu0/cpufreq/scaling_governor 2>/dev/null || echo ?)," \
     "EPP $(cat $CPUF/cpu0/cpufreq/energy_performance_preference 2>/dev/null || echo ?)," \
     "boost $(cat $CPUF/cpufreq/boost 2>/dev/null || echo ?)"
echo "ядер/потоков: $(nproc), датчик CPU: ${CPU_HW:-не найден}, вентилятор: ${FAN_HW:-не найден}"
echo

declare -A who; n=0; hot=0; tmax=0; fmax=0
end=$(( $(date +%s) + DUR ))
while [ "$(date +%s)" -lt "$end" ]; do
    t=0; [ -n "$CPU_HW" ] && t=$(( $(cat "$CPU_HW/temp1_input" 2>/dev/null || echo 0) / 1000 ))
    f=0; [ -n "$FAN_HW" ] && f=$(cat "$FAN_HW"/fan1_input 2>/dev/null || echo 0)
    freq=$(cat "$CPUF"/cpu[0-9]*/cpufreq/scaling_cur_freq 2>/dev/null |
           awk '{s+=$1; c++; if ($1>m) m=$1} END{if (c) printf "%d/%d", s/c/1000, m/1000; else printf "?"}')
    top1=$(top -bn2 -d1 -o %CPU 2>/dev/null |
           awk '/^top -/{k++} k==2 && $1 ~ /^[0-9]+$/ {print $12" "$9"%"; exit}')
    printf '%s  CPU %3d°C  вент. %5s RPM  частота ср/макс %s МГц  load %s  топ: %s\n' \
        "$(date +%H:%M:%S)" "$t" "$f" "$freq" "$(cut -d' ' -f1 /proc/loadavg)" "${top1:-?}"
    n=$((n+1)); (( t > tmax )) && tmax=$t; (( f > fmax )) && fmax=$f
    if (( t >= HOT )); then hot=$((hot+1)); p=${top1%% *}; [ -n "$p" ] && who[$p]=$(( ${who[$p]:-0} + 1 )); fi
    sleep $(( STEP > 1 ? STEP - 1 : 0 ))
done

echo
echo "=== итог: $n замеров ==="
echo "максимум CPU: ${tmax}°C, замеров от ${HOT}°C: $hot из $n, максимум вентилятора: $fmax RPM"
if [ ${#who[@]} -gt 0 ]; then
    echo "в горячие моменты чаще всего грели:"
    for p in "${!who[@]}"; do echo "${who[$p]} $p"; done | sort -rn | head -5 | sed 's/^/  /'
else
    echo "горячих моментов (от ${HOT}°C) за это время не было, запусти в момент, когда вентилятор ускоряется"
fi
exit 0
