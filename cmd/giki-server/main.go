// Command giki-server is giki's sync server: one static binary, one SQLite
// file, no runtime dependencies.
//
//	giki-server -db giki.sqlite -tokens "s3cret:alice"
//	giki-server -db giki.sqlite -dev-user alice   # local development only
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/guettli/giki/internal/auth"
	"github.com/guettli/giki/internal/passkey"
	"github.com/guettli/giki/internal/store"
	"github.com/guettli/giki/internal/syncapi"
)

func main() {
	if err := run(); err != nil {
		slog.Error("giki-server stopped", "error", err)
		os.Exit(1)
	}
}

func run() error {
	addr := flag.String("addr", "127.0.0.1:8080", "address to listen on")
	dbPath := flag.String("db", "giki.sqlite", "path to the SQLite database")
	tokens := flag.String("tokens", os.Getenv("GIKI_TOKENS"),
		`bearer tokens as "token:user,token:user" (default $GIKI_TOKENS)`)
	devUser := flag.String("dev-user", "",
		"INSECURE: authenticate every request as this user, for local development")
	passkeyDomain := flag.String("passkey-domain", os.Getenv("GIKI_PASSKEY_DOMAIN"),
		"domain passkeys are bound to, without scheme or port, e.g.\n"+
			"giki.example.org (default $GIKI_PASSKEY_DOMAIN). Enables the\n"+
			"WebAuthn endpoints; a credential registered here cannot be used\n"+
			"anywhere else, which is what makes passkeys unphishable.")
	passkeyOrigins := flag.String("passkey-origin", os.Getenv("GIKI_PASSKEY_ORIGIN"),
		"comma-separated origins a passkey ceremony may happen at, e.g.\n"+
			"https://giki.example.org (default $GIKI_PASSKEY_ORIGIN). Defaults\n"+
			"to https://<passkey-domain> when unset.")
	registerToken := flag.String("register-token", os.Getenv("GIKI_REGISTER_TOKEN"),
		"token required to register a passkey for a NEW account (default\n"+
			"$GIKI_REGISTER_TOKEN). Already signed-in users need no token to\n"+
			"add another authenticator. Unset means new accounts are closed,\n"+
			"which is the right default while giki has no authorization.")
	webRoot := flag.String("web-root", os.Getenv("GIKI_WEB_ROOT"),
		"directory holding the built Flutter web app; serves it on the same\n"+
			"origin as the API, which is what a production deployment wants\n"+
			"(default $GIKI_WEB_ROOT, empty for API only)")
	logLevel := flag.String("log-level", "info", "debug, info, warn or error")
	corsOrigins := flag.String("cors-origin", os.Getenv("GIKI_CORS_ORIGIN"),
		"comma-separated origins allowed to call the API from a browser,\n"+
			"e.g. http://localhost:8081 (default $GIKI_CORS_ORIGIN). Needed\n"+
			"only when the PWA is served from a different origin than this server.")
	flag.Parse()

	level, err := parseLevel(*logLevel)
	if err != nil {
		return err
	}
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: level}))
	slog.SetDefault(logger)

	st, err := store.Open(*dbPath)
	if err != nil {
		return err
	}
	defer st.Close()

	passkeys, err := buildPasskeys(*passkeyDomain, *passkeyOrigins, st, logger)
	if err != nil {
		return err
	}

	authenticator, err := buildAuth(st, *tokens, *devUser, passkeys != nil, logger)
	if err != nil {
		return err
	}

	cursor, err := st.Cursor(context.Background())
	if err != nil {
		return err
	}
	logger.Info("database ready", "path", *dbPath, "cursor", cursor)

	origins, err := parseOrigins(*corsOrigins)
	if err != nil {
		return err
	}

	var opts []syncapi.Option
	if passkeys != nil {
		opts = append(opts, syncapi.WithPasskeys(passkeys, *registerToken))
		if *registerToken == "" {
			logger.Info("passkeys enabled; new accounts are closed (no -register-token)")
		} else {
			logger.Info("passkeys enabled; new accounts may be registered with the token")
		}
	}
	if *webRoot != "" {
		// Fail here rather than serving 500s: a typo in this path would
		// otherwise look like a broken deployment.
		index := filepath.Join(*webRoot, "index.html")
		if _, err := os.Stat(index); err != nil {
			return fmt.Errorf("-web-root %q has no index.html: %w", *webRoot, err)
		}
		opts = append(opts, syncapi.WithWebRoot(*webRoot))
		logger.Info("serving the web app", "web_root", *webRoot)
	}

	handler := syncapi.CORS(origins, syncapi.New(st, authenticator, logger, opts...).Routes())
	if len(origins) > 0 {
		logger.Info("cross-origin requests allowed", "origins", origins)
	}

	server := &http.Server{
		Addr:              *addr,
		Handler:           handler,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       60 * time.Second,
		WriteTimeout:      60 * time.Second,
		IdleTimeout:       120 * time.Second,
	}

	// Shut down on SIGINT/SIGTERM so in-flight sync batches finish committing
	// instead of being cut off mid-transaction.
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	errs := make(chan error, 1)
	go func() {
		logger.Info("listening", "addr", *addr)
		if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errs <- err
			return
		}
		errs <- nil
	}()

	select {
	case err := <-errs:
		return err
	case <-ctx.Done():
		logger.Info("shutting down")
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		if err := server.Shutdown(shutdownCtx); err != nil {
			return fmt.Errorf("shutdown: %w", err)
		}
		return nil
	}
}

// buildPasskeys configures the WebAuthn relying party, or returns nil when
// -passkey-domain was not given.
func buildPasskeys(domain, origins string, st *store.Store, logger *slog.Logger) (*passkey.Service, error) {
	if domain == "" {
		return nil, nil
	}
	if strings.Contains(domain, "/") || strings.Contains(domain, ":") {
		return nil, fmt.Errorf("-passkey-domain %q must be a bare domain, without scheme or port", domain)
	}

	var list []string
	for _, origin := range strings.Split(origins, ",") {
		if trimmed := strings.TrimSpace(origin); trimmed != "" {
			list = append(list, trimmed)
		}
	}
	if len(list) == 0 {
		// The overwhelmingly common case, and getting it wrong is a confusing
		// browser-side error rather than a server one.
		list = []string{"https://" + domain}
		logger.Info("no -passkey-origin given; assuming one", "origin", list[0])
	}

	service, err := passkey.New(passkey.Config{
		RPID:        domain,
		DisplayName: "giki",
		Origins:     list,
	}, st)
	if err != nil {
		return nil, err
	}
	logger.Info("passkeys configured", "domain", domain, "origins", list)
	return service, nil
}

// buildAuth assembles the ways a request may prove who it is.
//
// A chain rather than a choice: a passkey session and an operator's static
// token are both legitimate, and the sync endpoints should not care which one
// a request brought.
func buildAuth(st *store.Store, tokens, devUser string, passkeysEnabled bool, logger *slog.Logger) (auth.Authenticator, error) {
	if devUser != "" && tokens != "" {
		return nil, errors.New("-dev-user and -tokens are mutually exclusive")
	}

	var chain auth.Chain
	if tokens != "" {
		static, err := auth.ParseTokens(tokens)
		if err != nil {
			return nil, err
		}
		chain = append(chain, static)
	}
	if passkeysEnabled {
		chain = append(chain, auth.NewSessions(st))
	}
	// Last: it accepts everything, so anything after it would be unreachable.
	if devUser != "" {
		logger.Warn("INSECURE: -dev-user authenticates every request", "user_id", devUser)
		chain = append(chain, auth.OpenDev{UserID: devUser})
	}

	if len(chain) == 0 {
		return nil, errors.New("no authentication configured: pass -passkey-domain for passkeys, " +
			"-tokens (or $GIKI_TOKENS) for static tokens, or -dev-user for local development")
	}
	return chain, nil
}

// parseOrigins splits the -cors-origin list and refuses the ones that would
// not work.
//
// "*" is rejected rather than ignored: it is matched against the Origin header,
// which is never literally "*", so accepting it would log "cross-origin
// requests allowed" and then fail every browser request -- the most confusing
// possible outcome for whoever wrote it.
func parseOrigins(spec string) ([]string, error) {
	var origins []string
	for _, origin := range strings.Split(spec, ",") {
		origin = strings.TrimSpace(origin)
		switch {
		case origin == "":
			continue
		case origin == "*":
			return nil, errors.New(`-cors-origin does not accept "*": list the exact origins, e.g. https://giki.example.org`)
		case !strings.HasPrefix(origin, "http://") && !strings.HasPrefix(origin, "https://"):
			return nil, fmt.Errorf("-cors-origin %q is not an origin: it must start with http:// or https://", origin)
		case strings.HasSuffix(origin, "/"):
			return nil, fmt.Errorf("-cors-origin %q must not end in a slash: a browser sends the origin without a path", origin)
		}
		origins = append(origins, origin)
	}
	return origins, nil
}

func parseLevel(name string) (slog.Level, error) {
	var level slog.Level
	if err := level.UnmarshalText([]byte(name)); err != nil {
		return level, fmt.Errorf("invalid -log-level %q", name)
	}
	return level, nil
}
