(
CONFIG_PATH="/opt/etc/mihomo/config.yaml"
PROVIDER_DIR="/opt/etc/mihomo/proxy-providers"
UPDATE_SCRIPT="/opt/etc/mihomo/update-config.sh"
UPDATE_VERSIONS_SCRIPT="/opt/etc/mihomo/update-versions.sh"

GROUPS_RULES_URL="https://raw.githubusercontent.com/dorian6996/Mihomo-HWID-Subscription/main/template.yaml"
XKEEN_TARBALL_URL="https://github.com/jameszeroX/XKeen/releases/latest/download/xkeen.tar.gz"
MIHOMO_RELEASE_API="https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
MIHOMO_DOWNLOAD_BASE="https://github.com/MetaCubeX/mihomo/releases/download"
YQ_UPSTREAM_BASE="https://github.com/mikefarah/yq/releases/latest/download"
YQ_WORKAROUND_BASE="https://github.com/jameszeroX/yq/releases/latest/download"

progress_wait() {
  message="$1"
  shift

  printf "  %s" "$message"
  "$@" >/dev/null 2>&1 &
  pid="$!"

  while kill -0 "$pid" 2>/dev/null; do
    printf "."
    sleep 2
  done

  wait "$pid"
  rc="$?"

  if [ "$rc" -eq 0 ]; then
    echo " готово"
  else
    echo " ошибка"
  fi

  return "$rc"
}

download_file_attempts() {
  url="$1"
  output="$2"

  rm -f "$output"

  if curl -fsSL --connect-timeout 10 -m 90 "$url" -o "$output"; then
    return 0
  fi

  if curl -fsSL --connect-timeout 10 -m 90 "https://gh-proxy.com/$url" -o "$output"; then
    return 0
  fi

  if curl -fsSL --connect-timeout 10 -m 90 "https://ghfast.top/$url" -o "$output"; then
    return 0
  fi

  rm -f "$output"
  return 1
}

download_file() {
  url="$1"
  output="$2"
  label="$3"

  if progress_wait "Загрузка $label" download_file_attempts "$url" "$output"; then
    return 0
  fi

  echo "Не удалось загрузить $label."
  return 1
}

xkeen_is_installed() {
  [ -x /opt/sbin/xkeen ] &&
    [ -f /opt/sbin/.xkeen/import.sh ] &&
    [ -x /opt/etc/init.d/S05xkeen ]
}

mihomo_is_installed() {
  [ -x /opt/sbin/mihomo ] &&
    [ -x /opt/sbin/yq ] &&
    /opt/sbin/mihomo -v >/dev/null 2>&1 &&
    /opt/sbin/yq --version >/dev/null 2>&1
}

xkeen_run() {
  if command -v xkeen >/dev/null 2>&1; then
    XKEEN_FOREGROUND=1 xkeen "$@"
  else
    XKEEN_FOREGROUND=1 /opt/sbin/xkeen "$@"
  fi
}

restart_xkeen() {
  xkeen_run -restart
}

install_xkeen_packages() {
  command -v opkg >/dev/null 2>&1 || return 0

  progress_wait "Обновление списка пакетов Entware" opkg update || return 1

  for package in curl jq ip-full iptables ipset ca-bundle coreutils-uname coreutils-nohup; do
    if ! opkg list-installed 2>/dev/null | grep -q "^$package "; then
      progress_wait "Установка пакета $package" opkg install "$package" || return 1
    fi
  done
}

detect_xkeen_architecture() {
  ARCHITECTURE=""
  SOFTFLOAT=""

  if command -v opkg >/dev/null 2>&1; then
    opkg_arch="$(opkg print-architecture 2>/dev/null | awk '!/all/ {print $2; exit}' | cut -d- -f1)"
    case "$opkg_arch" in
      *aarch64*) ARCHITECTURE="arm64-v8a" ;;
      *mipsel*) ARCHITECTURE="mips32le" ;;
      *mips*) ARCHITECTURE="mips32" ;;
    esac
  fi

  if [ -z "$ARCHITECTURE" ]; then
    uname_arch="$(uname -m 2>/dev/null)"
    case "$uname_arch" in
      aarch64|arm64) ARCHITECTURE="arm64-v8a" ;;
      mipsel*|mipsle*) ARCHITECTURE="mips32le" ;;
      mips*) ARCHITECTURE="mips32" ;;
    esac
  fi

  if [ "$ARCHITECTURE" = "mips32le" ]; then
    router_version="$(curl -fsS --connect-timeout 2 -m 5 "localhost:79/rci/show/version" 2>/dev/null || ndmc -c 'show version' 2>/dev/null)"
    case "$router_version" in
      *KN-1212*|*KN-2310*|*KN-2311*|*KN-2910*) SOFTFLOAT="true" ;;
    esac
  fi

  case "$ARCHITECTURE" in
    arm64-v8a|mips32le|mips32) return 0 ;;
  esac

  echo "Не удалось определить поддерживаемую архитектуру Entware."
  return 1
}

latest_mihomo_version() {
  for prefix in "" "https://gh-proxy.com/" "https://ghfast.top/"; do
    version="$(
      curl -fsSL --connect-timeout 10 -m 30 "${prefix}${MIHOMO_RELEASE_API}" 2>/dev/null |
        sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
        head -n 1
    )"
    [ -n "$version" ] && echo "$version" && return 0
  done

  return 1
}

download_mihomo_binary() {
  detect_xkeen_architecture || return 1

  version="$(latest_mihomo_version)"
  if [ -z "$version" ]; then
    echo "Не удалось получить последнюю версию Mihomo."
    return 1
  fi

  case "$ARCHITECTURE" in
    arm64-v8a)
      mihomo_asset="mihomo-linux-arm64-$version.gz"
      yq_asset="yq_linux_arm64"
      yq_base="$YQ_UPSTREAM_BASE"
      ;;
    mips32le)
      if [ "$SOFTFLOAT" = "true" ]; then
        mihomo_asset="mihomo-linux-mipsle-softfloat-$version.gz"
        yq_base="$YQ_WORKAROUND_BASE"
      else
        mihomo_asset="mihomo-linux-mipsle-hardfloat-$version.gz"
        yq_base="$YQ_UPSTREAM_BASE"
      fi
      yq_asset="yq_linux_mipsle"
      ;;
    mips32)
      mihomo_asset="mihomo-linux-mips-hardfloat-$version.gz"
      yq_asset="yq_linux_mips"
      yq_base="$YQ_UPSTREAM_BASE"
      ;;
  esac

  mkdir -p /opt/sbin /tmp/xkeen-mihomo

  if ! /opt/sbin/yq --version >/dev/null 2>&1; then
    download_file "$yq_base/$yq_asset" "/opt/sbin/yq" "yq" || return 1
    chmod +x /opt/sbin/yq
  fi

  mihomo_gz="/tmp/xkeen-mihomo/mihomo.gz"
  mihomo_tmp="/tmp/xkeen-mihomo/mihomo"

  download_file "$MIHOMO_DOWNLOAD_BASE/$version/$mihomo_asset" "$mihomo_gz" "Mihomo $version" || return 1
  if ! gzip -cd "$mihomo_gz" > "$mihomo_tmp"; then
    rm -f "$mihomo_gz" "$mihomo_tmp"
    echo "Не удалось распаковать Mihomo."
    return 1
  fi

  mv "$mihomo_tmp" /opt/sbin/mihomo
  chmod +x /opt/sbin/mihomo
  rm -f "$mihomo_gz"

  if ! /opt/sbin/mihomo -v >/dev/null 2>&1; then
    echo "Установленный Mihomo не запускается."
    return 1
  fi
}

install_xkeen_distribution() {
  mkdir -p /opt/sbin /tmp/xkeen-mihomo
  xkeen_archive="/tmp/xkeen-mihomo/xkeen.tar.gz"
  xkeen_extract_dir="/tmp/xkeen-mihomo/xkeen-dist"

  download_file "$XKEEN_TARBALL_URL" "$xkeen_archive" "XKeen" || return 1
  if ! tar -tzf "$xkeen_archive" >/dev/null 2>&1; then
    rm -f "$xkeen_archive"
    echo "Архив XKeen повреждён или имеет неверный формат."
    return 1
  fi

  rm -rf "$xkeen_extract_dir"
  mkdir -p "$xkeen_extract_dir"

  if ! tar -xzf "$xkeen_archive" -C "$xkeen_extract_dir"; then
    rm -rf "$xkeen_extract_dir"
    rm -f "$xkeen_archive"
    echo "Не удалось распаковать XKeen."
    return 1
  fi

  if [ -d "$xkeen_extract_dir/_xkeen" ]; then
    xkeen_scripts_dir="$xkeen_extract_dir/_xkeen"
  elif [ -d "$xkeen_extract_dir/.xkeen" ]; then
    xkeen_scripts_dir="$xkeen_extract_dir/.xkeen"
  else
    rm -rf "$xkeen_extract_dir"
    rm -f "$xkeen_archive"
    echo "В архиве XKeen не найдены скрипты."
    return 1
  fi

  if [ ! -f "$xkeen_extract_dir/xkeen" ]; then
    rm -rf "$xkeen_extract_dir"
    rm -f "$xkeen_archive"
    echo "В архиве XKeen не найден запускной файл."
    return 1
  fi

  mv -f "$xkeen_extract_dir/xkeen" /opt/sbin/xkeen
  rm -rf /opt/sbin/.xkeen /opt/sbin/_xkeen
  mv "$xkeen_scripts_dir" /opt/sbin/.xkeen
  chmod +x /opt/sbin/xkeen
  rm -rf "$xkeen_extract_dir"
  rm -f "$xkeen_archive"
}

register_xkeen_offline() {
  if ! printf '1\n1\n' | XKEEN_FOREGROUND=1 /opt/sbin/xkeen -io; then
    echo "Не удалось выполнить offline-установку XKeen."
    exit 1
  fi
}

ensure_xkeen_mihomo() {
  if xkeen_is_installed; then
    echo "XKeen уже установлен."
    if ! mihomo_is_installed; then
      echo "Установка Mihomo"
      download_mihomo_binary || exit 1
      register_xkeen_offline
    fi
    xkeen_run -mihomo >/dev/null 2>&1 || true
    return 0
  fi

  install_xkeen_packages || exit 1
  echo "Установка Mihomo"
  download_mihomo_binary || exit 1
  echo "Установка XKeen"
  install_xkeen_distribution || exit 1

  register_xkeen_offline
  xkeen_run -mihomo >/dev/null 2>&1 || true
}

echo
echo "=== Mihomo HWID Subscription Installer ==="
echo

ensure_xkeen_mihomo

CONFIG_EXISTS=0
[ -f "$CONFIG_PATH" ] && CONFIG_EXISTS=1

if [ "$CONFIG_EXISTS" -eq 1 ]; then
  echo "Конфиг найден."
  echo "1) Добавить новую подписку"
  echo "2) Заменить существующие подписки"
  echo "3) Полностью заменить конфиг"
  echo
  echo "0) Отмена"
  printf "Выберите [1-3,0]: "
  read MODE

  [ "$MODE" = "0" ] && echo "Отменено." && exit 0

  if [ "$MODE" = "3" ]; then
    echo
    echo "Какой конфиг установить?"
    echo "1) Полный"
    echo "2) Минимальный"
    echo
    echo "0) Отмена"
    printf "Выберите [0-2]: "
    read SUBMODE

    case "$SUBMODE" in
      0)
        echo "Отменено."
        exit 0
        ;;
      1)
        MODE="FULL"
        ;;
      2)
        MODE="MINIMAL"
        ;;
      *)
        echo "Неверный выбор."
        exit 1
        ;;
    esac
  fi

else
  echo "Конфиг не найден."
  echo "1) Создать полный конфиг"
  echo "2) Создать минимальный конфиг (global mode)"
  echo
  echo "0) Отмена"
  printf "Выберите [1-2]: "
  read MODE

  [ "$MODE" = "0" ] && echo "Отменено." && exit 0

  if [ "$MODE" = "1" ]; then
    MODE="FULL"
  fi

  if [ "$MODE" = "2" ]; then
    MODE="MINIMAL"
  fi
fi

printf "Введите ссылку подписки: "
IFS= read -r SUB_URL
[ -z "$SUB_URL" ] && echo "Ссылка не указана." && exit 0

mkdir -p "$PROVIDER_DIR"

NDM_INFO="$(ndmc -c 'show version' 2>/dev/null)"
OS_VER="$(echo "$NDM_INFO" | awk '/title:/ {print $2}')"
MODEL_RAW="$(echo "$NDM_INFO" | awk -F': ' '/model:/ {print $2}')"
MODEL="$(echo "$MODEL_RAW" | tr ' ()' '--' | tr -cd '[:alnum:]._-\n')"

MAC_ADDR="$(cat /sys/class/net/br0/address 2>/dev/null || cat /sys/class/net/eth0/address)"
HWID="$(echo "$MAC_ADDR" | tr -d ':' | tr '[:lower:]' '[:upper:]')"

MIHOMO_VER="$(mihomo -v 2>/dev/null | head -n1 | grep -oE 'v[0-9]+(\.[0-9]+){1,2}')"
[ -z "$MIHOMO_VER" ] && MIHOMO_VER="v1.0.0"

HEADERS=$(curl -s -D - -o /dev/null \
  -H "x-hwid: $HWID" \
  -H "x-device-os: Keenetic OS" \
  -H "x-ver-os: $OS_VER" \
  -H "x-device-model: $MODEL" \
  -H "User-Agent: mihomo/$MIHOMO_VER" \
  "$SUB_URL")

PROFILE_NAME=$(echo "$HEADERS" | awk -F': ' 'tolower($1)=="profile-title" {print $2}' | tr -d '\r')

if echo "$PROFILE_NAME" | grep -q '^base64'; then
  RAW=$(echo "$PROFILE_NAME" | sed 's/^base64//')
  DECODED=$(echo "$RAW" | base64 -d 2>/dev/null)
  [ -n "$DECODED" ] && PROFILE_NAME="$DECODED"
fi

PROFILE_NAME=$(echo "$PROFILE_NAME" | tr -cd '[:alnum:]_ -')

[ -z "$PROFILE_NAME" ] && PROFILE_NAME="sub$(date +%d%m%y)"

BASE_NAME="$PROFILE_NAME"
PROVIDER_NAME="$BASE_NAME"
i=2

escape_for_grep() {
  printf '%s' "$1" | sed -e 's/[][\.*^$\/]/\\&/g'
}

escaped_name=$(escape_for_grep "$PROVIDER_NAME")

while grep -qE "^[[:space:]]*(\"$escaped_name\"|'$escaped_name'|$escaped_name)[[:space:]]*:" "$CONFIG_PATH" 2>/dev/null; do
  PROVIDER_NAME="${BASE_NAME}_$i"
  escaped_name=$(escape_for_grep "$PROVIDER_NAME")
  i=$((i+1))
done

echo "Название подписки: $PROVIDER_NAME"

if [ "$CONFIG_EXISTS" -eq 1 ] && [ "$MODE" = "1" ]; then

  awk '
  BEGIN {done=0}
  /proxy-providers:/ && done==0 {
    print
    print "  '"$PROVIDER_NAME"':"
    print "    type: http"
    print "    url: \"'"$SUB_URL"'\""
    print "    path: ./proxy-providers/'"$PROVIDER_NAME"'.yaml"
    print "    interval: 3600"
    print "    header:"
    print "      User-Agent:"
    print "        - \"mihomo/'"$MIHOMO_VER"'\""
    print "      x-hwid:"
    print "        - \"'"$HWID"'\""
    print "      x-device-os:"
    print "        - \"Keenetic OS\""
    print "      x-ver-os:"
    print "        - \"'"$OS_VER"'\""
    print "      x-device-model:"
    print "        - \"'"$MODEL"'\""
    print "    health-check:"
    print "      enable: true"
    print "      url: http://www.msftncsi.com/ncsi.txt"
    print "      interval: 3000"
    done=1
    next
  }
  {print}
  ' "$CONFIG_PATH" > "$CONFIG_PATH.tmp" && mv "$CONFIG_PATH.tmp" "$CONFIG_PATH"

  echo "Подписка добавлена."
  restart_xkeen
  exit 0
fi

if [ "$CONFIG_EXISTS" -eq 1 ] && { [ "$MODE" = "2" ] || [ "$MODE" = "MINIMAL" ]; }; then
  if [ -f "$CONFIG_PATH" ]; then
    sed -i '/proxy-providers:/,/proxy-groups:/d' "$CONFIG_PATH"
  fi
  echo "Подписки удалены (providers)."
  exit 0
fi

if [ "$MODE" = "MINIMAL" ]; then
  cat > "$CONFIG_PATH" <<EOF
listeners:
- name: tproxy
  type: tproxy
  port: 1181
mixed-port: 1080
allow-lan: true
mode: global
log-level: silent
ipv6: false
external-controller: 0.0.0.0:9090
external-ui: ./zash
external-ui-url: https://github.com/Zephyruso/zashboard/releases/latest/download/dist-cdn-fonts.zip
proxy-providers:
  $PROVIDER_NAME:
    type: http
    url: "$SUB_URL"
    path: ./proxy-providers/${PROVIDER_NAME}.yaml
    interval: 3600
    header:
      User-Agent:
        - "mihomo/$MIHOMO_VER"
      x-hwid:
        - "$HWID"
      x-device-os:
        - "Keenetic OS"
      x-ver-os:
        - "$OS_VER"
      x-device-model:
        - "$MODEL"
    health-check:
      enable: true
      url: http://www.msftncsi.com/ncsi.txt
      interval: 3000
EOF

  echo "Минимальный конфиг создан."
  restart_xkeen
  exit 0
fi

if [ "$MODE" = "FULL" ]; then
  cat > "$CONFIG_PATH" <<EOF
listeners:
  - name: tproxy
    type: tproxy
    port: 1181
mixed-port: 1080
tcp-concurrent: true
allow-lan: true
unified-delay: true
mode: rule
log-level: silent
ipv6: false
external-controller: 0.0.0.0:9090
external-ui: ./zash
external-ui-url: "https://github.com/Zephyruso/zashboard/releases/latest/download/dist-cdn-fonts.zip"
profile:
  store-selected: true
find-process-mode: always
sniffer:
  enable: true
  force-dns-mapping: true
  parse-pure-ip: true
  override-destination: false
  sniff:
    HTTP:
      ports: [80]
      override-destination: true
    TLS:
      ports: [443]
    QUIC:
      ports: [443]
proxy-providers:
  $PROVIDER_NAME:
    type: http
    url: "$SUB_URL"
    path: ./proxy-providers/${PROVIDER_NAME}.yaml
    interval: 3600
    header:
      User-Agent:
        - "mihomo/$MIHOMO_VER"
      x-hwid:
        - "$HWID"
      x-device-os:
        - "Keenetic OS"
      x-ver-os:
        - "$OS_VER"
      x-device-model:
        - "$MODEL"
    health-check:
      enable: true
      url: http://www.msftncsi.com/ncsi.txt
      interval: 3000
EOF

  GROUPS_RULES_TMP="/tmp/template-$$.yaml"
  if curl -fsSL "$GROUPS_RULES_URL" -o "$GROUPS_RULES_TMP" 2>/dev/null; then
    cat "$GROUPS_RULES_TMP" >> "$CONFIG_PATH"
    rm -f "$GROUPS_RULES_TMP"
    echo "proxy-groups и rules загружены с GitHub."
  else
    echo "ВНИМАНИЕ: не удалось загрузить template.yaml с GitHub."
    echo "Проверьте URL: $GROUPS_RULES_URL"
    rm -f "$GROUPS_RULES_TMP"
    exit 1
  fi

  echo
  echo "Автоматически обновлять файл конфигурации каждые 3 дня?"
  echo "1) Да — установить обновление по расписанию"
  echo "2) Нет — пропустить"
  printf "Выберите [1-2]: "
  read CRON_CHOICE

  if [ "$CRON_CHOICE" = "2" ]; then
    echo "Крон не установлен."
    echo "Полный конфиг установлен."
    restart_xkeen
    echo "Готово."
    exit 0
  fi

  # Скрипт обновления template (proxy-groups + rules)
  cat > "$UPDATE_SCRIPT" <<'UPDATEEOF'
#!/bin/sh
CONFIG_PATH="/opt/etc/mihomo/config.yaml"
GROUPS_RULES_URL="PLACEHOLDER_URL"
TMP_FILE="/tmp/template-update.yaml"
BACKUP="$CONFIG_PATH.bak"

[ ! -f "$CONFIG_PATH" ] && exit 1

if ! curl -fsSL "$GROUPS_RULES_URL" -o "$TMP_FILE" 2>/dev/null; then
  exit 1
fi

cp "$CONFIG_PATH" "$BACKUP"

awk '/^proxy-groups:/{exit} {print}' "$CONFIG_PATH" > "$CONFIG_PATH.tmp"
cat "$TMP_FILE" >> "$CONFIG_PATH.tmp"
mv "$CONFIG_PATH.tmp" "$CONFIG_PATH"
rm -f "$TMP_FILE"

if command -v xkeen >/dev/null 2>&1; then
  XKEEN_FOREGROUND=1 xkeen -restart
else
  XKEEN_FOREGROUND=1 /opt/sbin/xkeen -restart
fi
UPDATEEOF

  sed -i "s|PLACEHOLDER_URL|$GROUPS_RULES_URL|g" "$UPDATE_SCRIPT"
  chmod +x "$UPDATE_SCRIPT"

  cat > "$UPDATE_VERSIONS_SCRIPT" <<'VERSEOF'
#!/bin/sh
CONFIG_PATH="/opt/etc/mihomo/config.yaml"

[ ! -f "$CONFIG_PATH" ] && exit 1

NDM_INFO="$(ndmc -c 'show version' 2>/dev/null)"
OS_VER="$(echo "$NDM_INFO" | awk '/title:/ {print $2}')"

MIHOMO_VER="$(mihomo -v 2>/dev/null | head -n1 | grep -oE 'v[0-9]+(\.[0-9]+){1,2}')"
[ -z "$MIHOMO_VER" ] && MIHOMO_VER="v1.0.0"

cp "$CONFIG_PATH" "$CONFIG_PATH.bak"

awk -v ua="mihomo/$MIHOMO_VER" -v osver="$OS_VER" '
{
  line = $0

  if (line ~ /^[[:space:]]+-[[:space:]]+"mihomo\/v[0-9]/) {
    sub(/"mihomo\/v[0-9][^"]*"/, "\"" ua "\"", line)
    print line
    next
  }

  if (prev_key ~ /x-ver-os/ && line ~ /^[[:space:]]+-[[:space:]]+"/) {
    sub(/"[^"]*"/, "\"" osver "\"", line)
    print line
    next
  }

  if (line ~ /^[[:space:]]+x-[a-z-]+[[:space:]]*:/) {
    match(line, /x-[a-z-]+/)
    prev_key = substr(line, RSTART, RLENGTH)
  } else if (line !~ /^[[:space:]]+-[[:space:]]*"/) {
    prev_key = ""
  }

  print line
}
' "$CONFIG_PATH" > "$CONFIG_PATH.tmp" && mv "$CONFIG_PATH.tmp" "$CONFIG_PATH"

VERSEOF

  chmod +x "$UPDATE_VERSIONS_SCRIPT"

  CRON_JOB="0 5 */3 * * $UPDATE_SCRIPT >> /opt/var/log/mihomo-update.log 2>&1"
  CRON_MARKER="# mihomo-config-update"

  if crontab -l 2>/dev/null | grep -q "$CRON_MARKER"; then
    crontab -l 2>/dev/null | grep -v "$CRON_MARKER" | { cat; echo "$CRON_JOB $CRON_MARKER"; } | crontab -
  else
    (crontab -l 2>/dev/null; echo "$CRON_JOB $CRON_MARKER") | crontab -
  fi

  CRON_VER="50 4 * * 0 $UPDATE_VERSIONS_SCRIPT >> /opt/var/log/mihomo-update.log 2>&1"
  CRON_VER_MARKER="# mihomo-versions-update"

  if crontab -l 2>/dev/null | grep -q "$CRON_VER_MARKER"; then
    crontab -l 2>/dev/null | grep -v "$CRON_VER_MARKER" | { cat; echo "$CRON_VER $CRON_VER_MARKER"; } | crontab -
  else
    (crontab -l 2>/dev/null; echo "$CRON_VER $CRON_VER_MARKER") | crontab -
  fi

  echo "Расписание установлено: каждый 3й день в 5:00."
  echo "Полный конфиг установлен."
  restart_xkeen
  echo "Готово."
fi
)
