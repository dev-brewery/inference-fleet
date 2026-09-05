#!/usr/bin/env python3
import argparse
import json
import time
import urllib.error
import urllib.request
import uuid
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Dict, List, Tuple

from router import append_jsonl, classify_task, load_template, run_structured_request
from verifier import verify_response


def _json_response(handler: BaseHTTPRequestHandler, status: int, payload: Dict[str, Any]) -> None:
    data = json.dumps(payload, ensure_ascii=True).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(data)))
    handler.end_headers()
    handler.wfile.write(data)


def _extract_text_content(content: Any) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts: List[str] = []
        for item in content:
            if isinstance(item, dict) and item.get("type") == "text":
                txt = item.get("text")
                if isinstance(txt, str):
                    parts.append(txt)
        return "\n".join(parts)
    return ""


def _extract_messages(payload: Dict[str, Any]) -> Tuple[str, str]:
    messages = payload.get("messages")
    if not isinstance(messages, list) or not messages:
        raise ValueError("messages must be a non-empty array")

    system_parts: List[str] = []
    user_parts: List[str] = []
    for m in messages:
        if not isinstance(m, dict):
            continue
        role = str(m.get("role", "")).strip().lower()
        content_text = _extract_text_content(m.get("content"))
        if role == "system" and content_text.strip():
            system_parts.append(content_text.strip())
        if role == "user" and content_text.strip():
            user_parts.append(content_text.strip())

    if not user_parts:
        raise ValueError("at least one user message is required")
    goal = user_parts[-1]
    system = "\n\n".join(system_parts).strip()
    return goal, system


def _build_structured_request(payload: Dict[str, Any], goal: str, system: str) -> Dict[str, Any]:
    metadata = payload.get("metadata", {}) if isinstance(payload.get("metadata"), dict) else {}
    task_type = payload.get("task_type", "auto")
    if not isinstance(task_type, str):
        task_type = "auto"

    constraints: List[str] = []
    if system:
        constraints.append(f"System guidance: {system}")
    constraints.append("Return direct answer only; no hidden chain-of-thought.")
    if isinstance(payload.get("max_tokens"), int):
        constraints.append(f"Response length should fit within max_tokens={payload['max_tokens']}.")

    output_format = "Concise answer matching user intent"
    response_format = payload.get("response_format")
    if isinstance(response_format, dict):
        rf_type = response_format.get("type")
        if rf_type == "json_schema":
            output_format = "Valid JSON matching requested schema"
            metadata["response_format"] = response_format

    acceptance_checks: List[str] = ["Meets request requirements"]
    if metadata.get("acceptance_checks") and isinstance(metadata["acceptance_checks"], list):
        checks = [c for c in metadata["acceptance_checks"] if isinstance(c, str)]
        if checks:
            acceptance_checks = checks

    context: List[str] = []
    if len(goal) > 0:
        context.append(f"input_chars={len(goal)}")

    return {
        "task_type": task_type,
        "goal": goal,
        "constraints": constraints,
        "output_format": output_format,
        "acceptance_checks": acceptance_checks,
        "context": context,
        "metadata": metadata,
    }


def _backend_request(server_base: str, path: str, payload: Dict[str, Any], timeout_s: int = 300) -> Dict[str, Any]:
    req = urllib.request.Request(
        server_base.rstrip("/") + path,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout_s) as resp:
        body = resp.read().decode("utf-8")
        return json.loads(body)


def _proxy_stream_request(
    handler: BaseHTTPRequestHandler,
    server_base: str,
    path: str,
    payload: Dict[str, Any],
    timeout_s: int = 600,
) -> None:
    req = urllib.request.Request(
        server_base.rstrip("/") + path,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout_s) as resp:
        ctype = resp.headers.get("Content-Type", "text/event-stream")
        handler.send_response(resp.status)
        handler.send_header("Content-Type", ctype)
        handler.send_header("Cache-Control", "no-cache")
        handler.send_header("Connection", "keep-alive")
        handler.end_headers()
        while True:
            chunk = resp.read(4096)
            if not chunk:
                break
            handler.wfile.write(chunk)
            handler.wfile.flush()


def _backend_get(server_base: str, path: str, timeout_s: int = 30) -> Tuple[int, bytes, str]:
    req = urllib.request.Request(server_base.rstrip("/") + path, method="GET")
    with urllib.request.urlopen(req, timeout=timeout_s) as resp:
        data = resp.read()
        ctype = resp.headers.get("Content-Type", "application/json")
        return resp.status, data, ctype


def _augment_messages_with_route(messages: List[Dict[str, Any]], route: str, route_system: str) -> List[Dict[str, Any]]:
    out = [dict(m) for m in messages if isinstance(m, dict)]
    if not out:
        return [{"role": "system", "content": route_system}]

    first_system_idx = None
    for i, m in enumerate(out):
        if str(m.get("role", "")).lower() == "system":
            first_system_idx = i
            break

    route_header = f"[ROUTER ROUTE: {route}]"
    if first_system_idx is not None:
        original = _extract_text_content(out[first_system_idx].get("content"))
        merged = f"{route_header}\n{route_system}\n\n{original}".strip()
        out[first_system_idx]["content"] = merged
    else:
        out.insert(0, {"role": "system", "content": f"{route_header}\n{route_system}"})
    return out


def _extract_assistant_text(choice: Dict[str, Any]) -> str:
    msg = choice.get("message", {}) if isinstance(choice, dict) else {}
    return _extract_text_content(msg.get("content")).strip()


class RouterGatewayHandler(BaseHTTPRequestHandler):
    server_version = "DeeplyTunedRouterGateway/1.1"
    protocol_version = "HTTP/1.1"

    def _log_run(self, record: Dict[str, Any]) -> None:
        append_jsonl(Path(self.server.log_file), record)  # type: ignore[attr-defined]

    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/health":
            backend_ok = True
            detail = "ok"
            try:
                status, _, _ = _backend_get(self.server.llm_server_url, "/health", timeout_s=5)  # type: ignore[attr-defined]
                backend_ok = status == 200
                if not backend_ok:
                    detail = f"backend_status_{status}"
            except Exception as exc:
                backend_ok = False
                detail = f"backend_unreachable: {exc}"

            if backend_ok:
                _json_response(
                    self,
                    HTTPStatus.OK,
                    {"status": "ok", "service": "router-gateway", "backend": "ok"},
                )
            else:
                _json_response(
                    self,
                    HTTPStatus.SERVICE_UNAVAILABLE,
                    {"status": "degraded", "service": "router-gateway", "backend": detail},
                )
            return
        if self.path == "/v1/models":
            try:
                status, data, ctype = _backend_get(self.server.llm_server_url, "/v1/models")  # type: ignore[attr-defined]
                self.send_response(status)
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                return
            except Exception as exc:
                _json_response(self, HTTPStatus.BAD_GATEWAY, {"error": "backend_models_failed", "detail": str(exc)})
                return
        _json_response(self, HTTPStatus.NOT_FOUND, {"error": "not_found"})

    def do_POST(self) -> None:  # noqa: N802
        if self.path != "/v1/chat/completions":
            _json_response(self, HTTPStatus.NOT_FOUND, {"error": "not_found"})
            return

        content_length = self.headers.get("Content-Length")
        if not content_length:
            _json_response(self, HTTPStatus.BAD_REQUEST, {"error": "missing_content_length"})
            return
        try:
            raw = self.rfile.read(int(content_length))
            payload = json.loads(raw.decode("utf-8"))
        except Exception:
            _json_response(self, HTTPStatus.BAD_REQUEST, {"error": "invalid_json"})
            return

        try:
            goal, system = _extract_messages(payload)
        except ValueError as exc:
            _json_response(self, HTTPStatus.BAD_REQUEST, {"error": str(exc)})
            return

        messages = payload.get("messages")
        if not isinstance(messages, list):
            _json_response(self, HTTPStatus.BAD_REQUEST, {"error": "messages must be an array"})
            return

        task_type = payload.get("task_type", "auto")
        if not isinstance(task_type, str) or task_type == "auto":
            task_type = classify_task(goal)
        route_system = load_template(task_type, Path(__file__).resolve().parent)

        has_tools = isinstance(payload.get("tools"), list) and len(payload.get("tools", [])) > 0
        is_stream = bool(payload.get("stream", False))

        if is_stream:
            # Streaming compatibility path: passthrough stream without JSON parsing.
            proxied = dict(payload)
            proxied["messages"] = _augment_messages_with_route(messages, task_type, route_system)
            try:
                _proxy_stream_request(self, self.server.llm_server_url, "/v1/chat/completions", proxied)  # type: ignore[attr-defined]
            except urllib.error.HTTPError as exc:
                body = exc.read().decode("utf-8", errors="replace")
                _json_response(self, HTTPStatus.BAD_GATEWAY, {"error": "backend_http_error", "status": exc.code, "body": body})
            except Exception as exc:
                _json_response(self, HTTPStatus.BAD_GATEWAY, {"error": "backend_request_failed", "detail": str(exc)})
            return

        if has_tools:
            # Full OpenAI compatibility path: preserve tool-call semantics and passthrough all fields.
            proxied = dict(payload)
            proxied["messages"] = _augment_messages_with_route(messages, task_type, route_system)
            try:
                backend_resp = _backend_request(self.server.llm_server_url, "/v1/chat/completions", proxied)  # type: ignore[attr-defined]
            except urllib.error.HTTPError as exc:
                body = exc.read().decode("utf-8", errors="replace")
                _json_response(self, HTTPStatus.BAD_GATEWAY, {"error": "backend_http_error", "status": exc.code, "body": body})
                return
            except Exception as exc:
                _json_response(self, HTTPStatus.BAD_GATEWAY, {"error": "backend_request_failed", "detail": str(exc)})
                return

            # Optional gate only for final text (never block tool-call turn).
            verification = None
            choices = backend_resp.get("choices", [])
            if isinstance(choices, list) and choices:
                first = choices[0] if isinstance(choices[0], dict) else {}
                finish = first.get("finish_reason")
                msg = first.get("message", {}) if isinstance(first.get("message", {}), dict) else {}
                tool_calls = msg.get("tool_calls")
                if finish == "stop" and not tool_calls:
                    structured_req = _build_structured_request(payload, goal, system)
                    text = _extract_assistant_text(first)
                    verification = verify_response(structured_req, task_type, text)
                    if self.server.fail_on_verify and verification and not verification.get("passed", False):  # type: ignore[attr-defined]
                        _json_response(
                            self,
                            HTTPStatus.UNPROCESSABLE_ENTITY,
                            {
                                "error": "verification_failed",
                                "verification": verification,
                                "route": task_type,
                                "attempts_used": 1,
                            },
                        )
                        return

            backend_resp["router_meta"] = {
                "route": task_type,
                "mode": "passthrough_tools" if has_tools else "passthrough_stream",
                "verification": verification,
            }
            self._log_run(
                {
                    "ts_unix": int(time.time()),
                    "mode": "passthrough",
                    "route": task_type,
                    "goal": goal,
                    "has_tools": has_tools,
                    "stream": is_stream,
                    "verification": verification,
                }
            )
            _json_response(self, HTTPStatus.OK, backend_resp)
            return

        # Structured mode for plain chat requests
        structured_req = _build_structured_request(payload, goal, system)
        result = run_structured_request(
            raw=structured_req,
            server=self.server.llm_server_url,  # type: ignore[attr-defined]
            no_verify=False,
            max_retries=self.server.max_retries,  # type: ignore[attr-defined]
            log_file=self.server.log_file,  # type: ignore[attr-defined]
        )

        if not result.get("ok", False):
            _json_response(self, HTTPStatus.BAD_GATEWAY, {"error": result.get("error", "router_failed"), "details": result})
            return

        verification = result.get("verification", {})
        if self.server.fail_on_verify and verification and not verification.get("passed", False):  # type: ignore[attr-defined]
            _json_response(
                self,
                HTTPStatus.UNPROCESSABLE_ENTITY,
                {
                    "error": "verification_failed",
                    "verification": verification,
                    "route": result.get("route"),
                    "attempts_used": result.get("attempts_used"),
                },
            )
            return

        created = int(time.time())
        completion_id = f"chatcmpl-router-{uuid.uuid4().hex[:24]}"
        content = result.get("response", "")
        response_payload = {
            "id": completion_id,
            "object": "chat.completion",
            "created": created,
            "model": payload.get("model", "local-router"),
            "choices": [
                {
                    "index": 0,
                    "finish_reason": "stop",
                    "message": {"role": "assistant", "content": content},
                }
            ],
            "usage": {
                "prompt_tokens": 0,
                "completion_tokens": 0,
                "total_tokens": 0,
            },
            "router_meta": {
                "route": result.get("route"),
                "attempts_used": result.get("attempts_used"),
                "verification": verification,
                "timings": result.get("timings", {}),
                "mode": "structured",
            },
        }
        _json_response(self, HTTPStatus.OK, response_payload)

    def log_message(self, fmt: str, *args: Any) -> None:
        return


def main() -> int:
    parser = argparse.ArgumentParser(description="Router gateway for /v1/chat/completions")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8090)
    parser.add_argument("--llm-server", default="http://127.0.0.1:8080")
    parser.add_argument("--log-file", default="/tmp/gateway_runs.jsonl")
    parser.add_argument("--max-retries", type=int, default=2)
    parser.add_argument("--fail-on-verify", action="store_true")
    args = parser.parse_args()

    httpd = ThreadingHTTPServer((args.host, args.port), RouterGatewayHandler)
    httpd.llm_server_url = args.llm_server.rstrip("/")  # type: ignore[attr-defined]
    httpd.log_file = args.log_file  # type: ignore[attr-defined]
    httpd.max_retries = max(0, args.max_retries)  # type: ignore[attr-defined]
    httpd.fail_on_verify = bool(args.fail_on_verify)  # type: ignore[attr-defined]

    print(
        json.dumps(
            {
                "service": "router-gateway",
                "listen": f"{args.host}:{args.port}",
                "llm_server": args.llm_server,
                "max_retries": args.max_retries,
                "fail_on_verify": args.fail_on_verify,
            }
        )
    )
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
