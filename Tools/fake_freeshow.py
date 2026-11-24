#!/usr/bin/env python3
"""A pretend FreeShow REST API, for trying CueVideo's bumper buttons with no FreeShow.

    python3 Tools/fake_freeshow.py [port] [seconds]   (default 5506, 12-second videos)

Answers the actions CueVideo sends: play_media starts a pretend video of the given length,
get_playing_video_time_left counts it down (an empty answer at 0, as FreeShow gives),
clear_background stops it, get_cleared answers. Prints each action.
"""
import json, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 5506
LENGTH = float(sys.argv[2]) if len(sys.argv) > 2 else 12.0
started = None

class FreeShow(BaseHTTPRequestHandler):
    def do_POST(self):
        global started
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        action = body.get("action")
        print(action, json.dumps({k: v for k, v in body.items() if k != "action"}), flush=True)
        out = None
        if action == "play_media":
            started = time.time()
        elif action == "clear_background":
            started = None
        elif action == "get_playing_video_time_left" and started is not None:
            left = LENGTH - (time.time() - started)
            if left > 0:
                out = left
        elif action == "get_cleared":
            out = {"background": started is None}
        if out is None:
            self.send_response(204)
            self.end_headers()
            return
        data = json.dumps({"action": action, "data": out}).encode()  # as FreeShow answers
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *a):
        pass

print(f"Fake FreeShow on http://127.0.0.1:{PORT} ({LENGTH:g}-second videos)", flush=True)
ThreadingHTTPServer(("127.0.0.1", PORT), FreeShow).serve_forever()
