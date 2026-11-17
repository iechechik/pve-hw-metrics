#!/bin/bash
# Ночной бэкап хоста Proxmox:
#   1) архив конфигов и метаданных (по нему можно развернуть хост заново),
#   2) копия архивов на сервер архивов (misc), БЕЗ удаления чего-либо на той стороне,
#   3) зеркало дампов VM на соседний proxmox,
#   4) полное зеркало data -> backup (USB HDD).
#
# Запуск:  ./скрипт             обычная работа
#          ./скрипт --dry-run   проба: rsync ничего не меняет, маркеры не ставятся, старое не чистится
#
# Настройки берутся из /etc/pve-host-backup.conf (если есть), иначе из переменных окружения,
# иначе значения по умолчанию ниже. Пример файла для хоста, где misc видит каталог под другим путём:
#     ARCH_DIR=/mnt/data/backup/$HOST        # именно ${HOST} или $HOST, НЕ $(HOST)
#     DUMP_IP=proxmox-net.local
# Пустое значение отключает шаг: ARCH_IP= (шаг 2), DUMP_IP= (шаг 3), BACKUP= (шаг 4).
#
# Защита от стирания (удаление на приёмнике допускается только при выполнении всех условий):
#   * путь приёмника задан корректно и оканчивается именем этого хоста (не родительский каталог);
#   * приёмник уже помечен маркером .pve-backup-mirror от этого же источника, а при первом запуске
#     он пуст (тогда копируется без удаления и маркер ставится);
#   * число удаляемых rsync объектов не больше MAX_DELETE;
#   * источник не пуст, а USB-диск это другое устройство, чем диск данных.
export PATH="$PATH:/usr/sbin:/usr/bin:/sbin:/bin"
shopt -s nullglob

DRY_RUN=0
case "${1:-}" in
    --dry-run) DRY_RUN=1 ;;
    "") ;;
    *) echo "неизвестный аргумент: $1 (допустим только --dry-run)"; exit 1 ;;
esac

# --- Настройки (приоритет: $CONF > окружение > значения по умолчанию) ---
CONF=${CONF:-/etc/pve-host-backup.conf}
ROOT=${ROOT:-/mnt/pve/data}
BACKUP=${BACKUP-/mnt/pve/backup}                # пусто = шаг 4 отключён (нет USB-HDD)
HOST=${HOST:-$(hostname)}
ARCH_IP=${ARCH_IP-misc.local}                   # пусто = шаг 2 отключён (нет сервера архивов)
if [ "$HOST" = "proxmox-app" ]; then
    ARCH_IP=""
fi
DUMP_IP=${DUMP_IP-proxmox-net.local}            # пусто = шаг 3 отключён (нет соседа)
if [ "$HOST" = "proxmox-app" ]; then
    DUMP_IP="proxmox-net.local"
else
    DUMP_IP="proxmox-app.local"
fi

KEEP_DAYS=${KEEP_DAYS:-7}
MAX_DELETE=${MAX_DELETE:-500}
LOCK=${LOCK:-/var/lock/pve-host-backup.lock}
# shellcheck disable=SC1090
[ -f "$CONF" ] && . "$CONF"

HOME_DIR=${HOME_DIR:-$ROOT/backup/$HOST}
LOG=${LOG:-$HOME_DIR/backup.log}
CONFIGS_ARCHIVE_BASE="$HOME_DIR/${HOST}_configs"
CONFIGS_ARCHIVE="${CONFIGS_ARCHIVE_BASE}_$(date +%Y-%m-%d).tar.gz"
ARCH_DIR=${ARCH_DIR-"/mnt/data/backup/$HOST"}   # каталог на сервере архивов (по умолчанию тот же путь)
DUMP_DIR=${DUMP_DIR:-$ROOT/$HOST/}              # откуда берём дампы
DUMP_REMOTE_DIR=${DUMP_REMOTE_DIR:-$DUMP_DIR}   # куда кладём на соседе (по умолчанию тот же путь)
SSH_OPTS=(-o ConnectTimeout=5 -o BatchMode=yes)
RSH="ssh ${SSH_OPTS[*]}"
MARKER=.pve-backup-mirror

# --- Журнал ---
# Формат везде одинаков:  [2026-11-15 03:40:01] [УРОВЕНЬ] текст
# Уровни: INFO (ход работы), OK (шаг удался), WARN (проблема, но продолжаем), FAIL (ошибка).
# Пока не убедились, что $ROOT смонтирован, в файл журнала не пишем: иначе при отвалившемся
# диске каталог и лог создадутся на системном разделе.
LOG_READY=0
FAILS=0
PROBLEMS=()          # все WARN/FAIL с номером шага, выводятся списком в конце
CUR_STEP="[старт]"
_emit() {  # _emit УРОВЕНЬ текст
    local m; m="[$(date '+%Y-%m-%d %H:%M:%S')] [$1] $2"
    echo "$m"
    [ "$LOG_READY" = 1 ] && echo "$m" >> "$LOG"
    return 0
}
log_message() { _emit "INFO" "$*"; }
log_detail()  { _emit "INFO" "    $*"; }
log_ok()      { _emit " OK " "$*"; }
log_warn()    { _emit "WARN" "$*";  FAILS=$((FAILS + 1)); PROBLEMS+=("WARN|$CUR_STEP $*"); logger -t pve-host-backup -- "WARN: $*" 2>/dev/null; }
log_error()   { _emit "FAIL" "$*";  FAILS=$((FAILS + 1)); PROBLEMS+=("FAIL|$CUR_STEP $*"); logger -t pve-host-backup -- "FAIL: $*" 2>/dev/null; }
fatal()       { _emit "FAIL" "$*";  logger -t pve-host-backup -- "FATAL: $*" 2>/dev/null; exit 1; }
step()        { CUR_STEP=${1%% *}; _emit "INFO" "--- $* ---"; }
tail_detail() { local l; while IFS= read -r l; do [ -n "$l" ] && log_detail "$l"; done < <(tail -n "${2:-3}" "$1"); }

hbytes() {  # 1234567 -> 1.2MB ; 0 -> 0 B
    if [ "${1:-0}" -lt 1024 ] 2>/dev/null; then echo "${1:-0} B"
    elif command -v numfmt >/dev/null 2>&1; then numfmt --to=iec --suffix=B --format=%.1f "$1" 2>/dev/null || echo "$1 B"
    else echo "$1 B"; fi
}
duration() { echo "$(( $1 / 60 )) мин $(( $1 % 60 )) с"; }

# --- Проверка путей ---
# safe_path: абсолютный путь из безопасных символов, не меньше двух компонентов
safe_path() { [[ "${1%/}" =~ ^/[A-Za-z0-9._+@-]+(/[A-Za-z0-9._+@-]+)+$ ]]; }
# valid_dir: safe_path, и последний компонент равен имени хоста (так не получится указать родителя)
valid_dir() { safe_path "$1" && [ "$(basename "${1%/}")" = "$HOST" ]; }

# run_script ХОСТ арг...  (скрипт читается из stdin): на ХОСТ по ssh, при пустом ХОСТ локально
run_script() {
    local h=$1; shift
    if [ -n "$h" ]; then
        local q; q=$(printf ' %q' "$@")
        $RSH root@"$h" "bash -s --$q"
    else
        bash -s -- "$@"
    fi
}

# --- Маркер зеркала ---
# mirror_state ХОСТ КАТАЛОГ ИДЕНТИФИКАТОР -> delete | init | refuse:<причина>
mirror_state() {
    run_script "$1" "$2" "$3" <<'EOS'
d=$1; id=$2; m="$d/.pve-backup-mirror"
if [ -f "$m" ]; then
    if [ "$(cat "$m")" = "$id" ]; then echo delete; else echo "refuse:маркер зеркала от другого источника"; fi
elif [ ! -d "$d" ] || [ -z "$(ls -A "$d" | grep -v '^lost+found$')" ]; then
    echo init
else
    echo "refuse:каталог не пуст и не помечен как зеркало"
fi
EOS
}
mark_mirror() {  # mark_mirror ХОСТ КАТАЛОГ ИДЕНТИФИКАТОР
    run_script "$1" "$2" "$3" <<'EOS'
mkdir -p "$1" && printf '%s\n' "$2" > "$1/.pve-backup-mirror"
EOS
}

# run_rsync "что делаем" ключи... источник приёмник : запускает rsync и пишет итог по-русски
run_rsync() {
    local what=$1 out rc files bytes del dry=(); shift
    [ "$DRY_RUN" = 1 ] && dry=(-n)
    out=$(mktemp -p "$WORK")
    LC_ALL=C rsync "${dry[@]}" --stats "$@" > "$out" 2>&1; rc=$?
    # 0 = ок; 24 = часть файлов исчезла между составлением списка и копированием
    # (у работающих баз, например VictoriaMetrics, это обычное дело), остальное скопировано
    if [ $rc -eq 0 ] || [ $rc -eq 24 ]; then
        files=$(sed -n 's/^Number of regular files transferred: *//p' "$out" | head -1 | tr -d ,)
        bytes=$(sed -n 's/^Total transferred file size: *\([0-9,]*\) bytes.*/\1/p' "$out" | head -1 | tr -d ,)
        del=$(sed -n 's/^Number of deleted files: *\([0-9,]*\).*/\1/p' "$out" | head -1 | tr -d ,)
        log_ok "${dry:+(проба) }$what: передано файлов ${files:-?} ($(hbytes "${bytes:-0}")), удалено ${del:-0}"
        [ $rc -eq 24 ] && log_detail "часть файлов исчезла во время копирования (код 24 у rsync): для работающих баз это норма"
        return 0
    fi
    log_error "$what: rsync завершился с кодом $rc"
    [ $rc -eq 25 ] && log_detail "превышен лимит удалений MAX_DELETE=$MAX_DELETE: проверь источник; если удаление ожидаемо, запусти один раз с большим MAX_DELETE"
    tail_detail "$out" 3
    return 1
}

# do_mirror "что" ХОСТ КАТАЛОГ_ПРИЁМНИКА ИДЕНТИФИКАТОР ИСТОЧНИК ПРИЁМНИК [ключи rsync...]
# Удаление на приёмнике включается только если он уже помечен нашим маркером.
do_mirror() {
    local what=$1 host=$2 dir=$3 id=$4 src=$5 dst=$6 state; shift 6
    state=$(mirror_state "$host" "$dir" "$id") || { log_error "$what: не удалось проверить приёмник"; return 1; }
    case "$state" in
        delete)
            run_rsync "$what" "$@" --delete --max-delete="$MAX_DELETE" --exclude=/$MARKER "$src" "$dst" ;;
        init)
            log_message "$what: приёмник пуст или ещё не существует, копирую без удаления и ставлю маркер"
            if run_rsync "$what" "$@" --exclude=/$MARKER "$src" "$dst"; then
                if [ "$DRY_RUN" = 1 ]; then log_message "(проба) маркер не ставлю"
                else mark_mirror "$host" "$dir" "$id" || log_warn "$what: не удалось поставить маркер в $dir"; fi
            fi ;;
        refuse:*)
            log_warn "$what: отказ, ${state#refuse:} ($dir)"
            log_detail "если это действительно зеркало этого источника, поставь маркер вручную и убедись, что в приёмнике нет ничего ценного:"
            log_detail "${host:+ssh root@$host }echo '$id' > '$dir/$MARKER'" ;;
        *) log_error "$what: неожиданный ответ проверки приёмника: $state"; return 1 ;;
    esac
}

# --- Проверки до начала работы ---
mountpoint -q "$ROOT" || fatal "$ROOT не смонтирован, работа прервана"
[[ "$KEEP_DAYS" =~ ^[0-9]+$ ]] || fatal "KEEP_DAYS='$KEEP_DAYS' должно быть числом"
[[ "$MAX_DELETE" =~ ^[0-9]+$ ]] || fatal "MAX_DELETE='$MAX_DELETE' должно быть числом"

exec 9> "$LOCK" && { flock -n 9 || { log_message "Другой бэкап уже выполняется, выходим"; exit 0; }; }

mkdir -p "$HOME_DIR" || fatal "не удалось создать $HOME_DIR"
WORK=$(mktemp -d) || fatal "не удалось создать временный каталог"
trap 'rm -rf "$WORK"' EXIT
# журнал не растёт бесконечно: больше 5 МБ -> .1 (одна предыдущая копия)
[ -f "$LOG" ] && [ "$(stat -c %s "$LOG")" -gt 5242880 ] && mv -f "$LOG" "$LOG.1"
LOG_READY=1
log_message "===== Бэкап $HOST: начало ====="
[ "$DRY_RUN" = 1 ] && log_message "РЕЖИМ ПРОБЫ: на приёмниках ничего не меняется, маркеры не ставятся, старое не удаляется"

# Копия самого скрипта рядом с архивами: хранится в том виде, в каком он реально отработал
# (дальше уезжает вместе с архивами на misc и в зеркало)
SELF=$(readlink -f "$0")
SELF_COPY="$HOME_DIR/${HOST}-backup.sh"
if [ "$DRY_RUN" != 1 ] && [ -f "$SELF" ] && ! [ "$SELF" -ef "$SELF_COPY" ] && ! cmp -s "$SELF" "$SELF_COPY"; then
    if cp -f "$SELF" "$SELF_COPY"; then log_message "Скрипт обновлён: $SELF_COPY"
    else log_warn "не удалось сохранить копию скрипта в $SELF_COPY"; fi
fi

# changed_files КАТАЛОГ...: файлы, не принадлежащие ни одному пакету (созданы тобой или сгенерированы),
# и файлы пакетов (conffile), изменённые относительно пакета; плюс маски юнитов (ссылки на /dev/null).
# Ссылки включения юнитов (.wants) не берём: их создают пакеты; включённость своих юнитов
# хранится в meta/systemd-enabled.txt.
changed_files() (
    export LC_ALL=C
    local d
    for d in "$@"; do [ -d "$d" ] && find "$d" \( -type f -o -lname /dev/null \) -print; done | sort -u > "$WORK/cand.txt"
    [ -s "$WORK/cand.txt" ] || exit 0
    cat /var/lib/dpkg/info/*.list 2>/dev/null | sort -u > "$WORK/owned.txt"
    comm -23 "$WORK/cand.txt" "$WORK/owned.txt"
    dpkg-query -W -f='${Conffiles}\n' 2>/dev/null | awk 'NF >= 2 && substr($1, 1, 1) == "/" { print $1, $2 }' | sort -k1,1 > "$WORK/conf.txt"
    join -j1 "$WORK/cand.txt" "$WORK/conf.txt" | while read -r path md5; do
        [ "$(md5sum "$path" 2>/dev/null | cut -d' ' -f1)" != "$md5" ] && echo "$path"
    done
    exit 0
)

# --- 1. Локальный архив конфигов ---
step "[1/4] Архив конфигов"

# Метаданные для разворачивания: что стояло и как было разложено (лежат в архиве в каталоге meta/)
mkdir -p "$WORK/meta"
meta() { local name=$1; shift; command -v "$1" >/dev/null 2>&1 && "$@" > "$WORK/meta/$name" 2>&1; return 0; }
meta dpkg-selections.txt dpkg --get-selections
meta packages-manual.txt apt-mark showmanual
[ -s "$WORK/meta/packages-manual.txt" ] && sort -o "$WORK/meta/packages-manual.txt" "$WORK/meta/packages-manual.txt"
meta dkms.txt            dkms status
meta pveversion.txt      pveversion -v
meta lsblk.txt           lsblk -f
meta lvs.txt             lvs -a
command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files --state=enabled --no-legend > "$WORK/meta/systemd-enabled.txt" 2>&1
{
    echo "host=$HOST"
    echo "date=$(date -Is)"
    echo "kernel=$(uname -r)"
    echo "pve=$(pveversion 2>/dev/null)"
} > "$WORK/meta/MANIFEST"

# Целиком берём то, что не управляется пакетами (твои файлы, данные Proxmox):
CONFIG_PATHS=(
    /etc/pve                                        # конфиги узла, виртуалок, хранилищ, заданий
    /etc/vzdump.conf
    /etc/subuid /etc/subgid                         # нужны LXC с собственным idmap
    /etc/network/interfaces
    /etc/hosts /etc/resolv.conf /etc/hostname /etc/fstab
    /etc/modules /etc/sysctl.conf
    /etc/aliases /etc/mailname
    /etc/smartd.conf
    /var/lib/smartmontools/drivedb/drivedb.h /var/lib/smartmontools/drivedb/drivedb.h.raw
    /etc/crontab /var/spool/cron
    /etc/pve-metrics.conf /etc/pve-host-backup.conf
    /root/.ssh
    /usr/local/bin /usr/local/sbin /usr/local/etc   # без lib/share/src: там бывают тяжёлые установки
    '/root/*.sh' /root/.bashrc /root/.profile
)
# В этих каталогах свои файлы кладут и пакеты, поэтому берём только то, что создано тобой/системой
# (не принадлежит пакету) или изменено относительно пакета. Так на новой версии Proxmox старые
# служебные файлы пакетов не вернутся поверх новых.
CHANGED_DIRS=(
    /etc/apt /etc/default /etc/kernel /etc/ssh /etc/postfix /etc/nut
    /etc/systemd/system /etc/modprobe.d /etc/modules-load.d /etc/sysctl.d
    /etc/udev/rules.d /etc/cron.d /etc/network/interfaces.d
)
# Берём только то, что реально существует (иначе tar ругается на каждый отсутствующий файл);
# маски раскрываются здесь.
FILES=(); MISSING=()
for p in "${CONFIG_PATHS[@]}"; do
    matches=( $p )
    [ ${#matches[@]} -eq 0 ] && MISSING+=("$p")
    for f in "${matches[@]}"; do
        if [ -e "$f" ] || [ -L "$f" ]; then FILES+=("${f#/}"); else MISSING+=("$f"); fi
    done
done
[ ${#MISSING[@]} -gt 0 ] && log_message "Нет на этой системе (пропущено ${#MISSING[@]}): ${MISSING[*]}"
mapfile -t CHANGED < <(changed_files "${CHANGED_DIRS[@]}")
for f in "${CHANGED[@]}"; do FILES+=("${f#/}"); done
printf '%s\n' "${CHANGED[@]}" > "$WORK/meta/changed-files.txt"
log_message "Изменённых или своих файлов в каталогах пакетов: ${#CHANGED[@]} (список в архиве: meta/changed-files.txt)"

tar -czf "$CONFIGS_ARCHIVE.part" --warning=no-file-changed -C / "${FILES[@]}" -C "$WORK" meta 2> "$WORK/tar.err"
tar_rc=$?
# 0 = всё хорошо, 1 = какой-то файл изменился во время чтения (для /etc/pve это нормально)
if [ $tar_rc -le 1 ] && [ -s "$CONFIGS_ARCHIVE.part" ]; then
    mv -f "$CONFIGS_ARCHIVE.part" "$CONFIGS_ARCHIVE"
    log_ok "Архив создан: $CONFIGS_ARCHIVE ($(hbytes "$(stat -c %s "$CONFIGS_ARCHIVE")"), путей: ${#FILES[@]})"
else
    rm -f "$CONFIGS_ARCHIVE.part"
    log_error "tar завершился с кодом $tar_rc, архив конфигов не создан"
    tail_detail "$WORK/tar.err" 3
fi
# старые архивы (в -name только имя файла, без пути)
old=$(find "$HOME_DIR" -maxdepth 1 -name "${HOST}_configs_*.tar.gz" -type f -mtime +"$KEEP_DAYS" -print -delete 2>> "$LOG" | wc -l)
[ "$old" -gt 0 ] && log_message "Удалено старых архивов (старше $KEEP_DAYS дн.): $old"

# --- 2. Копирование архивов на сервер архивов ---
# Здесь rsync БЕЗ --delete: даже при неверном пути он может только добавить файлы.
# Старые архивы на той стороне чистятся отдельно, строго по маске имени этого хоста.
step "[2/4] Копирование архивов на $ARCH_IP"
if [ -z "$ARCH_IP" ]; then
    log_message "Отключено (ARCH_IP пуст), шаг пропущен"
elif ! valid_dir "$ARCH_DIR"; then
    log_error "ARCH_DIR='$ARCH_DIR' недопустим: нужен абсолютный путь, оканчивающийся именем хоста '$HOST' (например /mnt/data/backup/$HOST). Шаг пропущен"
else
    if ! ssh_err=$($RSH root@"$ARCH_IP" true 2>&1); then
        log_warn "Сервер архивов $ARCH_IP недоступен"
        log_detail "ssh: $(echo "$ssh_err" | tail -n 1)"
    elif ! $RSH root@"$ARCH_IP" "[ -d '$ARCH_DIR' ]"; then
        log_warn "На $ARCH_IP нет каталога $ARCH_DIR"
    elif ! ls "$CONFIGS_ARCHIVE_BASE"_*.tar.gz >/dev/null 2>&1; then
        log_warn "Локально нет ни одного архива, копирование пропущено"
    else
        if run_rsync "Архивы на $ARCH_IP:$ARCH_DIR" -a --no-o --no-g -e "$RSH" "$HOME_DIR/" root@"$ARCH_IP":"${ARCH_DIR%/}/" && [ "$DRY_RUN" != 1 ]; then
            old=$($RSH root@"$ARCH_IP" "find '${ARCH_DIR%/}' -maxdepth 1 -name '${HOST}_configs_*.tar.gz' -type f -mtime +$KEEP_DAYS -print -delete" 2>/dev/null | wc -l)
            [ "$old" -gt 0 ] && log_message "На $ARCH_IP удалено старых архивов (старше $KEEP_DAYS дн.): $old"
        fi
    fi
fi

# --- 3. Зеркало дампов VM на соседний proxmox ---
step "[3/4] Зеркало дампов на $DUMP_IP"
if [ -z "$DUMP_IP" ]; then
    log_message "Отключено (DUMP_IP пуст), шаг пропущен"
elif [ ! -d "$DUMP_DIR" ]; then
    log_message "Каталога дампов $DUMP_DIR нет, шаг пропущен"
elif ! safe_path "$DUMP_DIR" || ! valid_dir "$DUMP_REMOTE_DIR"; then
    log_error "DUMP_DIR='$DUMP_DIR' или DUMP_REMOTE_DIR='$DUMP_REMOTE_DIR' недопустимы: нужны абсолютные пути, приёмник оканчивается именем хоста '$HOST'. Шаг пропущен"
elif [ -z "$(ls -A "$DUMP_DIR" 2>/dev/null)" ]; then
    log_warn "Каталог дампов $DUMP_DIR пуст, зеркало пропущено (чтобы не стереть копию на $DUMP_IP)"
elif ! ssh_err=$($RSH root@"$DUMP_IP" true 2>&1); then
    log_warn "Сервер дампов $DUMP_IP недоступен"
    log_detail "ssh: $(echo "$ssh_err" | tail -n 1)"
elif ! $RSH root@"$DUMP_IP" "mountpoint -q '$ROOT'"; then
    log_warn "На $DUMP_IP не смонтирован $ROOT, дампы не копирую"
else
    do_mirror "Дампы на $DUMP_IP:${DUMP_REMOTE_DIR%/}" "$DUMP_IP" "${DUMP_REMOTE_DIR%/}" "dumps:$HOST:${DUMP_DIR%/}" \
        "${DUMP_DIR%/}/" root@"$DUMP_IP":"${DUMP_REMOTE_DIR%/}/" -a -e "$RSH"
fi

# --- 4. Полное зеркало data -> backup ---
# Содержимое $ROOT копируется прямо в корень $BACKUP, лишнее в $BACKUP удаляется (кроме lost+found),
# но только если $BACKUP уже помечен маркером (первый раз он должен быть пуст).
step "[4/4] Зеркало $ROOT -> $BACKUP"
r_root=$(readlink -f "$ROOT"); r_backup=$(readlink -f "$BACKUP")
if [ -z "$BACKUP" ]; then
    log_message "Отключено (BACKUP пуст), шаг пропущен"
elif ! safe_path "$BACKUP"; then
    log_error "BACKUP='$BACKUP' недопустим: нужен абсолютный путь из обычных символов. Шаг пропущен"
elif [ "$r_root" = "$r_backup" ] || [[ "$r_backup/" == "$r_root/"* ]]; then
    log_error "$BACKUP совпадает с $ROOT или лежит внутри него, зеркало не делаю"
elif ! mountpoint -q "$BACKUP"; then
    log_warn "$BACKUP не смонтирован, зеркало пропущено"
elif [ "$(stat -c %d "$ROOT")" = "$(stat -c %d "$BACKUP")" ]; then
    log_error "$BACKUP и $ROOT находятся на одном устройстве, зеркало не делаю"
elif [ -z "$(ls -A "$ROOT" 2>/dev/null)" ]; then
    log_error "$ROOT пуст, зеркало не делаю (чтобы не стереть $BACKUP)"
else
    do_mirror "Зеркало $ROOT -> $BACKUP" "" "${BACKUP%/}" "mirror:$HOST:$ROOT" \
        "$ROOT/" "$BACKUP/" -aHAXS --numeric-ids --exclude=/lost+found
fi

# --- Итог ---
if [ $FAILS -eq 0 ]; then
    log_ok "===== Бэкап $HOST: завершён без проблем за $(duration $SECONDS) ====="
else
    n=$FAILS
    log_message "Что пошло не так:"
    i=0
    for p in "${PROBLEMS[@]}"; do
        i=$((i + 1)); _emit "${p%%|*}" "    $i) ${p#*|}"
    done
    log_warn "===== Бэкап $HOST: завершён, проблем: $n, время $(duration $SECONDS) ====="
fi
echo "--------------------------------" >> "$LOG"

# для красоты чистим кэши (ядро и так освободит их само при нехватке памяти, так что не обязательно)
sync && echo 3 > /proc/sys/vm/drop_caches 2>/dev/null

### [ $FAILS -eq 0 ] || exit 1
exit 0
