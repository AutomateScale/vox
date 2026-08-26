#!/bin/bash
# Vox Background Monitor Loop Daemon
# Continuously monitors https://automatescale.com/vox and logs health status.

LOG_FILE="$(pwd)/monitor.log"
STATUS_FILE="$(pwd)/MONITOR_STATUS.md"
INTERVAL="${INTERVAL:-3600}" # Default: 1 hour (3600 seconds)

echo "=== Vox Monitor Loop Daemon started at $(date) (interval: ${INTERVAL}s) ===" | tee -a "$LOG_FILE"

while true; do
  TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
  
  # Probe target site
  RESPONSE=$(curl -s -w "\nHTTP_STATUS=%{http_code}\nTIME_TOTAL=%{time_total}\nSSL_VERIFY=%{ssl_verify_result}\n" \
    --max-time 10 -o /dev/null "https://automatescale.com/vox" 2>&1)
  
  STATUS_CODE=$(echo "$RESPONSE" | grep "HTTP_STATUS=" | cut -d'=' -f2)
  LATENCY=$(echo "$RESPONSE" | grep "TIME_TOTAL=" | cut -d'=' -f2)
  SSL_RESULT=$(echo "$RESPONSE" | grep "SSL_VERIFY=" | cut -d'=' -f2)
  
  if [ "$STATUS_CODE" = "200" ] && [ "$SSL_RESULT" = "0" ]; then
    LOG_ENTRY="[$TIMESTAMP] ✅ OK - https://automatescale.com/vox (HTTP $STATUS_CODE | Latency: ${LATENCY}s | SSL: Valid)"
    HEALTH="HEALTHY"
  else
    LOG_ENTRY="[$TIMESTAMP] ❌ ERROR - https://automatescale.com/vox (HTTP: ${STATUS_CODE:-'FAIL'} | Latency: ${LATENCY:-'N/A'}s | SSL: ${SSL_RESULT:-'FAIL'})"
    HEALTH="DEGRADED / DOWN"
  fi
  
  echo "$LOG_ENTRY" | tee -a "$LOG_FILE"
  
  # Update markdown status file
  cat <<EOF > "$STATUS_FILE"
# 📡 Vox Site Monitor Status

- **Status**: $HEALTH
- **Last Checked**: $TIMESTAMP
- **Target URL**: https://automatescale.com/vox
- **HTTP Code**: $STATUS_CODE
- **Latency**: ${LATENCY}s
- **Check Frequency**: Every $((INTERVAL / 60)) minutes (${INTERVAL}s)
- **Log File**: \`$LOG_FILE\`

### Recent Event:
\`\`\`
$LOG_ENTRY
\`\`\`
EOF

  sleep "$INTERVAL"
done
