#!/bin/bash
# One-shot check: helper tool-match timeout rate after --parallel 2
# Baseline (40h ending 2026-03-31): 153 timeouts / 349 attempts = 44%
# Scheduled to run 2026-04-02 ~7pm

NUDGES=$(docker logs smart-proxy 2>&1 | grep -c "Tool nudge: injected")
TIMEOUTS=$(docker logs smart-proxy 2>&1 | grep -c "Tool match failed")
TOTAL=$((NUDGES + TIMEOUTS))

if [ "$TOTAL" -gt 0 ]; then
  RATE=$(python3 -c "print(f'{$TIMEOUTS / $TOTAL * 100:.1f}')")
else
  RATE="N/A (no tool match attempts)"
fi

PASSED=$(docker logs smart-proxy 2>&1 | grep -c "passed on first attempt")
FAILED=$(docker logs smart-proxy 2>&1 | grep -c "all attempts failed")
ZAI_500=$(docker logs smart-proxy 2>&1 | grep -c "Z.AI returned 500")
DEFERRED=$(curl -s http://localhost:8092/metrics | grep '^llamacpp:requests_deferred ' | awk '{print $2}')
UPTIME=$(docker inspect smart-proxy --format '{{.State.StartedAt}}' 2>/dev/null)

BODY="Helper Agent --parallel 2 Report ($(date))

BASELINE (pre-change, 40h window ending 2026-03-31):
  Tool match timeouts: 153 / 349 attempts = 44%

CURRENT (since proxy start: ${UPTIME}):
  Tool nudges injected: ${NUDGES}
  Tool match timeouts:  ${TIMEOUTS}
  Total attempts:       ${TOTAL}
  Timeout rate:         ${RATE}%

  Quality gate passed (1st attempt): ${PASSED}
  Quality gate exhausted (all failed): ${FAILED}
  Z.AI 500 errors: ${ZAI_500}
  Helper requests_deferred (cumulative): ${DEFERRED}

VERDICT:
$(if [ "$TOTAL" -gt 0 ] && python3 -c "exit(0 if $TIMEOUTS / $TOTAL < 0.30 else 1)" 2>/dev/null; then
  echo "  IMPROVEMENT — timeout rate dropped below 30%"
elif [ "$TOTAL" -gt 0 ] && python3 -c "exit(0 if $TIMEOUTS / $TOTAL < 0.44 else 1)" 2>/dev/null; then
  echo "  MARGINAL — timeout rate improved but still above 30%"
else
  echo "  NO IMPROVEMENT — consider --parallel 3 or bumping timeout to 6s"
fi)"

python3 -c "
import smtplib, ssl
from email.mime.text import MIMEText

msg = MIMEText('''$BODY''')
msg['Subject'] = 'LLM Stack: Helper --parallel 2 Timeout Report'
msg['From'] = 'william.fitzmeyer@brewerwebdesign.com'
msg['To'] = 'design@brewerwebdesign.com'

ctx = ssl.create_default_context()
with smtplib.SMTP_SSL('secure329.inmotionhosting.com', 465, context=ctx) as s:
    s.login('william.fitzmeyer@brewerwebdesign.com', 'uUDDh6m7Knv45Nf')
    s.send_message(msg)
    print('Email sent.')
"

# Self-cleanup: remove the cron entry after running
crontab -l 2>/dev/null | grep -v 'check-helper-timeouts' | crontab -
echo "Cron entry removed."
