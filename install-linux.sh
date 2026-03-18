#!/bin/sh
# =============================================================
# Mihomo HWID Subscription Installer — Linux edition
# =============================================================

GROUPS_RULES_URL="https://raw.githubusercontent.com/dorian6996/Mihomo-HWID-Subscription/main/template.yaml"

# ── Проверка root ────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
  echo "Запустите скрипт от root или через sudo."
  exit 1
fi

# ── Определяем директорию конфига ───────────────────────────
for candidate in /etc/mihomo /usr/local/etc/mihomo /opt/mihomo /opt/etc/mihomo; do
  if [ -d "$candidate" ]; then
    MIHOMO_DIR="$candidate"
    break
  fi
done
if [ -z "$MIHOMO_DIR" ]; then
  MIHOMO_DIR="/etc/mihomo"
  mkdir -p "$MIHOMO_DIR"
fi

CONFIG_PATH="$MIHOMO_DIR/config.yaml"
PROVIDER_DIR="$MIHOMO_DIR/proxy-providers"
UPDATE_SCRIPT="$MIHOMO_DIR/update-config.sh"
UPDATE_VERSIONS_SCRIPT="$MIHOMO_DIR/update-versions.sh"
LOG_FILE="/var/log/mihomo-update.log"

if command -v systemctl >/dev/null 2>&1 && systemctl list-units --type=service 2>/dev/null | grep -q mihomo; then
  RESTART_CMD="systemctl restart mihomo"
elif command -v service >/dev/null 2>&1 && service --status-all 2>/dev/null | grep -q mihomo; then
  RESTART_CMD="service mihomo restart"
elif [ -f /etc/init.d/mihomo ]; then
  RESTART_CMD="/etc/init.d/mihomo restart"
else
  MIHOMO_BIN="$(command -v mihomo 2>/dev/null)"
  if [ -n "$MIHOMO_BIN" ]; then
    RESTART_CMD="sh -c 'pkill mihomo 2>/dev/null; sleep 1; $MIHOMO_BIN -d $MIHOMO_DIR &'"
  else
    RESTART_CMD="echo 'Перезапустите mihomo вручную'"
  fi
fi

echo
echo "=== Mihomo HWID Subscription Installer (Linux) ==="
echo "  Конфиг:  $CONFIG_PATH"
echo "  Рестарт: $RESTART_CMD"
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
      0) echo "Отменено."; exit 0 ;;
      1) MODE="FULL" ;;
      2) MODE="MINIMAL" ;;
      *) echo "Неверный выбор."; exit 1 ;;
    esac
  fi

else
  echo "Конфиг не найден."
  echo "1) Создать полный конфиг"
  echo "2) Создать минимальный конфиг (global mode)"
  echo
  echo "0) Отмена"
  printf "Выберите [1-2,0]: "
  read MODE
  [ "$MODE" = "0" ] && echo "Отменено." && exit 0
  [ "$MODE" = "1" ] && MODE="FULL"
  [ "$MODE" = "2" ] && MODE="MINIMAL"
fi

printf "Введите ссылку подписки: "
IFS= read -r SUB_URL
[ -z "$SUB_URL" ] && echo "Ссылка не указана." && exit 0

mkdir -p "$PROVIDER_DIR"

OS_VER="$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")"
[ -z "$OS_VER" ] && OS_VER="$(uname -sr)"

MODEL="$(hostname 2>/dev/null | tr ' ()' '--' | tr -cd '[:alnum:]._-')"
[ -z "$MODEL" ] && MODEL="linux-host"

MAC_ADDR=""
for iface in $(ls /sys/class/net/ 2>/dev/null); do
  case "$iface" in lo|docker*|veth*|tun*|tap*|br-*|virbr*|dummy*|wg*) continue ;; esac
  addr_file="/sys/class/net/$iface/address"
  if [ -f "$addr_file" ]; then
    addr="$(cat "$addr_file" 2>/dev/null)"
    if [ -n "$addr" ] && [ "$addr" != "00:00:00:00:00:00" ]; then
      MAC_ADDR="$addr"
      break
    fi
  fi
done
[ -z "$MAC_ADDR" ] && echo "Не удалось определить MAC-адрес." && exit 1

HWID="$(echo "$MAC_ADDR" | tr -d ':' | tr '[:lower:]' '[:upper:]')"

MIHOMO_VER="$(mihomo -v 2>/dev/null | head -n1 | grep -oE 'v[0-9]+(\.[0-9]+){1,2}')"
[ -z "$MIHOMO_VER" ] && MIHOMO_VER="v1.0.0"

# ── Имя подписки из заголовков ──────────────────────────────
HEADERS=$(curl -s -D - -o /dev/null \
  -H "x-hwid: $HWID" \
  -H "x-device-os: Linux" \
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

escape_for_grep() { printf '%s' "$1" | sed -e 's/[][\.*^$\/]/\\&/g'; }

escaped_name=$(escape_for_grep "$PROVIDER_NAME")
while grep -qE "^[[:space:]]*(\"$escaped_name\"|'$escaped_name'|$escaped_name)[[:space:]]*:" "$CONFIG_PATH" 2>/dev/null; do
  PROVIDER_NAME="${BASE_NAME}_$i"
  escaped_name=$(escape_for_grep "$PROVIDER_NAME")
  i=$((i+1))
done

echo "Название подписки: $PROVIDER_NAME"


PROVIDER_BLOCK="  $PROVIDER_NAME:
    type: http
    url: \"$SUB_URL\"
    path: ./proxy-providers/${PROVIDER_NAME}.yaml
    interval: 3600
    header:
      User-Agent:
        - \"mihomo/$MIHOMO_VER\"
      x-hwid:
        - \"$HWID\"
      x-device-os:
        - \"Linux\"
      x-ver-os:
        - \"$OS_VER\"
      x-device-model:
        - \"$MODEL\"
    health-check:
      enable: true
      url: http://www.msftncsi.com/ncsi.txt
      interval: 3000"

if [ "$CONFIG_EXISTS" -eq 1 ] && [ "$MODE" = "1" ]; then
  awk -v block="$PROVIDER_BLOCK" '
  BEGIN {done=0}
  /proxy-providers:/ && done==0 {
    print
    print block
    done=1
    next
  }
  {print}
  ' "$CONFIG_PATH" > "$CONFIG_PATH.tmp" && mv "$CONFIG_PATH.tmp" "$CONFIG_PATH"

  echo "Подписка добавлена."
  eval "$RESTART_CMD"
  exit 0
fi

if [ "$CONFIG_EXISTS" -eq 1 ] && { [ "$MODE" = "2" ] || [ "$MODE" = "MINIMAL" ]; }; then
  sed -i '/proxy-providers:/,/proxy-groups:/d' "$CONFIG_PATH"
  echo "Подписки удалены (providers)."
  exit 0
fi

if [ "$MODE" = "MINIMAL" ]; then
  cat > "$CONFIG_PATH" <<EOF
mixed-port: 7890
allow-lan: true
mode: global
log-level: warning
ipv6: false
external-controller: 0.0.0.0:9090
external-ui: ./zash
external-ui-url: "https://github.com/Zephyruso/zashboard/releases/latest/download/dist-cdn-fonts.zip"
proxy-providers:
$PROVIDER_BLOCK
EOF

  echo "Минимальный конфиг создан."
  eval "$RESTART_CMD"
  exit 0
fi

if [ "$MODE" = "FULL" ]; then
  cat > "$CONFIG_PATH" <<EOF
mixed-port: 7890
allow-lan: true
tcp-concurrent: true
enable-process: true
find-process-mode: always
mode: rule
log-level: warning
ipv6: false
keep-alive-interval: 30
unified-delay: false
profile:
  store-selected: true
  store-fake-ip: true
sniffer:
  enable: true
  force-dns-mapping: true
  parse-pure-ip: true
  sniff:
    HTTP:
      ports:
        - 80
        - 8080-8880
      override-destination: true
    TLS:
      ports:
        - 443
        - 8443
  skip-dst-address:
    - 0.0.0.0/8
    - 10.0.0.0/8
    - 100.64.0.0/10
    - 127.0.0.0/8
    - 169.254.0.0/16
    - 172.16.0.0/12
    - 192.0.0.0/24
    - 192.0.2.0/24
    - 192.88.99.0/24
    - 192.168.0.0/16
    - 198.51.100.0/24
    - 203.0.113.0/24
    - 224.0.0.0/3
    - ::/127
    - fc00::/7
    - fe80::/10
    - ff00::/8
tun:
  enable: true
  stack: mixed
  auto-route: true
  auto-detect-interface: true
  dns-hijack:
    - any:53
  strict-route: true
  mtu: 1500
dns:
  enable: true
  prefer-h3: false
  use-hosts: true
  use-system-hosts: true
  ipv6: false
  enhanced-mode: redir-host
  default-nameserver:
    - tls://1.1.1.1#VPN
    - https://94.140.14.14/dns-query#DIRECT
    - https://8.8.8.8/dns-query#DIRECT
  proxy-server-nameserver:
    - tls://1.1.1.1#VPN
    - https://94.140.14.14/dns-query#DIRECT
    - https://8.8.8.8/dns-query#DIRECT
  direct-nameserver:
    - tls://77.88.8.8#DIRECT
    - https://77.88.8.8/dns-query#DIRECT
  nameserver:
    - tls://94.140.14.14#Остальное
external-controller: 0.0.0.0:9090
external-ui: ./zash
external-ui-url: "https://github.com/Zephyruso/zashboard/releases/latest/download/dist-cdn-fonts.zip"
proxy-providers:
$PROVIDER_BLOCK
EOF

  # Загружаем proxy-groups + rules из template.yaml
  GROUPS_RULES_TMP="/tmp/template-$$.yaml"
  if curl -fsSL "$GROUPS_RULES_URL" -o "$GROUPS_RULES_TMP" 2>/dev/null; then
    cat "$GROUPS_RULES_TMP" >> "$CONFIG_PATH"
    rm -f "$GROUPS_RULES_TMP"
    echo "proxy-groups и rules загружены с GitHub."
  else
    echo "ВНИМАНИЕ: не удалось загрузить template.yaml с GitHub."
    rm -f "$GROUPS_RULES_TMP"
    exit 1
  fi

  # ── update-config.sh (cron 1: обновление proxy-groups/rules) ─
  cat > "$UPDATE_SCRIPT" <<EOF
#!/bin/sh
CONFIG_PATH="$CONFIG_PATH"
GROUPS_RULES_URL="$GROUPS_RULES_URL"
TMP_FILE="/tmp/template-update.yaml"

[ ! -f "\$CONFIG_PATH" ] && exit 1

if ! curl -fsSL "\$GROUPS_RULES_URL" -o "\$TMP_FILE" 2>/dev/null; then
  exit 1
fi

cp "\$CONFIG_PATH" "\$CONFIG_PATH.bak"
awk '/^proxy-groups:/{exit} {print}' "\$CONFIG_PATH" > "\$CONFIG_PATH.tmp"
cat "\$TMP_FILE" >> "\$CONFIG_PATH.tmp"
mv "\$CONFIG_PATH.tmp" "\$CONFIG_PATH"
rm -f "\$TMP_FILE"

$RESTART_CMD
EOF
  chmod +x "$UPDATE_SCRIPT"

  # ── update-versions.sh (cron 2: обновление User-Agent/OS) ────
  cat > "$UPDATE_VERSIONS_SCRIPT" <<EOF
#!/bin/sh
CONFIG_PATH="$CONFIG_PATH"

[ ! -f "\$CONFIG_PATH" ] && exit 1

OS_VER="\$(. /etc/os-release 2>/dev/null && echo "\$PRETTY_NAME")"
[ -z "\$OS_VER" ] && OS_VER="\$(uname -sr)"

MIHOMO_VER="\$(mihomo -v 2>/dev/null | head -n1 | grep -oE 'v[0-9]+(\.[0-9]+){1,2}')"
[ -z "\$MIHOMO_VER" ] && MIHOMO_VER="v1.0.0"

cp "\$CONFIG_PATH" "\$CONFIG_PATH.bak"

awk -v ua="mihomo/\$MIHOMO_VER" -v osver="\$OS_VER" '
{
  line = \$0
  if (line ~ /^[[:space:]]+-[[:space:]]+"mihomo\\/v[0-9]/) {
    sub(/"mihomo\\/v[0-9][^"]*"/, "\\"" ua "\\"", line)
    print line
    next
  }
  if (prev_key ~ /x-ver-os/ && line ~ /^[[:space:]]+-[[:space:]]+"/) {
    sub(/"[^"]*"/, "\\"" osver "\\"", line)
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
' "\$CONFIG_PATH" > "\$CONFIG_PATH.tmp" && mv "\$CONFIG_PATH.tmp" "\$CONFIG_PATH"
EOF
  chmod +x "$UPDATE_VERSIONS_SCRIPT"

  CRON_JOB="0 5 */3 * * $UPDATE_SCRIPT >> $LOG_FILE 2>&1"
  CRON_MARKER="# mihomo-config-update"
  if crontab -l 2>/dev/null | grep -q "$CRON_MARKER"; then
    crontab -l 2>/dev/null | grep -v "$CRON_MARKER" | { cat; echo "$CRON_JOB $CRON_MARKER"; } | crontab -
  else
    (crontab -l 2>/dev/null; echo "$CRON_JOB $CRON_MARKER") | crontab -
  fi

  CRON_VER="50 4 * * 0 $UPDATE_VERSIONS_SCRIPT >> $LOG_FILE 2>&1"
  CRON_VER_MARKER="# mihomo-versions-update"
  if crontab -l 2>/dev/null | grep -q "$CRON_VER_MARKER"; then
    crontab -l 2>/dev/null | grep -v "$CRON_VER_MARKER" | { cat; echo "$CRON_VER $CRON_VER_MARKER"; } | crontab -
  else
    (crontab -l 2>/dev/null; echo "$CRON_VER $CRON_VER_MARKER") | crontab -
  fi

  echo "Расписание установлено: каждые 3 дня в 5:00 + версии каждое вс в 4:50."
  echo "Полный конфиг установлен."
  eval "$RESTART_CMD"
  echo "Готово."
fi
