// WebPanel: the panel as a web page on the local network, for a phone or another computer.
//
// Security:
// - It is off until the user turns it on. The setting stays after a restart of the app.
// - Each installation has a random key (128 bits). The address that the panel shows contains the
//   key; the page then keeps it in a cookie (HttpOnly, SameSite=Strict). A request without the key
//   gets "403 Forbidden".
// - It accepts only connections from loopback, private and link-local addresses.
// - Changes need a POST with the header "X-QC: 1", so another web site cannot send them.
// - "New key" makes all old addresses and cookies invalid.
import AppKit
import CoreImage
import Foundation
import Network

final class WebPanel: ObservableObject {
    static let port: UInt16 = 8745
    private static let enabledKey = "webPanelEnabled"
    private static let tokenKey = "webPanelToken"

    @Published private(set) var running = false
    @Published private(set) var url: String?
    @Published private(set) var error: String?
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: WebPanel.enabledKey)
            enabled ? start() : stop()
        }
    }

    private let model: PanelModel
    private let audio: AudioDevice
    private let queue = DispatchQueue(label: "com.louistissot.quadcapture.panel.web")
    private var listener: NWListener?
    private let tokenLock = NSLock()   // the server queue reads the key, the main thread changes it
    private var _token: String
    private var token: String {
        get { tokenLock.lock(); defer { tokenLock.unlock() }; return _token }
        set { tokenLock.lock(); _token = newValue; tokenLock.unlock() }
    }

    init(model: PanelModel, audio: AudioDevice) {
        self.model = model
        self.audio = audio
        _token = UserDefaults.standard.string(forKey: WebPanel.tokenKey) ?? WebPanel.newToken()
        UserDefaults.standard.set(_token, forKey: WebPanel.tokenKey)
        enabled = UserDefaults.standard.bool(forKey: WebPanel.enabledKey)
        if enabled { start() }
    }

    func newKey() {
        token = WebPanel.newToken()
        UserDefaults.standard.set(token, forKey: WebPanel.tokenKey)
        updateURL()
    }

    func stop() {
        listener?.cancel()
        listener = nil
        running = false
        url = nil
    }

    private static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func start() {
        guard listener == nil else { return }
        do {
            let l = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: WebPanel.port)!)
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    switch state {
                    case .ready:
                        self.running = true
                        self.error = nil
                        self.updateURL()
                    case .failed(let e):
                        self.error = "The web panel cannot start: \(e.localizedDescription)"
                        self.stop()
                    default: break
                    }
                }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            self.error = "The web panel cannot start: \(error.localizedDescription)"
        }
    }

    private func updateURL() {
        guard running else { url = nil; return }
        url = "http://\(WebPanel.localAddress() ?? "127.0.0.1"):\(WebPanel.port)/?k=\(token)"
    }

    // The first private IPv4 address of this Mac (Wi-Fi or Ethernet).
    private static func localAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var found: String?
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  ifa.ifa_flags & UInt32(IFF_UP) != 0, ifa.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            let b = withUnsafeBytes(of: addr.s_addr) { Array($0) }
            guard isPrivate(v4: b) else { continue }
            found = b.map(String.init).joined(separator: ".")
            if String(cString: ifa.ifa_name).hasPrefix("en") { break }
        }
        return found
    }

    private static func isPrivate(v4 b: [UInt8]) -> Bool {
        b[0] == 127 || b[0] == 10 || (b[0] == 172 && b[1] & 0xF0 == 16) || (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254)
    }

    private static func allowed(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let a): return isPrivate(v4: [UInt8](a.rawValue))
        case .ipv6(let a):
            if a.isLoopback { return true }
            let b = [UInt8](a.rawValue)
            if b[0] == 0xFE && b[1] & 0xC0 == 0x80 { return true }   // link-local fe80::/10
            if b[0] & 0xFE == 0xFC { return true }                     // unique local fc00::/7
            if let v4 = a.asIPv4 { return isPrivate(v4: [UInt8](v4.rawValue)) }
            return false
        default: return false
        }
    }

    // MARK: HTTP

    private struct Request {
        var method = "", path = "", query: [String: String] = [:], headers: [String: String] = [:], body = Data()
    }

    private func accept(_ c: NWConnection) {
        guard WebPanel.allowed(c.endpoint) else { c.cancel(); return }
        c.start(queue: queue)
        receive(c, Data())
        // A client that does not complete its request in 10 s loses the connection.
        queue.asyncAfter(deadline: .now() + 10) { c.cancel() }
    }

    private func receive(_ c: NWConnection, _ buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, err in
            guard let self = self else { c.cancel(); return }
            var buf = buffer
            if let d = data { buf.append(d) }
            if err != nil || buf.count > 65536 { c.cancel(); return }
            if let req = WebPanel.parse(buf) {
                self.handle(req, c)
            } else if complete {
                c.cancel()
            } else {
                self.receive(c, buf)
            }
        }
    }

    // Returns the request when the headers and the body are complete.
    private static func parse(_ data: Data) -> Request? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: data[..<end.lowerBound], encoding: .utf8) else { return Request(method: "BAD") }
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return Request(method: "BAD") }
        var r = Request()
        r.method = String(first[0])
        let target = String(first[1])
        let parts = target.split(separator: "?", maxSplits: 1)
        r.path = String(parts.first ?? "/")
        if parts.count == 2 {
            for item in parts[1].split(separator: "&") {
                let kv = item.split(separator: "=", maxSplits: 1)
                if kv.count == 2 { r.query[String(kv[0])] = String(kv[1]) }
            }
        }
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            r.headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard let length = Int(r.headers["content-length"] ?? "0"), (0...65536).contains(length) else { return Request(method: "BAD") }
        let bodyStart = end.upperBound
        if data.count - bodyStart < length { return nil }
        r.body = data[bodyStart..<(bodyStart + length)]
        return r
    }

    private func cookieToken(_ r: Request) -> String? {
        for part in (r.headers["cookie"] ?? "").split(separator: ";") {
            let kv = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
            if kv.count == 2 && kv[0] == "qc" { return String(kv[1]) }
        }
        return nil
    }

    private func same(_ a: String?, _ b: String) -> Bool {
        guard let a = a, a.utf8.count == b.utf8.count else { return false }
        return zip(a.utf8, b.utf8).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0   // same time for all inputs
    }

    // A web site can point its own name at a local address (DNS rebinding). Thus the panel accepts
    // only requests to an IP address, "localhost" or a ".local" name.
    private static func hostAllowed(_ host: String?) -> Bool {
        guard var h = host?.lowercased(), !h.isEmpty else { return false }
        if h.hasPrefix("[") { return true }                                           // IPv6 literal
        if let colon = h.lastIndex(of: ":") { h = String(h[..<colon]) }               // remove the port
        if h == "localhost" || h.hasSuffix(".local") { return true }
        let parts = h.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }

    private func handle(_ r: Request, _ c: NWConnection) {
        guard r.method != "BAD", WebPanel.hostAllowed(r.headers["host"]) else {
            send(c, status: "400 Bad Request", type: "text/plain", body: Data())
            return
        }
        let token = self.token
        if r.method == "GET" && r.path == "/" {
            if same(r.query["k"], token) {
                // Keep the key in a cookie, and remove it from the address bar.
                send(c, status: "303 See Other", type: "text/plain", body: Data(),
                     extra: ["Location: /", "Set-Cookie: qc=\(token); HttpOnly; SameSite=Strict; Path=/; Max-Age=31536000"])
            } else if same(cookieToken(r), token) {
                send(c, status: "200 OK", type: "text/html; charset=utf-8", body: Data(WebPanel.page.utf8))
            } else {
                send(c, status: "403 Forbidden", type: "text/plain; charset=utf-8",
                     body: Data("Open the address that QuadCapture Panel shows (it contains the key).\n".utf8))
            }
            return
        }
        guard same(cookieToken(r), token) else {
            send(c, status: "403 Forbidden", type: "text/plain", body: Data())
            return
        }
        switch (r.method, r.path) {
        case ("GET", "/state"):
            DispatchQueue.main.async {
                let body = (try? JSONSerialization.data(withJSONObject: self.state())) ?? Data("{}".utf8)
                self.queue.async { self.send(c, status: "200 OK", type: "application/json", body: body) }
            }
        case ("POST", "/set"):
            guard r.headers["x-qc"] == "1",
                  let obj = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any] else {
                send(c, status: "400 Bad Request", type: "text/plain", body: Data())
                return
            }
            DispatchQueue.main.async {
                self.apply(obj)
                self.queue.async { self.send(c, status: "204 No Content", type: "text/plain", body: Data()) }
            }
        default:
            send(c, status: "404 Not Found", type: "text/plain", body: Data())
        }
    }

    private func send(_ c: NWConnection, status: String, type: String, body: Data, extra: [String] = []) {
        var head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nX-Frame-Options: DENY\r\n"
        head += "Content-Security-Policy: default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'\r\n"
        for line in extra { head += line + "\r\n" }
        head += "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        c.send(content: data, completion: .contentProcessed { _ in c.cancel() })
    }

    // MARK: State and commands (main thread)

    private func state() -> [String: Any] {
        let m = model
        var inputs: [[String: Any]] = []
        for ch in 0..<2 {
            var d: [String: Any] = [:]
            for p in Parameter.allCases {
                d["\(p.rawValue)"] = ["v": m.inputs[ch][p], "t": p.text(m.inputs[ch][p]), "max": p.maximum]
            }
            inputs.append(d)
        }
        let meters = m.meters
        return [
            "link": linkText(m.link), "connected": m.canEdit, "inputs": inputs, "stereoLink": m.stereoLink,
            "mixer": m.mixer.map { ["db": $0 <= 0 ? -61 : max(-60, MixerLevel.decibels($0)), "t": MixerLevel.text($0)] },
            "autoSens": m.autoSens, "rate": audio.sampleRate, "rates": audio.availableRates,
            "meters": meters.active.contains(true) ? meters.level.map { Double($0) } : [], "clip": meters.clip,
        ]
    }

    private func linkText(_ l: PanelModel.Link) -> String {
        switch l {
        case .open: return "Connected"
        case .opening: return "Connecting"
        case .busy, .released: return "Another process uses the control channel"
        case .noReply: return "The QUAD-CAPTURE does not answer"
        case .noDevice: return "QUAD-CAPTURE not connected"
        }
    }

    private func apply(_ o: [String: Any]) {
        guard let what = o["what"] as? String else { return }
        let raw = o["v"] as? Double ?? 0
        guard raw.isFinite else { return }
        let v = min(1_000_000, max(-1_000_000, raw))   // Int(v) traps for very large values
        switch what {
        case "param":
            guard let ch = o["ch"] as? Int, (0...1).contains(ch), let raw = o["p"] as? Int,
                  let p = Parameter(rawValue: UInt8(clamping: raw)) else { return }
            model.set(ch, p, Int(v))
        case "link": model.setStereoLink(v != 0)
        case "mixer":
            guard let i = o["i"] as? Int, (0...2).contains(i) else { return }
            model.setMixer(i, MixerLevel.raw(v))
        case "autosens": model.pressAutoSens()
        case "rate": if audio.availableRates.contains(v) { audio.setSampleRate(v) }
        default: break
        }
    }

    // MARK: QR code

    func qrImage() -> NSImage? {
        guard let url = url, let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        f.setValue(Data(url.utf8), forKey: "inputMessage")
        f.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 6, y: 6)) else { return nil }
        let rep = NSCIImageRep(ciImage: out)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    // MARK: Page

    static let page = """
<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>QuadCapture Panel</title>
<style>
:root{--bg:#f4f4f6;--card:#fff;--fg:#1c1c1e;--muted:#6e6e73;--acc:#0a7cff;--line:#d9d9de}
@media (prefers-color-scheme:dark){:root{--bg:#1c1c1e;--card:#2c2c2e;--fg:#f2f2f7;--muted:#a1a1a6;--acc:#409cff;--line:#3a3a3c}}
*{box-sizing:border-box}body{margin:0;font:15px -apple-system,system-ui,sans-serif;background:var(--bg);color:var(--fg)}
header{padding:12px 16px;display:flex;gap:12px;align-items:center;flex-wrap:wrap}
h1{font-size:17px;margin:0}#st{color:var(--muted);font-size:13px}
main{display:grid;grid-template-columns:repeat(auto-fit,minmax(300px,1fr));gap:12px;padding:0 16px 16px}
section{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:12px}
h2{font-size:15px;margin:0 0 8px}
.row{display:grid;grid-template-columns:92px 1fr 78px;gap:8px;align-items:center;margin:6px 0}
.row span:last-child{text-align:right;font-variant-numeric:tabular-nums;font-size:13px}
input[type=range]{width:100%;accent-color:var(--acc)}label.t{margin-right:16px;white-space:nowrap}
button,select{font:inherit;padding:6px 12px;border-radius:8px;border:1px solid var(--line);background:var(--card);color:var(--fg)}
button.on{background:var(--acc);color:#fff;border-color:var(--acc)}
.m{height:8px;background:var(--line);border-radius:4px;overflow:hidden;margin:4px 0 8px}
.m i{display:block;height:100%;width:0;background:linear-gradient(90deg,#34c759 70%,#ffcc00 85%,#ff3b30)}
.dis{opacity:.5;pointer-events:none}
</style></head><body>
<header><h1>QuadCapture Panel</h1><span id="st">...</span></header>
<main id="main">
<section id="in0"><h2>IN 1</h2></section>
<section id="in1"><h2>IN 2</h2></section>
<section><h2>Monitor mixer (OUTPUT 1-2)</h2><div id="mix"></div>
<div class="row"><span>COAX level</span><div><div class="m"><i id="m2"></i></div></div><span></span></div>
<p><label class="t"><input type="checkbox" id="link"> Stereo link</label>
<button id="as">AUTO-SENS</button></p>
<p>Sample rate <select id="rate"></select></p></section>
</main>
<script>
const P=[[4,'SENS'],[10,'Threshold'],[11,'Ratio'],[8,'Attack'],[9,'Release'],[7,'Gate'],[12,'Gain']];
const T=[[1,'LO-CUT'],[2,'PHASE'],[6,'Compressor']];
let busy=null,timer=null;
function post(o){return fetch('/set',{method:'POST',headers:{'X-QC':'1','Content-Type':'application/json'},body:JSON.stringify(o)})}
function later(o){clearTimeout(timer);timer=setTimeout(()=>post(o),60)}
function row(parent,name,id,min,max,step,send){
 const r=document.createElement('div');r.className='row';
 r.innerHTML='<span>'+name+'</span><input type=range min='+min+' max='+max+' step='+step+' id='+id+'><span id='+id+'t></span>';
 parent.appendChild(r);const e=r.querySelector('input');
 e.addEventListener('pointerdown',()=>busy=id);e.addEventListener('pointerup',()=>setTimeout(()=>busy=null,500));
 e.addEventListener('input',()=>{busy=id;later(send(+e.value))});
}
for(const ch of [0,1]){
 const s=document.getElementById('in'+ch);
 const m=document.createElement('div');m.className='m';m.innerHTML='<i id=m'+ch+'></i>';s.appendChild(m);
 const t=document.createElement('p');s.appendChild(t);
 for(const[p,n]of T){const l=document.createElement('label');l.className='t';
  l.innerHTML='<input type=checkbox id=c'+ch+'_'+p+'> '+n;t.appendChild(l);
  l.querySelector('input').addEventListener('change',e=>post({what:'param',ch,p,v:e.target.checked?1:0}))}
 for(const[p,n]of P)row(s,n,'p'+ch+'_'+p,0,1,1,v=>({what:'param',ch,p,v}));
}
['INPUT 1','INPUT 2','COAX'].forEach((n,i)=>row(document.getElementById('mix'),n,'x'+i,-61,12,0.5,v=>({what:'mixer',i,v})));
document.getElementById('link').addEventListener('change',e=>post({what:'link',v:e.target.checked?1:0}));
document.getElementById('as').addEventListener('click',()=>post({what:'autosens'}));
document.getElementById('rate').addEventListener('change',e=>post({what:'rate',v:+e.target.value}));
function bar(i,db){const e=document.getElementById('m'+i);if(e)e.style.width=(db==null?0:Math.max(0,(db+60)/60*100))+'%'}
async function poll(){
 try{const r=await fetch('/state');if(r.status==403){document.getElementById('st').textContent='Open the address that the app shows.';return}
 const s=await r.json();
 document.getElementById('st').textContent=s.link+(s.rate?' \\u00b7 '+s.rate/1000+' kHz':'');
 document.getElementById('main').classList.toggle('dis',!s.connected);
 s.inputs.forEach((d,ch)=>{
  for(const[p]of T){const e=document.getElementById('c'+ch+'_'+p);e.checked=d[p].v!=0}
  for(const[p]of P){const id='p'+ch+'_'+p,e=document.getElementById(id);e.max=d[p].max;
   if(busy!=id)e.value=d[p].v;document.getElementById(id+'t').textContent=d[p].t}});
 s.mixer.forEach((x,i)=>{const id='x'+i;if(busy!=id)document.getElementById(id).value=x.db;document.getElementById(id+'t').textContent=x.t});
 document.getElementById('link').checked=s.stereoLink;
 document.getElementById('as').classList.toggle('on',s.autoSens==2);
 const sel=document.getElementById('rate');
 if(sel.options.length!=s.rates.length){sel.innerHTML=s.rates.map(r=>'<option value='+r+'>'+r/1000+' kHz</option>').join('')}
 if(document.activeElement!=sel)sel.value=s.rate;
 for(let i=0;i<3;i++)bar(i,s.meters.length?s.meters[i]:null);
 }catch(e){document.getElementById('st').textContent='No connection to the Mac'}
 setTimeout(poll,150);
}
poll();
</script></body></html>
"""
}
