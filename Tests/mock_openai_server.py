#!/usr/bin/env python3
"""本地 OpenAI 兼容 mock，用于无网络/无密钥地测试云端转写与 LLM 校对。"""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TRANSCRIPT = {
    "text": "ACA财务会计,折现率是10%,每股收益很重要,管理会计强调公司治理。",
    "segments": [
        {"start": 0.0, "end": 3.2, "text": "ACA财务会计,折现率是10%,"},
        {"start": 3.2, "end": 7.8, "text": "每股收益很重要,管理会计强调公司治理。"},
    ],
}

FIXES = {
    "ACA财务会计": "ACCA财务会计",
    "折现率是10%": "折现率是 10%",
}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("[mock] " + fmt % args + "\n")

    def _send(self, payload, status=200):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.endswith("/models"):
            self._send({
                "object": "list",
                "data": [
                    {"id": "mock-chat", "object": "model"},
                    {"id": "mock-chat-mini", "object": "model"},
                    {"id": "whisper-1", "object": "model"},
                ],
            })
            return
        self._send({"error": "not found: " + self.path}, 404)

    def do_POST(self):
        auth = self.headers.get("Authorization", "")
        if auth:
            sys.stderr.write("[mock] auth: " + auth[:24] + "\n")
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        path = self.path

        if path.endswith("/audio/transcriptions"):
            if b"multipart/form-data" not in (self.headers.get("Content-Type") or "").encode():
                self._send({"error": "expected multipart"}, 400)
                return
            self._send(TRANSCRIPT)
            return

        if path.endswith("/chat/completions"):
            try:
                request = json.loads(raw.decode("utf-8"))
            except Exception:
                request = {}
            messages = request.get("messages") or []
            if messages:
                sys.stderr.write("[mock] system prompt: " + str(messages[0].get("content", ""))[:100] + "\n")
            content = json.dumps(FIXES, ensure_ascii=False)
            self._send({
                "id": "chatcmpl-mock",
                "object": "chat.completion",
                "model": request.get("model", "mock"),
                "choices": [{
                    "index": 0,
                    "message": {"role": "assistant", "content": content},
                    "finish_reason": "stop",
                }],
                "usage": {"prompt_tokens": 10, "completion_tokens": 10, "total_tokens": 20},
            })
            return

        self._send({"error": "not found: " + path}, 404)


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    sys.stderr.write("[mock] listening on http://127.0.0.1:%d\n" % port)
    server.serve_forever()


if __name__ == "__main__":
    main()
