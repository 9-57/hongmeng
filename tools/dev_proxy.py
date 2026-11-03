#!/usr/bin/env python3
"""本机反向代理：模拟器 -> 10.0.2.2:8787 -> https://<project>.supabase.co

背景：这台机器上的模拟器 netstack 拿不到可用的 DNS（系统 ping 能解析，App 走 RPC 一律
Couldn't resolve host name），但到宿主机 10.0.2.2 的 TCP 是通的。所以把请求转到本机，
由本机（DNS 正常）去访问 Supabase。

仅在本地联调时使用：配合 tools/dev-proxy.cmd on|off 自动切换 SUPABASE_URL，
联调完记得 off 还原，别把 http://10.0.2.2:8787 提交上去。
"""
import os
import ssl
import sys
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dev-proxy.log")


def log(msg):
    """同时打到控制台和 tools/dev-proxy.log —— 脚本是隐藏窗口启动的，没控制台可看。"""
    line = time.strftime("[%H:%M:%S] ") + msg
    try:
        print(line, flush=True)
    except Exception:
        pass
    try:
        with open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass

TARGET = "https://hfumlfksryyzaebiuaca.supabase.co"
LISTEN_PORT = 8787
HOP_HEADERS = {"transfer-encoding", "connection", "content-length", "keep-alive", "host"}
FORWARD_HEADERS = ("apikey", "authorization", "content-type", "prefer", "accept",
                   "accept-profile", "content-profile", "x-client-info", "range")

CTX_VERIFY = ssl.create_default_context()
CTX_NO_VERIFY = ssl.create_default_context()
CTX_NO_VERIFY.check_hostname = False
CTX_NO_VERIFY.verify_mode = ssl.CERT_NONE


def fetch(method, path, body, headers):
    url = TARGET + path
    req = urllib.request.Request(url, data=body, method=method)
    for h in FORWARD_HEADERS:
        v = headers.get(h)
        if v:
            req.add_header(h, v)
    last = None
    for ctx in (CTX_VERIFY, CTX_NO_VERIFY):
        try:
            with urllib.request.urlopen(req, timeout=30, context=ctx) as r:
                return r.status, dict(r.headers), r.read()
        except urllib.error.HTTPError as e:      # 4xx/5xx 也是正常响应，原样回给客户端
            return e.code, dict(e.headers), e.read()
        except Exception as e:                   # 证书/连接问题换个上下文再试一次
            last = e
    raise last


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _handle(self):
        length = int(self.headers.get("content-length") or 0)
        body = self.rfile.read(length) if length else None
        try:
            status, headers, data = fetch(self.command, self.path, body, self.headers)
        except Exception as e:                   # 代理本身出错也要回一个可读的 JSON
            msg = ('{"ok":false,"code":"proxy_error","message":"%s"}'
                   % str(e).replace('"', "'")).encode()
            self.send_response(502)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(msg)))
            self.end_headers()
            self.wfile.write(msg)
            log("[proxy] %s %s -> 502 %s" % (self.command, self.path, e))
            return
        self.send_response(status)
        for k, v in headers.items():
            if k.lower() not in HOP_HEADERS:
                self.send_header(k, v)
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)
        log("[proxy] %s %s -> %d (%d bytes)" % (self.command, self.path, status, len(data)))

    do_GET = _handle
    do_POST = _handle
    do_PATCH = _handle
    do_PUT = _handle
    do_DELETE = _handle
    do_HEAD = _handle

    def log_message(self, fmt, *args):
        pass


if __name__ == "__main__":
    srv = ThreadingHTTPServer(("0.0.0.0", LISTEN_PORT), Handler)
    log("[proxy] listening on 0.0.0.0:%d -> %s" % (LISTEN_PORT, TARGET))
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        sys.exit(0)
