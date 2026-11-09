#!/usr/bin/env bash
# Surveillance externe de Morali Pay.
# Lancé toutes les 5 minutes par GitHub Actions (serveurs de GitHub, pas ceux du site).
#
# Vérifie :
#   1. la page d'accueil répond (200) et contient bien « Morali » (pas une page d'erreur vide) ;
#   2. /api/health répond et la base de données est « connected » ;
#   3. chaque réponse arrive en moins de MAX_SECONDS.
# Chaque vérification est retentée 3 fois (20 s d'écart) avant de conclure à une panne,
# pour éviter les fausses alertes.
#
# Alertes Telegram : à la panne, rappel toutes les 30 min tant que ça dure, et au retour.
# L'état est gardé dans state/status (commité par le workflow).
#
# Variables : SITE_URL, TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID, STATE_FILE (optionnel)
set -uo pipefail

SITE_URL="${SITE_URL:-https://moralipay.com}"
STATE_FILE="${STATE_FILE:-state/status}"
MAX_SECONDS="${MAX_SECONDS:-15}"
TRIES="${TRIES:-3}"
RETRY_WAIT="${RETRY_WAIT:-20}"
REMIND_EVERY="${REMIND_EVERY:-1800}"
NOW=$(date +%s)

body_file=$(mktemp)

# check_once <url> <test> → 0 si OK ; sinon écrit la raison dans $REASON
check_once() {
  local url="$1" kind="$2" code t
  read -r code t < <(curl -sS -o "$body_file" -w '%{http_code} %{time_total}' \
    --max-time "$MAX_SECONDS" -H 'Cache-Control: no-cache' -A 'MoraliSurveillance/1.0' "$url" 2>/dev/null || echo "000 $MAX_SECONDS")
  if [ "$code" = "000" ]; then REASON="aucune réponse (délai dépassé ou site injoignable)"; return 1; fi
  if [ "$code" != "200" ]; then REASON="code HTTP $code"; return 1; fi
  case "$kind" in
    home)   grep -qi 'morali' "$body_file" || { REASON="page vide ou inattendue"; return 1; } ;;
    health) grep -q '"database":"connected"' "$body_file" || { REASON="base de données injoignable"; return 1; } ;;
  esac
  return 0
}

check() {
  local url="$1" kind="$2" i
  for i in $(seq 1 "$TRIES"); do
    if check_once "$url" "$kind"; then return 0; fi
    [ "$i" -lt "$TRIES" ] && sleep "$RETRY_WAIT"
  done
  return 1
}

PROBLEMS=()
REASON=""
check "$SITE_URL/" home       || PROBLEMS+=("Site ($SITE_URL) : $REASON")
check "$SITE_URL/api/health" health || PROBLEMS+=("Serveur / base : $REASON")
rm -f "$body_file"

# --- état précédent
prev_status="up"; since="$NOW"; last_alert=0
if [ -f "$STATE_FILE" ]; then
  # shellcheck disable=SC1090
  . "$STATE_FILE"
  prev_status="${status:-up}"; since="${since:-$NOW}"; last_alert="${last_alert:-0}"
fi

send() {
  if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
    echo "::error::Secrets Telegram manquants : alerte non envoyée"; return 1
  fi
  curl -sS --max-time 15 -o /dev/null -w 'Telegram %{http_code}\n' \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=$1" \
    --data-urlencode "disable_web_page_preview=true"
}

duration() { local s=$1; if [ "$s" -lt 3600 ]; then echo "$((s / 60)) min"; else echo "$((s / 3600)) h $(((s % 3600) / 60)) min"; fi; }
heure() { TZ=Africa/Brazzaville date -d "@$1" '+%H:%M'; }

new_status="up"; [ ${#PROBLEMS[@]} -gt 0 ] && new_status="down"
details=$(printf '• %s\n' "${PROBLEMS[@]+"${PROBLEMS[@]}"}")

if [ "$new_status" = "down" ]; then
  if [ "$prev_status" = "up" ]; then
    since="$NOW"; last_alert="$NOW"
    send "🔴 MORALI PAY EST EN PANNE
${details}
Détectée à $(heure "$NOW") (heure de Brazzaville), après 3 essais.
Vérifie Vercel → Deployments / Logs. Prochain message : au retour ou dans 30 min."
  elif [ $((NOW - last_alert)) -ge "$REMIND_EVERY" ]; then
    last_alert="$NOW"
    send "🔴 Toujours en panne depuis $(duration $((NOW - since)))
${details}"
  fi
  echo "PANNE :"; echo "$details"
else
  if [ "$prev_status" = "down" ]; then
    send "🟢 MORALI PAY EST DE RETOUR
Panne terminée à $(heure "$NOW"), durée : $(duration $((NOW - since)))."
  fi
  since="$NOW"; last_alert=0
  echo "OK : site et base en ligne"
  if [ "${TEST_ALERT:-false}" = "true" ]; then
    send "✅ Test du robot de surveillance : Morali Pay est en ligne (site et base). Tu seras prévenu ici en cas de panne." || exit 1
  fi
fi

mkdir -p "$(dirname "$STATE_FILE")"
printf 'status=%s\nsince=%s\nlast_alert=%s\n' "$new_status" "$since" "$last_alert" > "$STATE_FILE.new"
# Ne réécrit le fichier que si quelque chose d'utile a changé (évite un commit toutes les 5 min).
if [ "$new_status" != "$prev_status" ] || ! cmp -s <(grep last_alert "$STATE_FILE.new") <(grep last_alert "$STATE_FILE" 2>/dev/null); then
  mv "$STATE_FILE.new" "$STATE_FILE"
else
  rm -f "$STATE_FILE.new"
fi

# Le job échoue pendant une panne : GitHub envoie aussi un e-mail (deuxième canal d'alerte).
[ "$new_status" = "up" ]
