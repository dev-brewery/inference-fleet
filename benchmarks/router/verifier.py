#!/usr/bin/env python3
import re
import ast
from math import gcd
from typing import Any, Dict, List, Set


STOP_WORDS: Set[str] = {
    "the", "a", "an", "and", "or", "to", "for", "of", "in", "on", "with", "by", "is", "are", "be",
    "this", "that", "it", "as", "at", "from", "into", "under", "over", "all", "any", "you", "your",
    "includes", "include", "must", "should", "can", "will", "if", "then", "than", "how", "what",
    "criteria", "criterion", "decision",
}


def _keyword_tokens(text: str) -> List[str]:
    tokens = re.findall(r"[a-z0-9_]+", text.lower())
    out = [t for t in tokens if len(t) >= 3 and t not in STOP_WORDS]
    return out


def _covers_check(response: str, check: str) -> bool:
    if check.strip().lower() in {"meets request requirements", "satisfies request requirements"}:
        return True

    r = response.lower()
    resp_toks = set(_keyword_tokens(response))
    toks = _keyword_tokens(check)

    exact_token = re.search(r"exact token\s+([a-z0-9_]+)", check.lower())
    if exact_token:
        needle = exact_token.group(1)
        return re.search(r"\b" + re.escape(needle) + r"\b", r) is not None

    quoted = re.findall(r'"([^"]+)"', check)
    if quoted:
        # If a quoted literal exists in the check, treat it as authoritative.
        for lit in quoted:
            if lit.strip() and lit.lower() in r:
                return True
        return False

    if not toks:
        return True

    def token_match(t: str) -> bool:
        if t in resp_toks:
            return True
        # prefix/stem fallback (e.g., verify vs verification, communicate vs communication)
        stem = t[:5]
        for rt in resp_toks:
            if len(rt) >= 5 and (rt.startswith(stem) or stem.startswith(rt[:5])):
                return True
        if re.search(r"\b" + re.escape(t) + r"\b", r):
            return True
        return False

    uniq = sorted(set(toks))
    hit = sum(1 for t in uniq if token_match(t))
    required = 1 if len(uniq) <= 2 else 2
    return hit >= required


def _route_failures(route: str, goal: str, output_format: str, response: str) -> List[str]:
    failures: List[str] = []
    g = goal.lower()
    of = output_format.lower()
    r = response.lower()

    if route == "ops":
        if not re.search(r"\b(rollback|mitigat|contain)\b", r):
            failures.append("ops_missing_containment_or_rollback")
        if not re.search(r"\b(communicat|owner|incident commander|on-call)\b", r):
            failures.append("ops_missing_owner_or_communication")
        if not re.search(r"\b(verify|check|metric|slo|5xx)\b", r):
            failures.append("ops_missing_verification_signal")
    elif route == "code":
        if re.search(r"\b(sql query|write a sql query|select .* from)\b", g):
            if not re.search(r"\bselect\b", r) or not re.search(r"\bfrom\b", r):
                failures.append("code_sql_missing_select_from")
        if re.search(r"\bpython\b|\bfunction\b|\bbug\b", g):
            if "def " not in response and "```python" not in r:
                failures.append("code_python_missing_function_shape")
    elif route == "math_logic":
        numeric_goal = re.search(r"\b(how many|calculate|angle|minutes|divisible|probability|count|number)\b", g)
        if numeric_goal and not re.search(r"\d", response):
            failures.append("math_logic_missing_numeric_signal")
    elif route == "planning":
        is_json = "json" in of or "json" in g
        if (not is_json) and not re.search(r"(^|\n)\s*(\d+\.|-)\s", response):
            failures.append("planning_missing_step_structure")
        needs_risk_rollback = bool(re.search(r"\b(migration|cutover|downtime|incident|rollback)\b", g))
        if needs_risk_rollback and not re.search(r"\b(risk|dependency|rollback)\b", r):
            failures.append("planning_missing_risk_or_rollback")

    return failures


def _first_number(text: str) -> float | None:
    m = re.search(r"[-+]?\d+(?:\.\d+)?", text)
    if not m:
        return None
    return float(m.group(0))


def _extract_python_code(response: str) -> str | None:
    m = re.search(r"```python\s*(.*?)```", response, flags=re.IGNORECASE | re.DOTALL)
    if m:
        return m.group(1).strip()
    if "def " in response:
        return response
    return None


def _tool_failures(route: str, goal: str, response: str) -> List[str]:
    out: List[str] = []
    g = goal.lower()
    r = response.lower()

    if route == "code":
        py = _extract_python_code(response)
        if py is not None:
            try:
                ast.parse(py)
            except SyntaxError:
                out.append("tool_python_syntax_invalid")

    if route == "math_logic":
        # Pattern: count integers in 1..N divisible by A or B
        m = re.search(r"from\s+1\s+to\s+(\d+)\s+.*divisible by\s+(\d+)\s+or\s+(\d+)", g)
        if m:
            n = int(m.group(1))
            a = int(m.group(2))
            b = int(m.group(3))
            expected = n // a + n // b - n // (a * b // gcd(a, b))
            if str(expected) not in response:
                out.append(f"tool_math_expected_{expected}")

        # Pattern: clock angle at H:MM
        m = re.search(r"at\s+(\d{1,2})\s*:\s*(\d{2}).*angle", g)
        if m:
            h = int(m.group(1)) % 12
            minute = int(m.group(2))
            hour_angle = (h * 30.0) + (minute * 0.5)
            minute_angle = minute * 6.0
            diff = abs(hour_angle - minute_angle)
            expected = int(min(diff, 360.0 - diff))
            if str(expected) not in response:
                out.append(f"tool_math_expected_{expected}")

        # Pattern: two-worker rate problem
        m = re.search(r"a can do .* in (\d+)\s*hours?.*b .* in (\d+)\s*hours?.*minutes", g)
        if m:
            a = float(m.group(1))
            b = float(m.group(2))
            minutes = (1.0 / (1.0 / a + 1.0 / b)) * 60.0
            expected_int = int(round(minutes))
            if str(expected_int) not in response and "24/7" not in r:
                out.append(f"tool_math_expected_{expected_int}")

    return out


def verify_response(req: Dict[str, Any], route: str, response: str) -> Dict[str, Any]:
    checks = req.get("acceptance_checks", [])
    matched: List[str] = []
    missing: List[str] = []
    for c in checks:
        if _covers_check(response, c):
            matched.append(c)
        else:
            missing.append(c)

    route_failures = _route_failures(route, req.get("goal", ""), req.get("output_format", ""), response)
    tool_failures = _tool_failures(route, req.get("goal", ""), response)

    metadata = req.get("metadata", {}) if isinstance(req.get("metadata", {}), dict) else {}
    required_patterns = metadata.get("required_patterns", []) if isinstance(metadata.get("required_patterns", []), list) else []
    forbidden_patterns = metadata.get("forbidden_patterns", []) if isinstance(metadata.get("forbidden_patterns", []), list) else []
    regex_missing: List[str] = []
    regex_forbidden_hits: List[str] = []
    for p in required_patterns:
        if isinstance(p, str) and p.strip():
            if re.search(p, response, flags=re.IGNORECASE) is None:
                regex_missing.append(p)
    for p in forbidden_patterns:
        if isinstance(p, str) and p.strip():
            if re.search(p, response, flags=re.IGNORECASE) is not None:
                regex_forbidden_hits.append(p)

    passed = (
        len(missing) == 0
        and len(route_failures) == 0
        and len(tool_failures) == 0
        and len(regex_missing) == 0
        and len(regex_forbidden_hits) == 0
    )

    return {
        "passed": passed,
        "checks_total": len(checks),
        "checks_matched": len(matched),
        "checks_missing": missing,
        "route_failures": route_failures,
        "tool_failures": tool_failures,
        "regex_missing": regex_missing,
        "regex_forbidden_hits": regex_forbidden_hits,
    }
