#!/bin/bash
# Vox site health monitor
# Probes https://automatescale.com/vox and reports status, latency, and SSL verification.

URL="${1:-https://automatescale.com/vox}"
TIMEOUT=5

TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
RESULT=$(curl -s -w "\nHTTP_STATUS=%{http_code}\nTIME_TOTAL=%{time_total}\nSSL_VERIFY=%{ssl_verify_result}\n" \
  --max-time "$TIMEOUT" -o /dev/null "$URL" 2>&1)

STATUS_CODE=$(echo "$RESULT" | grep "HTTP_STATUS=" | cut -d'=' -f2)
LATENCY=$(echo "$RESULT" | grep "TIME_TOTAL=" | cut -d'=' -f2)
SSL_RESULT=$(echo "$RESULT" | grep "SSL_VERIFY=" | cut -d'=' -f2)

if [ "$STATUS_CODE" = "200" ] && [ "$SSL_RESULT" = "0" ]; then
  echo "[$TIMESTAMP] ✅ OK - $URL (HTTP $STATUS_CODE, ${LATENCY}s)"
  exit 0
else
  echo "[$TIMESTAMP] ❌ ALERT - $URL failed! (HTTP: ${STATUS_CODE:-'ERR'}, Latency: ${LATENCY:-'N/A'}s, SSL: ${SSL_RESULT:-'N/A'})" >&2
  exit 1
fi
