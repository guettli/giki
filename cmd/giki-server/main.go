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
	"syscall"
	"time"

	"github.com/guettli/giki/internal/auth"
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
	logLevel := flag.String("log-level", "info", "debug, info, warn or error")
	flag.Parse()

	level, err := parseLevel(*logLevel)
	if err != nil {
		return err
	}
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: level}))
	slog.SetDefault(logger)

	authenticator, err := buildAuth(*tokens, *devUser, logger)
	if err != nil {
		return err
	}

	st, err := store.Open(*dbPath)
	if err != nil {
		return err
	}
	defer st.Close()

	cursor, err := st.Cursor(context.Background())
	if err != nil {
		return err
	}
	logger.Info("database ready", "path", *dbPath, "cursor", cursor)

	server := &http.Server{
		Addr:              *addr,
		Handler:           syncapi.New(st, authenticator, logger).Routes(),
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

func buildAuth(tokens, devUser string, logger *slog.Logger) (auth.Authenticator, error) {
	switch {
	case devUser != "" && tokens != "":
		return nil, errors.New("-dev-user and -tokens are mutually exclusive")
	case devUser != "":
		logger.Warn("INSECURE: -dev-user authenticates every request",
			"user_id", devUser)
		return auth.OpenDev{UserID: devUser}, nil
	case tokens != "":
		return auth.ParseTokens(tokens)
	default:
		return nil, errors.New("no authentication configured: pass -tokens (or $GIKI_TOKENS), or -dev-user for local development")
	}
}

func parseLevel(name string) (slog.Level, error) {
	var level slog.Level
	if err := level.UnmarshalText([]byte(name)); err != nil {
		return level, fmt.Errorf("invalid -log-level %q", name)
	}
	return level, nil
}
