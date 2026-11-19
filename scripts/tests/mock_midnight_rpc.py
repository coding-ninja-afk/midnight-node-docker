"""Mock Midnight (Substrate) JSON-RPC for testing scripts/midnight-height-check.sh.

Usage: python3 -I mock_midnight_rpc.py PORT MODE
Chain state is a function of seconds since start (t), so samples taken 30 s apart see
realistic movement. Modes: ready, catching_up, syncing_flag, stalled, falling_behind,
unknown_highest, finality_stuck, ahead_of_highest.
"""
import http.server
import json
import sys
import time

PORT, MODE = int(sys.argv[1]), sys.argv[2]
T0 = time.time()


def state():
    t = int(time.time() - T0)
    tip = 1000 + t // 6                      # normal 6 s block production
    s = {"best": tip, "fin": tip - 2, "high": tip + 1, "syncing": False, "peers": 8}
    if MODE == "catching_up":                # importing ~20 blocks/s, far behind
        s.update(best=1000 + t * 20, high=100000 + t // 6, syncing=True)
        s["fin"] = s["best"] - 2
    elif MODE == "syncing_flag":             # at tip but node still says isSyncing
        s["syncing"] = True
    elif MODE == "stalled":
        s.update(best=1000, fin=998, high=1001)
    elif MODE == "falling_behind":           # advancing, but network grows faster
        s.update(high=5000 + t // 2, syncing=True)
    elif MODE == "unknown_highest":
        s["high"] = None
    elif MODE == "ahead_of_highest":         # node imported a block peers haven't announced yet
        s["high"] = tip - 1
    elif MODE == "finality_stuck":
        s["fin"] = 990
    return s


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        req = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        s, method, params = state(), req["method"], req.get("params", [])
        result = {
            "chain_getHeader": {"number": hex(s["fin"] if params else s["best"])},
            "chain_getFinalizedHead": "0xfinalized",
            "system_syncState": {"startingBlock": 0, "currentBlock": s["best"], "highestBlock": s["high"]},
            "system_health": {"peers": s["peers"], "isSyncing": s["syncing"], "shouldHavePeers": True},
        }[method]
        body = json.dumps({"jsonrpc": "2.0", "id": req["id"], "result": result}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)


http.server.HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
