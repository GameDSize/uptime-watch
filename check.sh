#!/usr/bin/env bash
# Внешний мониторинг доменов сервера 173.242.49.22 (инцидент 18–23.09.2026:
# api.playmaxwall.com и домены GMC отвечали 502 почти пять суток, никто не знал).
#
# Запускается GitHub Actions раз в 5 минут. Для каждой строки checks.txt —
# запрос; неудача перепроверяется через 20 с (чтобы не будить из-за одного
# сбоя сети). Сообщение в Telegram:
#   - DOWN при первом падении, повтор раз в час, пока лежит;
#   - UP при восстановлении, с длительностью простоя;
#   - раз в неделю (понедельник 09:00 UTC) — сводка «мониторинг жив».
# Состояние хранится в state.txt и коммитится при изменении — это же держит
# репозиторий «активным» (GitHub выключает расписание после 60 дней без активности).
set -u

UA="CashoutUptimeWatch/1.0 (+github actions)"
TIMEOUT="${CHECK_TIMEOUT:-15}"
RETRY_DELAY="${RETRY_DELAY:-20}"
REMIND_EVERY=3600
TG_API="${TG_API:-https://api.telegram.org}"
SCHEME="${SCHEME:-https}"
STATE=state.txt
NOW=$(date -u +%s)
touch "$STATE"

if [ -z "${TG_TOKEN:-}" ] || [ -z "${TG_CHAT:-}" ]; then
  echo "::error::нет секретов TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID"; exit 1
fi

tg() {
  local out
  out=$(curl -s -m 20 -X POST "$TG_API/bot${TG_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TG_CHAT}" --data-urlencode "text=$1" \
        -d disable_web_page_preview=true)
  case "$out" in *'"ok":true'*) echo "telegram: отправлено" ;; *) echo "::error::telegram не принял сообщение"; TG_FAILED=1 ;; esac
}
TG_FAILED=0

probe() { curl -s -o /dev/null -A "$UA" -m "$TIMEOUT" -w '%{http_code}' "$SCHEME://$1$2" 2>/dev/null || true; }

is_ok() { # code expect
  local c="${1:-000}"
  if [ "$2" = "up" ]; then [ "$c" != "000" ] && [ "$c" -lt 500 ]; else [ "$c" = "$2" ]; fi
}

human() { local s=$1; printf '%dч %02dмин' $((s/3600)) $((s%3600/60)); }

get_state() { awk -v k="$1" '$1==k {print $2, $3, $4; exit}' "$STATE"; }   # status since last_alert
set_state() { # key status since last_alert
  awk -v k="$1" '$1!=k' "$STATE" > "$STATE.tmp"; echo "$1 $2 $3 $4" >> "$STATE.tmp"; sort -o "$STATE" "$STATE.tmp"; rm -f "$STATE.tmp"
}

SUMMARY=""
DOWN_COUNT=0
while read -r host path expect; do
  case "$host" in ''|\#*) continue ;; esac
  key="$host$path"
  code=$(probe "$host" "$path"); code=${code:-000}
  if ! is_ok "$code" "$expect"; then
    sleep "$RETRY_DELAY"
    code=$(probe "$host" "$path"); code=${code:-000}
  fi
  read -r st since last <<<"$(get_state "$key")"
  st=${st:-UP}; since=${since:-$NOW}; last=${last:-0}
  want="ожидался $expect"; [ "$expect" = "up" ] && want="ожидался любой ответ, кроме 5xx"
  shown="$code"; [ "$code" = "000" ] && shown="нет соединения"
  if is_ok "$code" "$expect"; then
    echo "OK    $key → $code"
    if [ "$st" = "DOWN" ]; then
      tg "UP   $key → $code
Снова работает. Простой: $(human $((NOW - since))) (с $(date -u -d @"$since" '+%d.%m %H:%M') UTC)."
      set_state "$key" UP "$NOW" 0
    elif [ -z "$(get_state "$key")" ]; then
      set_state "$key" UP "$NOW" 0
    fi
    SUMMARY="$SUMMARY
OK    $key → $code"
  else
    echo "FAIL  $key → $shown ($want)"
    DOWN_COUNT=$((DOWN_COUNT + 1))
    if [ "$st" != "DOWN" ]; then
      tg "DOWN $key → $shown ($want)
Проверено дважды с интервалом ${RETRY_DELAY} с. Время: $(date -u '+%d.%m %H:%M') UTC.
Первое, что проверить на сервере: cd /root/penalty-crash-rgs-stage && scripts/check-domains.sh"
      set_state "$key" DOWN "$NOW" "$NOW"
    elif [ $((NOW - last)) -ge "$REMIND_EVERY" ]; then
      tg "ВСЁ ЕЩЁ DOWN $key → $shown. Лежит уже $(human $((NOW - since)))."
      set_state "$key" DOWN "$since" "$NOW"
    fi
    SUMMARY="$SUMMARY
FAIL  $key → $shown"
  fi
done < checks.txt

if [ "${HEARTBEAT:-false}" = "true" ] || [ "${TEST_ALERT:-false}" = "true" ]; then
  title="Мониторинг жив — еженедельная сводка"
  [ "${TEST_ALERT:-false}" = "true" ] && title="Тестовое сообщение мониторинга (ручной запуск)"
  tg "$title
$SUMMARY"
  awk '$1!="heartbeat"' "$STATE" > "$STATE.tmp"; echo "heartbeat $(date -u +%F)" >> "$STATE.tmp"; sort -o "$STATE" "$STATE.tmp"; rm -f "$STATE.tmp"
fi

echo "== недоступно: $DOWN_COUNT"
[ "$TG_FAILED" = 0 ] || exit 1
exit 0
