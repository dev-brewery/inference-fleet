#!/bin/bash
# One-shot check: quality gate fix effectiveness after 2026-04-02 changes
# Three fixes applied:
#   1. Dedicated tool-match-agent (port 8094, 8 threads, --parallel 4)
#   2. False TRUNCATED override when stop_reason=end_turn
#   3. Retries limited to deterministic failures only
#
# Baseline (2h window 2026-04-02, pre-fix):
#   Tool match timeout rate: 87% (20/23)
#   TRUNCATED false positive rate: 100% (8/8 on end_turn responses)
#   Retry save rate: 8.3% (2/24)
#   Complete failure rate: 16.7% (4/24)
#   Wasted retry latency: ~245s
#
# Scheduled to run 2026-04-03 ~7pm (24h of post-fix traffic)

LOGS=$(docker logs smart-proxy 2>&1)
UPTIME=$(docker inspect smart-proxy --format '{{.State.StartedAt}}' 2>/dev/null)

# Tool match metrics
NUDGES=$(echo "$LOGS" | grep -c "Tool nudge: injected")
TOOL_TIMEOUT=$(echo "$LOGS" | grep -c "Tool match failed (timed out)")
TOOL_HEURISTIC=$(echo "$LOGS" | grep -c "Tool match (heuristic)")
TOOL_NONE=$(echo "$LOGS" | grep -c "Tool match: NONE")
TOOL_MATCH=$(echo "$LOGS" | grep -c "Tool match: \[")
TOOL_TOTAL=$((TOOL_MATCH + TOOL_TIMEOUT + TOOL_NONE))

if [ "$TOOL_TOTAL" -gt 0 ]; then
  TOOL_RATE=$(python3 -c "print(f'{$TOOL_TIMEOUT / $TOOL_TOTAL * 100:.1f}')")
else
  TOOL_RATE="N/A"
fi

# Quality gate outcomes
PASSED_FIRST=$(echo "$LOGS" | grep -c "passed on first attempt")
PASSED_RETRY=$(echo "$LOGS" | grep -c "passed on retry")
ALL_FAILED=$(echo "$LOGS" | grep -c "all attempts failed")
SKIPPED=$(echo "$LOGS" | grep -c "skipped (classified as no-eval)")
JUDGE_ONLY_SKIP=$(echo "$LOGS" | grep -c "judge-only failure, skipping retries")
TOTAL_EVAL=$((PASSED_FIRST + PASSED_RETRY + ALL_FAILED + JUDGE_ONLY_SKIP))

if [ "$TOTAL_EVAL" -gt 0 ]; then
  RETRY_RATE=$(python3 -c "print(f'{$PASSED_RETRY / $TOTAL_EVAL * 100:.1f}')")
  FAIL_RATE=$(python3 -c "print(f'{$ALL_FAILED / $TOTAL_EVAL * 100:.1f}')")
else
  RETRY_RATE="N/A"
  FAIL_RATE="N/A"
fi

# TRUNCATED override tracking
TRUNCATED_OVERRIDDEN=$(echo "$LOGS" | grep -c "Overrode false TRUNCATED")
TRUNCATED_FAILURES=$(echo "$LOGS" | grep "Judge verdict" | grep -c "TRUNCATED")

# Failure types (individual attempts)
MISSING_TOOLS=$(echo "$LOGS" | grep "Quality gate: failed" | grep -c "MISSING_TOOLS")
TRUNCATED_FINAL=$(echo "$LOGS" | grep "Quality gate: failed" | grep -c "TRUNCATED")

# Z.AI errors
ZAI_500=$(echo "$LOGS" | grep -c "Z.AI returned 500")

# Classifier timeouts
CLASSIFY_TIMEOUT=$(echo "$LOGS" | grep -c "classifier failed (timed out)")

# Tool-match-agent health
TMA_HEALTH=$(curl -sf http://localhost:8094/health 2>/dev/null || echo "UNREACHABLE")
TMA_UPTIME=$(docker inspect tool-match-agent --format '{{.State.StartedAt}}' 2>/dev/null)

BODY="Quality Gate Fix Report ($(date))
======================================================

BASELINE (2h pre-fix window, 2026-04-02 20:02-21:11 UTC):
  Tool match timeout rate:     87.0% (20/23)
  TRUNCATED false positives:   100% (8/8, all on end_turn)
  Retry save rate:             8.3% (2/24)
  Complete failure rate:       16.7% (4/24)
  Wasted retry latency:       ~245s

CURRENT (since proxy start: ${UPTIME}):
------------------------------------------------------
TOOL MATCHING (Fix 1: dedicated agent on port 8094):
  Tool match successes:        ${TOOL_MATCH}
  Tool match NONE:             ${TOOL_NONE}
  Tool match TIMED OUT:        ${TOOL_TIMEOUT}
  Total attempts:              ${TOOL_TOTAL}
  Timeout rate:                ${TOOL_RATE}%
  Tool nudges injected:        ${NUDGES}
  Tool-match-agent health:     ${TMA_HEALTH}
  Tool-match-agent started:    ${TMA_UPTIME}

TRUNCATED OVERRIDE (Fix 2: stop_reason=end_turn):
  Judge flagged TRUNCATED:     ${TRUNCATED_FAILURES}
  Overridden (false positive): ${TRUNCATED_OVERRIDDEN}
  TRUNCATED in final verdict:  ${TRUNCATED_FINAL}

RETRY GATING (Fix 3: deterministic-only retries):
  Passed first attempt:        ${PASSED_FIRST}
  Passed on retry:             ${PASSED_RETRY}
  Judge-only fail (no retry):  ${JUDGE_ONLY_SKIP}
  All attempts exhausted:      ${ALL_FAILED}
  Total evaluated:             ${TOTAL_EVAL}
  Retry save rate:             ${RETRY_RATE}%
  Complete failure rate:       ${FAIL_RATE}%

OTHER:
  Quality gate skipped:        ${SKIPPED}
  Z.AI 500 errors:             ${ZAI_500}
  Classifier timeouts:         ${CLASSIFY_TIMEOUT}

VERDICT:
$(
  GOOD=0; BAD=0

  if [ "$TOOL_TOTAL" -gt 0 ] && python3 -c "exit(0 if $TOOL_TIMEOUT / $TOOL_TOTAL < 0.10 else 1)" 2>/dev/null; then
    echo "  [PASS] Tool match timeout rate under 10% (was 87%)"
    GOOD=$((GOOD+1))
  elif [ "$TOOL_TOTAL" -gt 0 ]; then
    echo "  [FAIL] Tool match timeout rate still above 10%"
    BAD=$((BAD+1))
  fi

  if [ "$TRUNCATED_FINAL" -eq 0 ]; then
    echo "  [PASS] No false TRUNCATED in final verdicts (was 100%)"
    GOOD=$((GOOD+1))
  else
    echo "  [WARN] ${TRUNCATED_FINAL} TRUNCATED still reaching final verdict"
    BAD=$((BAD+1))
  fi

  if [ "$ALL_FAILED" -eq 0 ]; then
    echo "  [PASS] No exhausted retry cycles (was 4/24 = 17%)"
    GOOD=$((GOOD+1))
  elif [ "$TOTAL_EVAL" -gt 0 ] && python3 -c "exit(0 if $ALL_FAILED / $TOTAL_EVAL < 0.05 else 1)" 2>/dev/null; then
    echo "  [PASS] Complete failure rate under 5% (was 17%)"
    GOOD=$((GOOD+1))
  else
    echo "  [FAIL] Complete failure rate still above 5%"
    BAD=$((BAD+1))
  fi

  echo ""
  if [ "$BAD" -eq 0 ]; then
    echo "  ALL FIXES EFFECTIVE — quality gate is now net-positive"
  else
    echo "  ${GOOD}/3 fixes effective, ${BAD}/3 need further work"
  fi
)"

python3 -c "
import smtplib, ssl
from email.mime.text import MIMEText

msg = MIMEText('''$BODY''')
msg['Subject'] = 'LLM Stack: Quality Gate Fix Report (24h post-deploy)'
msg['From'] = 'william.fitzmeyer@brewerwebdesign.com'
msg['To'] = 'design@brewerwebdesign.com'

ctx = ssl.create_default_context()
with smtplib.SMTP_SSL('secure329.inmotionhosting.com', 465, context=ctx) as s:
    s.login('william.fitzmeyer@brewerwebdesign.com', 'uUDDh6m7Knv45Nf')
    s.send_message(msg)
    print('Email sent.')
"

# Self-cleanup: remove the cron entry after running
crontab -l 2>/dev/null | grep -v 'check-quality-gate-fixes' | crontab -
echo "Cron entry removed."
