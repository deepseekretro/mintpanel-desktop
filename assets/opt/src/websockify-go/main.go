// websockify-go: a drop-in replacement for websockify (WebSocket <-> TCP proxy).
//
// Why: websockify forks a whole Python process per connection (multiprocessing.Process
// in websockifyserver.py). On a memory-constrained container that is tens of MB per
// open noVNC tab. This implementation spends a goroutine pair per connection instead,
// ships as one statically linked binary and has no runtime dependencies.
package main

import (
	"context"
	"encoding/base64"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"mime"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"runtime/debug"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/gorilla/websocket"
)

var version = "dev"

type session struct {
	id     uint64
	ws     *websocket.Conn
	tcp    net.Conn
	peer   string
	proto  string
	up     atomic.Uint64
	down   atomic.Uint64
	closed sync.Once
}

func (s *session) close() {
	s.closed.Do(func() {
		_ = s.ws.Close()
		_ = s.tcp.Close()
	})
}

type proxy struct {
	listen      string
	target      string
	webDir      string
	wsPath      string
	statsPath   string
	pingEvery   time.Duration
	idleTimeout time.Duration
	maxConns    int
	verbose     bool

	up websocket.Upgrader

	mu     sync.Mutex
	conns  map[*session]struct{}
	nextID atomic.Uint64

	active    atomic.Int64
	total     atomic.Uint64
	bytesUp   atomic.Uint64
	bytesDown atomic.Uint64
	rejected  atomic.Uint64
}

func main() {
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)

	var p proxy
	flag.StringVar(&p.listen, "listen", "127.0.0.1:6080", "listen address")
	flag.StringVar(&p.target, "target", "127.0.0.1:5900", "TCP target (VNC server)")
	flag.StringVar(&p.webDir, "web", "", "serve this directory as static files (noVNC)")
	flag.StringVar(&p.wsPath, "ws-path", "/websockify", `upgrade only this path ("" = any path)`)
	flag.StringVar(&p.statsPath, "stats", "", "optional JSON stats endpoint, e.g. /__stats")
	flag.DurationVar(&p.pingEvery, "ping-interval", 0, "send websocket pings this often (0 = off)")
	flag.DurationVar(&p.idleTimeout, "idle-timeout", 0, "drop connections idle this long (0 = off)")
	flag.IntVar(&p.maxConns, "max-conns", 0, "reject new connections above this many (0 = unlimited)")
	flag.BoolVar(&p.verbose, "v", false, "log every connection open/close")
	showVer := flag.Bool("version", false, "print version and exit")
	flag.Parse()

	if *showVer {
		fmt.Println(version)
		return
	}

	p.up = websocket.Upgrader{
		ReadBufferSize:  64 << 10,
		WriteBufferSize: 64 << 10,
		Subprotocols:    []string{"binary", "base64"},
		// noVNC is served from the same origin (or through the panel reverse proxy),
		// and websockify itself accepts any origin: keep that behaviour.
		CheckOrigin: func(*http.Request) bool { return true },
		Error: func(w http.ResponseWriter, r *http.Request, status int, reason error) {
			if p.verbose {
				log.Printf("upgrade failed from %s: %d %v", r.RemoteAddr, status, reason)
			}
			w.WriteHeader(status)
		},
	}
	p.conns = make(map[*session]struct{})

	mux := http.NewServeMux()
	if p.wsPath != "" {
		mux.HandleFunc(p.wsPath, p.handleWS)
	} else {
		mux.HandleFunc("/", p.handleWS)
	}
	if p.webDir != "" {
		mux.HandleFunc("/", p.serveStatic)
	}
	if p.statsPath != "" {
		mux.HandleFunc(p.statsPath, p.handleStats)
	}

	srv := &http.Server{
		Addr:              p.listen,
		Handler:           mux,
		ReadHeaderTimeout: 15 * time.Second,
	}

	log.Printf("websockify-go %s listening on %s -> %s (web=%q ws-path=%q version=%s)",
		version, p.listen, p.target, p.webDir, p.wsPath, version)

	stop := make(chan os.Signal, 2)
	signal.Notify(stop, syscall.SIGTERM, syscall.SIGINT)
	go func() {
		sig := <-stop
		log.Printf("signal %v: draining %d connection(s)", sig, p.active.Load())
		p.closeAll()
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		_ = srv.Shutdown(ctx)
	}()

	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatalf("listen: %v", err)
	}
	log.Printf("bye (total=%d up=%d down=%d)", p.total.Load(), p.bytesUp.Load(), p.bytesDown.Load())
}

func (p *proxy) add(s *session) bool {
	if p.maxConns > 0 && p.active.Load() >= int64(p.maxConns) {
		p.rejected.Add(1)
		return false
	}
	p.mu.Lock()
	p.conns[s] = struct{}{}
	p.mu.Unlock()
	p.active.Add(1)
	p.total.Add(1)
	return true
}

func (p *proxy) remove(s *session) {
	p.mu.Lock()
	delete(p.conns, s)
	p.mu.Unlock()
	p.active.Add(-1)
	p.bytesUp.Add(s.up.Load())
	p.bytesDown.Add(s.down.Load())
	if p.verbose {
		log.Printf("conn#%d closed peer=%s proto=%s up=%dB down=%dB (active=%d)",
			s.id, s.peer, s.proto, s.up.Load(), s.down.Load(), p.active.Load())
	}
}

func (p *proxy) closeAll() {
	p.mu.Lock()
	list := make([]*session, 0, len(p.conns))
	for s := range p.conns {
		list = append(list, s)
	}
	p.mu.Unlock()
	for _, s := range list {
		s.close()
	}
}

func (p *proxy) handleWS(w http.ResponseWriter, r *http.Request) {
	defer func() {
		if rec := recover(); rec != nil {
			log.Printf("panic in ws handler (%s): %v\n%s", r.URL.Path, rec, debug.Stack())
		}
	}()

	ws, err := p.up.Upgrade(w, r, nil)
	if err != nil {
		return // Upgrade already replied with an HTTP error
	}

	s := &session{
		id:    p.nextID.Add(1),
		ws:    ws,
		peer:  r.RemoteAddr,
		proto: ws.Subprotocol(),
	}
	if s.proto == "" {
		s.proto = "binary" // websockify default when the client offers no subprotocol
	}
	if !p.add(s) {
		_ = ws.WriteControl(websocket.CloseMessage,
			websocket.FormatCloseMessage(websocket.CloseTryAgainLater, "server busy"),
			time.Now().Add(time.Second))
		_ = ws.Close()
		if p.verbose {
			log.Printf("conn#%d rejected: max-conns=%d", s.id, p.maxConns)
		}
		return
	}
	defer p.remove(s)
	defer s.close()

	d := net.Dialer{Timeout: 10 * time.Second, KeepAlive: 30 * time.Second}
	tcp, err := d.DialContext(r.Context(), "tcp", p.target)
	if err != nil {
		log.Printf("conn#%d dial %s failed: %v", s.id, p.target, err)
		_ = ws.WriteControl(websocket.CloseMessage,
			websocket.FormatCloseMessage(websocket.CloseInternalServerErr, "target unreachable"),
			time.Now().Add(time.Second))
		return
	}
	s.tcp = tcp
	if p.verbose {
		log.Printf("conn#%d open peer=%s proto=%s -> %s", s.id, s.peer, s.proto, p.target)
	}

	if p.pingEvery > 0 {
		_ = ws.SetReadDeadline(time.Now().Add(p.pingEvery * 2))
		ws.SetPongHandler(func(string) error {
			return ws.SetReadDeadline(time.Now().Add(p.pingEvery * 2))
		})
		go p.pinger(s)
	}
	if p.idleTimeout > 0 {
		go p.idleWatch(s)
	}

	b64 := s.proto == "base64"
	var wmu sync.Mutex // gorilla requires a single concurrent writer

	// TCP -> WebSocket
	go func() {
		defer s.close()
		buf := make([]byte, 64<<10)
		for {
			n, rerr := tcp.Read(buf)
			if n > 0 {
				s.down.Add(uint64(n))
				mt := websocket.BinaryMessage
				payload := buf[:n]
				if b64 {
					mt = websocket.TextMessage
					payload = []byte(base64.StdEncoding.EncodeToString(buf[:n]))
				}
				wmu.Lock()
				werr := ws.WriteMessage(mt, payload)
				wmu.Unlock()
				if werr != nil {
					return
				}
			}
			if rerr != nil {
				if !errors.Is(rerr, io.EOF) {
					if ne, ok := rerr.(net.Error); !ok || !ne.Timeout() {
						if p.verbose {
							log.Printf("conn#%d tcp read: %v", s.id, rerr)
						}
					}
				}
				return
			}
		}
	}()

	// WebSocket -> TCP
	for {
		mt, data, rerr := ws.ReadMessage()
		if rerr != nil {
			if p.verbose && !websocket.IsCloseError(rerr, websocket.CloseNormalClosure, websocket.CloseGoingAway) {
				log.Printf("conn#%d ws read: %v", s.id, rerr)
			}
			return
		}
		if b64 {
			if mt != websocket.TextMessage && mt != websocket.BinaryMessage {
				continue
			}
			decoded, derr := base64.StdEncoding.DecodeString(strings.TrimSpace(string(data)))
			if derr != nil {
				if p.verbose {
					log.Printf("conn#%d bad base64 frame: %v", s.id, derr)
				}
				continue
			}
			data = decoded
		} else if mt != websocket.BinaryMessage {
			continue
		}
		if len(data) == 0 {
			continue
		}
		s.up.Add(uint64(len(data)))
		if _, werr := tcp.Write(data); werr != nil {
			return
		}
	}
}

func (p *proxy) pinger(s *session) {
	t := time.NewTicker(p.pingEvery)
	defer t.Stop()
	for {
		select {
		case <-t.C:
			if err := s.ws.WriteControl(websocket.PingMessage, nil, time.Now().Add(5*time.Second)); err != nil {
				s.close()
				return
			}
		}
	}
}

func (p *proxy) idleWatch(s *session) {
	last := s.up.Load() + s.down.Load()
	t := time.NewTicker(p.idleTimeout / 4)
	defer t.Stop()
	for {
		select {
		case <-t.C:
			cur := s.up.Load() + s.down.Load()
			if cur != last {
				last = cur
				continue
			}
			// no traffic: rely on the counters staying flat for a full window
			last = cur
			time.Sleep(p.idleTimeout)
			if s.up.Load()+s.down.Load() != last {
				continue
			}
			if p.verbose {
				log.Printf("conn#%d idle timeout (%s)", s.id, p.idleTimeout)
			}
			s.close()
			return
		}
	}
}

func (p *proxy) serveStatic(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path == "/" || r.URL.Path == "" {
		for _, name := range []string{"vnc.html", "index.html"} {
			f := filepath.Join(p.webDir, name)
			if st, err := os.Stat(f); err == nil && !st.IsDir() {
				http.ServeFile(w, r, f)
				return
			}
		}
	}
	clean := filepath.Clean("/" + r.URL.Path)
	full := filepath.Join(p.webDir, clean)
	rel, err := filepath.Rel(p.webDir, full)
	if err != nil || strings.HasPrefix(rel, "..") {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	if st, err := os.Stat(full); err == nil && st.IsDir() {
		if !strings.HasSuffix(r.URL.Path, "/") {
			http.Redirect(w, r, r.URL.Path+"/", http.StatusMovedPermanently)
			return
		}
		for _, name := range []string{"vnc.html", "index.html"} {
			if f := filepath.Join(full, name); fileExists(f) {
				http.ServeFile(w, r, f)
				return
			}
		}
	}
	if !fileExists(full) {
		http.NotFound(w, r)
		return
	}
	// Go's mime table misses wasm on older releases
	if ext := strings.ToLower(filepath.Ext(full)); ext == ".wasm" {
		w.Header().Set("Content-Type", "application/wasm")
	} else if ext != "" {
		if ct := mime.TypeByExtension(ext); ct != "" {
			w.Header().Set("Content-Type", ct)
		}
	}
	http.ServeFile(w, r, full)
}

func fileExists(p string) bool {
	st, err := os.Stat(p)
	return err == nil && !st.IsDir()
}

func (p *proxy) handleStats(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	fmt.Fprintf(w, `{"version":%q,"active":%d,"total":%d,"rejected":%d,"bytes_up":%d,"bytes_down":%d,"max_conns":%d}`+"\n",
		version, p.active.Load(), p.total.Load(), p.rejected.Load(),
		p.bytesUp.Load(), p.bytesDown.Load(), p.maxConns)
}
