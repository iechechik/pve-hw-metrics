#!/bin/bash
# =========================================================
# Скрипт установки драйвера вентилятора IT5570 для Proxmox
# =========================================================

if [ "$EUID" -ne 0 ]; then
    echo "[ERROR] Запускать нужно от root"
    exit 1
fi

echo "[1/5] Установка зависимостей (git, dkms, headers)..."
apt-get update
apt-get install -y git build-essential dkms proxmox-default-headers

echo "[2/5] Клонирование репозитория..."
cd /opt || exit 1
if [ -d "/opt/it5570-fan" ]; then
    echo " -> Папка уже существует, обновляем..."
    cd /opt/it5570-fan
    git pull
else
    echo " -> Скачиваем репозиторий..."
    git clone https://github.com/passiveEndeavour/it5570-fan.git /opt/it5570-fan
    cd /opt/it5570-fan || exit 1
fi

echo "[3/5] Сборка и установка модуля через DKMS..."
# Убираем старую запись, если скрипт запускают повторно (ошибки игнорируем)
dkms remove it5570-fan/v0.1.0 --all >/dev/null 2>&1 || true
make dkms-install

echo "[4/5] Загрузка модуля в ядро..."
modprobe it5570_fan

echo "[5/5] Настройка автозагрузки при старте системы..."
echo "it5570_fan" > /etc/modules-load.d/it5570_fan.conf

echo "========================================================================"
echo "[ ОКИ-ДОКИ! ] Установка завершена."
echo "Проверка датчиков:"
sensors | grep -A 6 "it5570_fan"
echo "========================================================================"
exit 0
