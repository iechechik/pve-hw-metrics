#!/bin/bash
# Что умеет драйвер it5570_fan и каким его датчикам можно верить. Только читает, ничего не меняет.
# Использование: ./it5570-check.sh [секунд=60] [интервал=2]
# Запускать при обычной работе, лучше когда есть хоть какая-то нагрузка (иначе всё будет «константой»).

DUR=${1:-60}; STEP=${2:-2}; SYS=${SYS:-/sys}; REPO=${REPO:-/opt/it5570-fan}

H=""; K=""
for h in "$SYS"/class/hwmon/hwmon*; do
    n=$(cat "$h/name" 2>/dev/null)
    [ "$n" = it5570_fan ] && H=$h
    [ "$n" = k10temp ] && K=$h
done
[ -z "$H" ] && { echo "hwmon it5570_fan не найден (модуль загружен? lsmod | grep it5570)"; exit 1; }

echo "=== DMI этой машины ==="
for k in sys_vendor product_name board_name bios_version; do
    printf '%-13s %s\n' "$k" "$(cat "$SYS/class/dmi/id/$k" 2>/dev/null)"
done

echo
echo "=== атрибуты $H (в правах буква w значит, что писать можно) ==="
for f in "$H"/*; do
    [ -f "$f" ] && printf '%-18s %s  %s\n' "$(basename "$f")" "$(stat -c %A "$f")" "$(head -c 40 "$f" 2>/dev/null | tr '\n' ' ')"
done

echo
echo "=== модуль ==="
modinfo it5570_fan 2>/dev/null | grep -E '^(filename|version|description|parm|alias):' || echo "modinfo ничего не вернул"

echo
echo "=== репозиторий $REPO ==="
ls "$REPO" 2>/dev/null | head -20
for r in "$REPO"/README*; do
    [ -f "$r" ] && { echo "--- $(basename "$r") (первые 80 строк)"; head -n 80 "$r"; break; }
done

echo
echo "=== параметры модуля, привязка к моделям и регистры (из исходников) ==="
grep -nE 'module_param|MODULE_PARM_DESC|DMI_(SYS|BOARD|PRODUCT)_|dmi_system_id|0x[0-9a-fA-F]{2,4}' "$REPO"/*.c 2>/dev/null | head -n 60

echo
echo "=== замеры $DUR с, шаг $STEP с: какие каналы живые ==="
chans=$(cd "$H" && ls temp*_input fan*_input pwm[0-9] 2>/dev/null)
declare -A mn mx
kmn=""; kmx=""
end=$(( $(date +%s) + DUR ))
while [ "$(date +%s)" -lt "$end" ]; do
    for c in $chans; do
        v=$(cat "$H/$c" 2>/dev/null)
        [[ "$v" =~ ^-?[0-9]+$ ]] || continue
        [ -z "${mn[$c]}" ] && { mn[$c]=$v; mx[$c]=$v; }
        (( v < mn[$c] )) && mn[$c]=$v
        (( v > mx[$c] )) && mx[$c]=$v
    done
    if [ -n "$K" ]; then
        v=$(cat "$K/temp1_input" 2>/dev/null)
        if [[ "$v" =~ ^-?[0-9]+$ ]]; then
            [ -z "$kmn" ] && { kmn=$v; kmx=$v; }
            (( v < kmn )) && kmn=$v
            (( v > kmx )) && kmx=$v
        fi
    fi
    sleep "$STEP"
done

fmt() {  # канал значение
    case $1 in
        temp*) awk -v x="$2" 'BEGIN{printf "%.1f°C", x/1000}' ;;
        fan*)  echo "$2 RPM" ;;
        *)     echo "$2" ;;
    esac
}
for c in $chans; do
    l=""; [ -f "$H/${c%_input}_label" ] && l=$(cat "$H/${c%_input}_label")
    if [ -z "${mn[$c]}" ]; then printf '%-13s %-10s нет данных\n' "$c" "$l"; continue; fi
    note=""; [ "${mn[$c]}" = "${mx[$c]}" ] && note="  <- не менялся за время замера"
    printf '%-13s %-10s мин %-9s макс %-9s%s\n' "$c" "$l" "$(fmt "$c" "${mn[$c]}")" "$(fmt "$c" "${mx[$c]}")" "$note"
done
if [ -n "$kmn" ]; then
    printf '%-13s %-10s мин %-9s макс %-9s\n' "k10temp" "Tctl (эталон)" "$(fmt temp "$kmn")" "$(fmt temp "$kmx")"
fi
echo
echo "Датчик, который не менялся при нагрузке или расходится с эталоном Tctl, считай недостоверным."
exit 0
