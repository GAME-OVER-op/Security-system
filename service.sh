#!/system/bin/sh
# uninstall_from_list.sh
# Читает список пакетов из файла и удаляет их, отправляет уведомления от имени системы.
# Иконки: /data/local/tmp/7.png
# Логи: /data/local/tmp/packages_uninstall.log

### Настройки (можно переопределить через окружение)
MODDIR=${0%/*}
PACKAGES_FILE="$MODDIR/packages.txt"
LOG_FILE="${LOG_FILE:-/data/local/tmp/packages_uninstall.log}"
NOTIFICATION="${NOTIFICATION:-1}"          # 1 = включены, 0 = выключены
ICON_PATH="file:///data/local/tmp/security.png"
STYLE="messaging"
TITLE="Система и безопасность"
SLEEP_BEFORE_START="${SLEEP_BEFORE_START:-250}"
LOOP_INTERVAL="${LOOP_INTERVAL:-30}"

# Полезные функции ----------------------------------------------------------------

log() {
    # Логируем и выводим в stdout
    local msg="$1"
    echo "$(date '+%Y-%m-%d %T') $msg" >> "$LOG_FILE"
    echo "$msg"
}

# Экранируем одинарные кавычки для безопасной вставки в '...'
_escape_single_quotes() {
    printf "%s" "$1" | sed "s/'/'\"'\"'/g"
}

# Получаем название приложения по имени пакета
get_app_name() {
    local pkg="$1"
    local app_name
    
    # Пытаемся получить название приложения через dumpsys
    app_name=$(dumpsys package "$pkg" | grep -A1 "application:" | grep "label=" | cut -d'=' -f2- | sed "s/['\"]//g" | head -1)
    
    if [ -n "$app_name" ]; then
        echo "$app_name"
    else
        echo "$pkg"
    fi
}

notification_send() {
    # Параметры:
    #   $1 - имя пакета
    if [ "$NOTIFICATION" != "1" ]; then
        log "Уведомления отключены (NOTIFICATION=$NOTIFICATION), пропускаю отправку."
        return 1
    fi

    local pkg="$1"
    local app_name=$(get_app_name "$pkg")
    local BODY="Внимание обнаружен вирус, в целях безопасности он будет удален: $app_name"
    local TAG="antivirus"

    # Экранируем одинарные кавычки, чтобы можно было поместить в '...'
    local esc_BODY=$(_escape_single_quotes "$BODY")
    local esc_TITLE=$(_escape_single_quotes "$TITLE")
    local cmdstr="cmd notification post \
        -i $ICON_PATH -I $ICON_PATH \
        -S $STYLE \
        --conversation 'System' \
        --message '$TITLE:$esc_BODY' \
        -t '$esc_TITLE' \
        '$TAG' '$esc_BODY'"

    # Выполняем от имени системного пользователя (через shell su -lp 2000 -c ...)
    su -lp 2000 -c "$cmdstr" >/dev/null 2>&1
    echo "$cmdstr"
    if [ $? -eq 0 ]; then
        log "Уведомление отправлено: $BODY"
    else
        log "Не удалось отправить уведомление: $BODY"
    fi
}

_pkg_installed() {
    # Проверяем, установлен ли пакет (возвращаем 0 если установлен)
    local p="$1"
    pm list packages | grep -q "^package:$p$" && return 0
    pm list packages | grep -q "$p" && return 0
    return 1
}

_remove_one_package() {
    local pkg="$1"
    log "Обрабатываю пакет: $pkg"

    # Останавливаем приложение, если запущено
    am force-stop "$pkg" >/dev/null 2>&1

    # Пробуем удалить как root (полное удаление)
    if su -c "pm uninstall '$pkg'" >/dev/null 2>&1; then
        log "Пакет $pkg полностью удалён (root)."
        return 0
    fi

    # Если root недоступен или команда не прошла, удаляем для user 0
    if pm uninstall --user 0 "$pkg" >/dev/null 2>&1; then
        log "Пакет $pkg удалён для user 0."
        return 0
    fi

    # Если не удалось удалить
    log "Не удалось удалить пакет $pkg."
    return 1
}

process_list_file() {
    [ -f "$PACKAGES_FILE" ] || { log "Файл списка пакетов не найден: $PACKAGES_FILE"; return 1; }
    # Проходим по строкам, игнорируем пустые и строки, начинающиеся с #.
    while IFS= read -r line || [ -n "$line" ]; do
        # Обрезаем пробелы
        pkg="$(printf "%s" "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [ -z "$pkg" ] && continue
        case "$pkg" in
            \#*) continue ;; # пропускаем комментарии
        esac

        if _pkg_installed "$pkg"; then
            notification_send "$pkg"
            _remove_one_package "$pkg"
        else
            log "Пакет $pkg не установлен, пропускаю."
        fi
    done < "$PACKAGES_FILE"
}

# Обработка сигналов и завершение ---------------------------------------------------
_cleanup() {
    log "Скрипт получает сигнал на завершение, выхожу."
    exit 0
}
trap _cleanup INT TERM

# MAIN ----------------------------------------------------------------------------
log "Старт скрипта uninstall_from_list.sh (PID $$). Файл пакетов: $PACKAGES_FILE"

# Ждём, чтобы система успела загрузиться
sleep "$SLEEP_BEFORE_START"

# Первый проход
process_list_file

# Циклическая проверка: каждые LOOP_INTERVAL секунд читаем файл и обрабатываем
while true; do
    sleep "$LOOP_INTERVAL"
    process_list_file
done