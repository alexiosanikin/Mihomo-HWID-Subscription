(
CONFIG_PATH="/opt/etc/mihomo/config.yaml"
PROVIDER_DIR="/opt/etc/mihomo/proxy-providers"
UPDATE_SCRIPT="/opt/etc/mihomo/update-config.sh"


GROUPS_RULES_URL="https://raw.githubusercontent.com/dorian6996/Mihomo-HWID-Subscription/main/template.yaml"

echo
echo "=== Mihomo HWID Subscription Installer ==="
echo

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
    print "        - \"KeeneticOS\""
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
  xkeen -restart
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
        - "KeeneticOS"
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
  xkeen -restart
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
        - "KeeneticOS"
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
    xkeen -restart
    echo "Готово."
    exit 0
  fi
 
  cat > "$UPDATE_SCRIPT" <<'UPDATEEOF'
#!/bin/sh


CONFIG_PATH="/opt/etc/mihomo/config.yaml"
GROUPS_RULES_URL="PLACEHOLDER_URL"
TMP_FILE="/tmp/template-update.yaml"
BACKUP="$CONFIG_PATH.bak"

[ ! -f "$CONFIG_PATH" ] && echo "Конфиг не найден: $CONFIG_PATH" && exit 1


if ! curl -fsSL "$GROUPS_RULES_URL" -o "$TMP_FILE" 2>/dev/null; then
  echo "Ошибка загрузки $GROUPS_RULES_URL"
  exit 1
fi


cp "$CONFIG_PATH" "$BACKUP"


awk '/^proxy-groups:/{exit} {print}' "$CONFIG_PATH" > "$CONFIG_PATH.tmp"
cat "$TMP_FILE" >> "$CONFIG_PATH.tmp"
mv "$CONFIG_PATH.tmp" "$CONFIG_PATH"
rm -f "$TMP_FILE"

echo "Конфиг обновлён"
xkeen -restart
UPDATEEOF

  sed -i "s|PLACEHOLDER_URL|$GROUPS_RULES_URL|g" "$UPDATE_SCRIPT"
  chmod +x "$UPDATE_SCRIPT"

  
  CRON_JOB="0 5 */3 * * $UPDATE_SCRIPT >> /opt/var/log/mihomo-update.log 2>&1"
  CRON_MARKER="# mihomo-config-update"

  
  if crontab -l 2>/dev/null | grep -q "$CRON_MARKER"; then
    crontab -l 2>/dev/null | grep -v "$CRON_MARKER" | { cat; echo "$CRON_JOB $CRON_MARKER"; } | crontab -
    echo "Установка расписания обновления."
  else
    (crontab -l 2>/dev/null; echo "$CRON_JOB $CRON_MARKER") | crontab -
    echo "Расписание установленно: каждый 3й день в 5:00."
  fi

  echo "Полный конфиг установлен."
  xkeen -restart
  echo "Готово."
fi
)
