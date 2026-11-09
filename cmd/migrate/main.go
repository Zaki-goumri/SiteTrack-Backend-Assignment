package main

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"time"

	"github.com/jackc/pgx/v5"

	sqlfiles "sitetrack/db"
	"sitetrack/internal/config"
	"sitetrack/internal/migrate"
)

func main() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, nil)))
	if err := run(); err != nil {
		slog.Error("migrate failed", "err", err)
		os.Exit(1)
	}
}

func run() error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	ctx := context.Background()
	conn, err := connect(ctx, cfg.AdminDatabaseURL)
	if err != nil {
		return err
	}
	defer conn.Close(ctx)

	r := migrate.Runner{Conn: conn, Files: sqlfiles.FS, APIDBUser: cfg.APIDBUser, APIDBPassword: cfg.APIDBPassword}
	cmd := "up"
	if len(os.Args) > 1 {
		cmd = os.Args[1]
	}
	switch cmd {
	case "up":
		return r.Up(ctx)
	case "seed":
		return r.Seed(ctx)
	}
	return fmt.Errorf("unknown command %q, use up or seed", cmd)
}

func connect(ctx context.Context, url string) (*pgx.Conn, error) {
	deadline := time.Now().Add(30 * time.Second)
	for {
		conn, err := pgx.Connect(ctx, url)
		if err == nil {
			return conn, nil
		}
		if time.Now().After(deadline) {
			return nil, fmt.Errorf("connect database: %w", err)
		}
		time.Sleep(time.Second)
	}
}
