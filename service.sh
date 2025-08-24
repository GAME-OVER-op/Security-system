#!/system/bin/sh
# uninstall_from_list.sh
# Читает список пакетов из файла и удаляет их, отправляет уведомления от имени системы.
# Иконки: /data/local/tmp/security.png
# Логи: /data/local/tmp/packages_uninstall.log

### Настройки (можно переопределить через окружение)
PACKAGES_FILE="${PACKAGES_FILE:-/data/adb/modules/security_system_gg/packages.txt}"
LOG_FILE="${LOG_FILE:-/data/local/tmp/packages_uninstall.log}"
NOTIFICATION="${NOTIFICATION:-1}"          # 1 = включены, 0 = выключены
ICON_PATH="${ICON_PATH:-file:///data/local/tmp/security.png}"
STYLE="${STYLE:-messaging}"
TITLE="${TITLE:-Система и безопасность}"
SLEEP_BEFORE_START="${SLEEP_BEFORE_START:-250}"
LOOP_INTERVAL="${LOOP_INTERVAL:-30}"
# Опция: если выставить DEBUG=1 -> больше отладочных логов
DEBUG="${DEBUG:-0}"
> "$LOG_FILE"

# Временный файл для нормализованного списка
TMP_PACKAGES="/data/local/tmp/packages_uninstall_src.txt"
PACKAGES_FILE_TO_READ=""

# -------------------------
log() {
  # Логируем и выводим в stdout
  # $1 - сообщение
  local msg="$1"
  # создаём файл, если нужно
  [ -n "$LOG_FILE" ] || LOG_FILE="/data/local/tmp/packages_uninstall.log"
  printf "%s %s\n" "$(date '+%Y-%m-%d %T')" "$msg" >> "$LOG_FILE"
  printf "%s\n" "$msg"
}

dbg() {
  # отладочный лог, отображается только если DEBUG=1
  if [ "$DEBUG" = "1" ]; then
    log "DEBUG: $1"
  fi
}

# -------------------------
# Экранируем одинарные кавычки для безопасной вставки в '...'
_escape_single_quotes() {
  printf "%s" "$1" | sed "s/'/'\"'\"'/g"
}

# -------------------------
# Подготовка/нормализация файла списка пакетов
_prepare_packages_file() {
  # Если указали директорию — используем packages.txt внутри неё
  if [ -d "$PACKAGES_FILE" ]; then
    PACKAGES_FILE="${PACKAGES_FILE%/}/packages.txt"
    dbg "PACKAGES_FILE указывал на директорию — подставил ${PACKAGES_FILE}"
  fi

  if [ ! -f "$PACKAGES_FILE" ]; then
    log "Файл списка пакетов не найден: $PACKAGES_FILE"
    return 1
  fi

  # Копируем исходный файл в /data/local/tmp (уменьшаем влияние SELinux/context/прав)
  cp "$PACKAGES_FILE" "$TMP_PACKAGES" 2>/dev/null || {
    log "Не удалось скопировать $PACKAGES_FILE -> $TMP_PACKAGES"
    return 1
  }

  # Удаляем CRLF (\r)
  tr -d '\r' < "$TMP_PACKAGES" > "${TMP_PACKAGES}.nocr" 2>/dev/null || {
    # если tr отсутствует, просто продолжим с оригиналом
    dbg "tr недоступен или не сработал; продолжаю с оригиналом"
    mv "$TMP_PACKAGES" "${TMP_PACKAGES}.nocr" 2>/dev/null || true
  }
  mv "${TMP_PACKAGES}.nocr" "$TMP_PACKAGES" 2>/dev/null || true

  # Удаляем BOM, если он есть (проверка первых 3 байт)
  first3=$(dd if="$TMP_PACKAGES" bs=1 count=3 2>/dev/null | od -An -t x1 | tr -d ' \n' 2>/dev/null || echo "")
  if [ "$first3" = "efbbbf" ]; then
    dbg "BOM обнаружен — удаляю первые 3 байта"
    # tail -c +4 работает в busybox/toybox на Android
    tail -c +4 "$TMP_PACKAGES" > "${TMP_PACKAGES}.nobom" 2>/dev/null && mv "${TMP_PACKAGES}.nobom" "$TMP_PACKAGES"
  else
    dbg "BOM не обнаружен (first3=$first3)"
  fi

  # Права безопасные
  chmod 644 "$TMP_PACKAGES" 2>/dev/null || true
  chown root:root "$TMP_PACKAGES" 2>/dev/null || true

  dbg "Подготовлен файл $TMP_PACKAGES (из $PACKAGES_FILE), байт: $(wc -c < "$TMP_PACKAGES" 2>/dev/null || echo '?'), строк: $(wc -l < "$TMP_PACKAGES" 2>/dev/null || echo '?')"

  PACKAGES_FILE_TO_READ="$TMP_PACKAGES"
  return 0
}

# -------------------------
# Проверяем, готов ли PackageManager (ожидание readiness)
_wait_for_pm() {
  local timeout="${1:-60}" # секунды
  local t=0
  dbg "Ожидаю готовности pm (таймаут ${timeout}s)..."
  while [ $t -lt "$timeout" ]; do
    # Проверяем любой системный пакет — например com.android.settings
    if pm path com.android.settings >/dev/null 2>&1; then
      dbg "pm готов (t=$t)"
      return 0
    fi
    sleep 1
    t=$((t+1))
  done
  log "WARN: pm не стал доступен за ${timeout}s, продолжу попытки (возможно поздний старт)."
  return 1
}

# -------------------------
# Получаем "человеческое" название приложения (fallback -> package name)
get_app_name() {
  local pkg="$1"
  local app_name=""
  # пытаемся через dumpsys package
  app_name=$(dumpsys package "$pkg" 2>/dev/null | awk -F'=' '
    /application-label:/ { lbl=$2; gsub(/^[ \t]+|[ \t]+$/, "", lbl); if (lbl!="") {print lbl; exit} }
    /label=/ { lbl=$2; gsub(/^[ \t]+|[ \t]+$/, "", lbl); if (lbl!="") {print lbl; exit} }
  ')
  if [ -n "$app_name" ]; then
    printf "%s" "$app_name"
  else
    printf "%s" "$pkg"
  fi
}

# -------------------------
# Отправка уведомления — пытаемся от system (UID 2000), иначе обычный cmd notification
notification_send() {
  # $1 - package name
  if [ "$NOTIFICATION" != "1" ]; then
    dbg "Уведомления отключены (NOTIFICATION=$NOTIFICATION)"
    return 1
  fi

  local pkg="$1"
  local app_name
  app_name=$(get_app_name "$pkg")
  local BODY="Внимание обнаружен вирус, в целях безопасности он будет удален: $app_name"
  local TAG="antivirus"

  local esc_BODY
  esc_BODY=$(_escape_single_quotes "$BODY")
  local esc_TITLE
  esc_TITLE=$(_escape_single_quotes "$TITLE")

  # Сформируем команду
  # Обратите внимание: некоторые реализации cmd notification ожидают немного другой синтаксис,
  # но общий вариант:
  cmdstr="cmd notification post -i $ICON_PATH -I $ICON_PATH -S $STYLE --conversation 'System' --message '$TITLE:$esc_BODY' -t '$esc_TITLE' '$TAG' '$esc_BODY'"

  # Попытка отправки от system (UID 2000) через su -lp 2000 -c
  if su -lp 2000 -c "$cmdstr" >/dev/null 2>&1; then
    log "Уведомление отправлено (system): $BODY"
    return 0
  fi

  # fallback: просто cmd notification (если su не работает)
  if sh -c "$cmdstr" >/dev/null 2>&1; then
    log "Уведомление отправлено (fallback): $BODY"
    return 0
  fi

  log "Не удалось отправить уведомление: $BODY"
  return 1
}

# -------------------------
# Проверяем, установлен ли пакет (надёжно) — возвращаем 0 если установлен
_pkg_installed() {
  local p="$1"
  if [ -z "$p" ]; then
    return 1
  fi
  # pm path возвращает код 0 если пакет установлен
  if pm path "$p" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# -------------------------
# Удаляем пакет с учётом прав/контекста
_remove_one_package() {
  local pkg="$1"
  [ -n "$pkg" ] || return 1
  log "Обрабатываю пакет: $pkg"

  # Останавливаем приложение (если работает)
  am force-stop "$pkg" >/dev/null 2>&1 || true

  # Сначала безопасное удаление для пользователя 0
  if pm uninstall --user 0 "$pkg" >/dev/null 2>&1; then
    log "Пакет $pkg удалён для user 0 (pm uninstall --user 0)."
    return 0
  fi

  # Если запустили от root — пробуем полное удаление
  if [ "$(id -u 2>/dev/null || echo 0)" = "0" ]; then
    # Попытка pm uninstall (может удалить system-пакет, если возможно)
    if pm uninstall "$pkg" >/dev/null 2>&1; then
      log "Пакет $pkg полностью удалён (pm uninstall)."
      return 0
    fi
    # Ещё одна попытка через su (если вызывается из не-root контекста)
    if su -c "pm uninstall '$pkg'" >/dev/null 2>&1; then
      log "Пакет $pkg удалён через su pm uninstall."
      return 0
    fi
  else
    # Если не root, но доступен su, пробуем через su
    if su -c "pm uninstall '$pkg'" >/dev/null 2>&1; then
      log "Пакет $pkg удалён через su pm uninstall."
      return 0
    fi
  fi

  # Если не удалось — логируем путь APK (если есть) для ручного анализа
  APK_PATH=$(pm path "$pkg" 2>/dev/null | sed 's/^package://g' | tr '\n' ' ' | sed 's/ $//')
  if [ -n "$APK_PATH" ]; then
    log "Не удалось удалить $pkg штатно. Найден путь APK: $APK_PATH"
  else
    log "Не удалось удалить $pkg и путь APK неизвестен."
  fi

  return 2
}

# -------------------------
process_list_file() {
  # Подготавливаем/копируем/нормализуем исходный файл
  _prepare_packages_file || return 1

  # Если pm ещё не готов — подождём (до 60s)
  _wait_for_pm 60

  # Читаем подготовленный файл
  while IFS= read -r line || [ -n "$line" ]; do
    # Обрезаем пробелы
    pkg="$(printf "%s" "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -z "$pkg" ] && continue
    case "$pkg" in
      \#*) continue ;; # комментарий
    esac
    # Берём только первое слово (защита от лишних полей)
    pkg=$(printf "%s" "$pkg" | awk '{print $1}')
    dbg "Строка->пакет: '$pkg'"

    if _pkg_installed "$pkg"; then
      notification_send "$pkg"
      _remove_one_package "$pkg"
    else
      log "Пакет $pkg не установлен, пропускаю."
    fi
  done < "$PACKAGES_FILE_TO_READ"
}

# -------------------------
_cleanup() {
  log "Скрипт получает сигнал на завершение, выхожу."
  # можно удалить временные файлы
  [ -f "$TMP_PACKAGES" ] && rm -f "$TMP_PACKAGES" 2>/dev/null || true
  exit 0
}
trap _cleanup INT TERM EXIT

# -------------------------
# MAIN
log "Старт скрипта uninstall_from_list.sh (PID $$). Файл пакетов: $PACKAGES_FILE"

# Ждём, чтобы система успела загрузиться
sleep "$SLEEP_BEFORE_START"

# Первый проход
process_list_file

# Циклическая проверка
while true; do
  sleep "$LOOP_INTERVAL"
  process_list_file
done
