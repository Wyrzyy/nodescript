#!/usr/bin/env python3
"""Mock Remnawave panel for testing nodescript's Hysteria2 API flow (shapes copied from the real panel)."""
import json, sys, uuid, threading
from http.server import BaseHTTPRequestHandler, HTTPServer

TOKEN = 'testtoken'
S = {'nodes': [], 'profiles': [], 'hosts': [], 'squads': [], 'log': []}

def U(): return str(uuid.uuid4())
def mk_inbounds(profile_uuid, cfg, old=None):
    old = {i['tag']: i['uuid'] for i in (old or [])}
    out = []
    for ib in cfg.get('inbounds', []):
        ss = ib.get('streamSettings') or {}
        out.append({'uuid': old.get(ib['tag'], U()), 'profileUuid': profile_uuid, 'tag': ib['tag'], 'type': ib['protocol'], 'network': ss.get('network'), 'security': ss.get('security'), 'port': ib.get('port'), 'rawInbound': ib})
    return out

def seed(mode):
    S.update({'nodes': [], 'profiles': [], 'hosts': [], 'squads': [], 'log': []})
    reality = {'tag': 'REAL-IN', 'port': 443, 'listen': '0.0.0.0', 'protocol': 'vless', 'settings': {'clients': [], 'decryption': 'none'}, 'streamSettings': {'network': 'raw', 'security': 'reality'}}
    pu = U(); cfg = {'log': {'loglevel': 'warning'}, 'inbounds': [reality], 'outbounds': [{'tag': 'DIRECT', 'protocol': 'freedom'}]}
    prof = {'uuid': pu, 'name': 'REALITY-PROFILE', 'config': cfg, 'inbounds': mk_inbounds(pu, cfg), 'nodes': []}
    S['profiles'].append(prof)
    def node(name, addr, withprof):
        n = {'uuid': U(), 'name': name, 'address': addr, 'port': 3000, 'isConnected': True,
             'configProfile': {'activeConfigProfileUuid': pu if withprof else None, 'activeInbounds': [dict(i) for i in prof['inbounds']] if withprof else []}}
        S['nodes'].append(n)
    node('Other node', '198.51.100.7', True)
    node('Game node', '203.0.113.10', mode != 'noprofile')
    for nm in ('users', 'Premium', 'Trial'):
        S['squads'].append({'uuid': U(), 'name': nm, 'info': {'membersCount': 10, 'inboundsCount': 1}, 'inbounds': [dict(i) for i in prof['inbounds']]})

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, code, obj):
        b = json.dumps(obj).encode(); self.send_response(code); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(b))); self.end_headers(); self.wfile.write(b)
    def _auth(self):
        if self.headers.get('Authorization') != f'Bearer {TOKEN}':
            self._send(401, {'message': 'Unauthorized', 'statusCode': 401}); return False
        return True
    def _body(self):
        n = int(self.headers.get('Content-Length') or 0); return json.loads(self.rfile.read(n) or b'{}')
    def do_GET(self):
        p = self.path.split('?')[0]
        if p == '/__reset':
            seed('noprofile' if 'noprofile' in self.path else 'profile'); return self._send(200, {})
        if p == '/__state': return self._send(200, S)
        if not self._auth(): return
        S['log'].append(('GET', p))
        if p == '/api/system/metadata': return self._send(200, {'response': {'version': '3.4.3'}})
        if p == '/api/nodes': return self._send(200, {'response': S['nodes']})
        if p == '/api/config-profiles': return self._send(200, {'response': {'total': len(S['profiles']), 'configProfiles': S['profiles']}})
        if p == '/api/hosts': return self._send(200, {'response': S['hosts']})
        if p == '/api/internal-squads': return self._send(200, {'response': {'total': len(S['squads']), 'internalSquads': S['squads']}})
        self._send(404, {'message': 'not found'})
    def do_POST(self):
        if not self._auth(): return
        p = self.path; b = self._body(); S['log'].append(('POST', p))
        if p == '/api/config-profiles':
            pu = U(); pr = {'uuid': pu, 'name': b['name'], 'config': b['config'], 'inbounds': mk_inbounds(pu, b['config']), 'nodes': []}
            S['profiles'].append(pr); return self._send(201, {'response': pr})
        if p == '/api/hosts':
            if not b.get('remark') or 'inbound' not in b: return self._send(400, {'message': 'Validation failed', 'errors': [{'message': 'remark required'}]})
            h = dict(b); h['uuid'] = U(); S['hosts'].append(h); return self._send(201, {'response': h})
        self._send(404, {'message': 'not found'})
    def do_PATCH(self):
        if not self._auth(): return
        p = self.path; b = self._body(); S['log'].append(('PATCH', p))
        if p == '/api/config-profiles':
            if S.get('fail_profile_patch'): return self._send(400, {'message': 'Validation failed', 'errors': [{'message': 'bad config'}]})
            pr = [x for x in S['profiles'] if x['uuid'] == b['uuid']][0]
            pr['config'] = b['config']; pr['inbounds'] = mk_inbounds(pr['uuid'], b['config'], pr['inbounds']); return self._send(200, {'response': pr})
        if p == '/api/nodes':
            n = [x for x in S['nodes'] if x['uuid'] == b['uuid']][0]; cp = b['configProfile']
            pr = [x for x in S['profiles'] if x['uuid'] == cp['activeConfigProfileUuid']][0]
            n['configProfile'] = {'activeConfigProfileUuid': cp['activeConfigProfileUuid'], 'activeInbounds': [i for i in pr['inbounds'] if i['uuid'] in cp['activeInbounds']]}
            return self._send(200, {'response': n})
        if p == '/api/internal-squads':
            sq = [x for x in S['squads'] if x['uuid'] == b['uuid']][0]
            allib = {i['uuid']: i for pr in S['profiles'] for i in pr['inbounds']}
            sq['inbounds'] = [allib[u] for u in b['inbounds']]; sq['info']['inboundsCount'] = len(sq['inbounds']); return self._send(200, {'response': sq})
        self._send(404, {'message': 'not found'})

if __name__ == '__main__':
    seed('profile'); port = int(sys.argv[1]) if len(sys.argv) > 1 else 18999
    HTTPServer(('127.0.0.1', port), H).serve_forever()
