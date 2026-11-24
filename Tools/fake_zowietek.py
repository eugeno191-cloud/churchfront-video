#!/usr/bin/env python3
"""A pretend Zowietek encoder (ZowieBox) on HTTP, for trying CueVideo's Stream and Record
buttons with no hardware.

    python3 Tools/fake_zowietek.py [port]        (default 8090; set the address to 127.0.0.1:8090)

Answers the ZowieTek API v1.5 requests CueVideo sends: stream status and the stream
on/off switch, the recording task list and recording on/off. Changes need the login
admin / admin, as on a new box. Prints each request.
"""
import json, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8090
USER, PASSWORD = "admin", "admin"
lock = threading.Lock()
streams = [
    {"index": 1, "show_index": 1, "protocol": "RTMP", "name": "YouTube", "desc": "youtube", "switch": 0, "status": 2},
    {"index": 2, "show_index": 2, "protocol": "RTMP", "name": "Facebook", "desc": "facebook", "switch": 0, "status": 2},
]
tasks = [
    {"index": "usb1_0", "name": "usb1", "enable": 0, "status": 5,
     "storageInfo": {"name": "USB1", "index": 1, "status": 1, "totalspace": 61000, "freespace": 52400}},
    {"index": "sdcard_0", "name": "sdcard", "enable": 0, "status": 5,
     "storageInfo": {"name": "SD card", "index": 2, "status": 0, "totalspace": 0, "freespace": 0}},
]

def go_online(i):
    # A real box takes a moment to reach the streaming service.
    time.sleep(2)
    with lock:
        for s in streams:
            if s["index"] == i and s["switch"] == 1:
                s["status"] = 1

class Box(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        setting = "option=setinfo" in self.path
        answer = {"rsp": "succeed", "status": "00000"}
        shown = {k: ("***" if k == "psw" else v) for k, v in body.items()}
        print(self.path, json.dumps(shown), flush=True)
        with lock:
            if setting and (body.get("user") != USER or body.get("psw") != PASSWORD):
                answer = {"rsp": "failed", "status": "80005"}
            elif body.get("group") == "getStreamStatus":
                answer["publish_status"] = streams
            elif body.get("opt") == "get_task_list":
                answer["data"] = tasks
            elif body.get("opt") == "update_publish_switch":
                d = body.get("data", {})
                for s in streams:
                    if s["index"] == d.get("index"):
                        s["switch"] = d.get("switch", 0)
                        s["status"] = 2
                        if s["switch"] == 1:
                            threading.Thread(target=go_online, args=(s["index"],), daemon=True).start()
            elif body.get("opt") == "set_task_enable":
                d = body.get("data", {})
                for t in tasks:
                    if t["index"] == d.get("index"):
                        t["enable"] = d.get("enable", 0)
        out = json.dumps(answer).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, *a):
        pass

print(f"Fake Zowietek listening on http://127.0.0.1:{PORT} (login admin / admin)", flush=True)
ThreadingHTTPServer(("127.0.0.1", PORT), Box).serve_forever()
