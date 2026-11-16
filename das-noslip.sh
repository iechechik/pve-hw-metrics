#!/bin/bash
# Пинаем диски ТОЛЬКО внутри многодисковой стойки ACASIS, игнорируя одиночные USB-диски

# НАСТРОЙКА: 
# "one" - пинать только ОДИН первый попавшийся HDD в стойке ACASIS
# "all" - пинать ВСЕ HDD внутри стойки по очереди
MODE="one"

declare -A port_counts
declare -A drive_ports

# 1. Сканируем все USB HDD в системе и определяем их физические порты
for dev_name in $(lsblk -d -n -o NAME,TRAN,ROTA | grep 'usb' | grep ' 1$' | awk '{print $1}'); do
    # Получаем аппаратный путь ID_PATH через udevadm (иммунитет к изменению букв дисков)
    id_path=$(udevadm info -q property -n "/dev/$dev_name" | grep 'ID_PATH=' | cut -d= -f2)
    [ -z "$id_path" ] && continue
    
    # Выковыриваем номер корневого USB-порта (например, "0:2" или "0:4")
    usb_port=$(echo "$id_path" | sed -E 's/.*usb-([0-9]+:[0-9]+).*/\1/')
    
    if [ -n "$usb_port" ]; then
        drive_ports[$dev_name]=$usb_port
        ((port_counts[$usb_port]++))
    fi
done

# 2. Ищем USB-порт, на котором висит БОЛЬШЕ ВСЕГО дисков (это 100% наша корзина)
acasis_port=""
max_count=0
for port in "${!port_counts[@]}"; do
    if [ ${port_counts[$port]} -gt $max_count ]; then
        max_count=${port_counts[$port]}
        acasis_port=$port
    fi
done

# Если USB-стойка не найдена — тихо завершаем работу
[ -z "$acasis_port" ] && exit 0

# 3. Пинаем только те диски, которые принадлежат этой стойке-победителю
for dev_name in "${!drive_ports[@]}"; do
    if [ "${drive_ports[$dev_name]}" == "$acasis_port" ]; then
        
        # Выполняем микро-чтение
        /bin/dd if="/dev/$dev_name" of=/dev/null bs=512 count=1 skip=$((RANDOM % 10000)) iflag=direct >/dev/null 2>&1
        
        # В режиме "one" выходим сразу после первого успешного пинка диска из корзины
        if [ "$MODE" == "one" ]; then
            break
        fi
    fi
done
