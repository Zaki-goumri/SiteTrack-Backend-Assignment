package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"runtime"
	"syscall"
	"time"

	"sitetrack/internal/auth"
	"sitetrack/internal/config"
	"sitetrack/internal/db"
	httpapi "sitetrack/internal/http"
)

func main() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, nil)))
	if err := run(); err != nil {
		slog.Error("api stopped", "err", err)
		os.Exit(1)
	}
}

func run() error {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	cfg, err := config.Load()
	if err != nil {
		return err
	}
	if err := cfg.Validate(); err != nil {
		return err
	}

	database, err := db.Open(ctx, cfg.DatabaseURL, cfg.DBMaxConns)
	if err != nil {
		return err
	}
	defer database.Close()

	hasher, err := auth.NewHasher(max(1, runtime.NumCPU()))
	if err != nil {
		return err
	}
	router := httpapi.NewRouter(httpapi.Deps{
		DB:         database,
		Tokens:     auth.NewTokens(cfg.JWTSecret, cfg.AccessTTL),
		Hasher:     hasher,
		RefreshTTL: cfg.RefreshTTL,
	})
	srv := httpapi.NewServer(":"+cfg.Port, router)
	errCh := make(chan error, 1)
	go func() {
		slog.Info("api listening", "port", cfg.Port)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
		}
		close(errCh)
	}()

	select {
	case err := <-errCh:
		return err
	case <-ctx.Done():
	}

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	return srv.Shutdown(shutdownCtx)
}
