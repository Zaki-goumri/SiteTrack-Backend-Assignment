package config

import (
	"fmt"
	"net/url"
	"os"
	"strconv"
	"time"
)

type Config struct {
	Port             string
	DatabaseURL      string
	AdminDatabaseURL string
	APIDBUser        string
	APIDBPassword    string
	DBMaxConns       int32
	JWTSecret        []byte
	AccessTTL        time.Duration
	RefreshTTL       time.Duration
}

func Load() (Config, error) {
	host := env("POSTGRES_HOST", "localhost")
	port := env("POSTGRES_PORT", "5432")
	name := env("POSTGRES_DB", "sitetrack")

	c := Config{
		Port:          env("API_PORT", "8080"),
		APIDBUser:     env("API_DB_USER", "sitetrack_api"),
		APIDBPassword: env("API_DB_PASSWORD", "sitetrack_api"),
		JWTSecret:     []byte(env("JWT_SECRET", "")),
	}
	c.DatabaseURL = dsn(c.APIDBUser, c.APIDBPassword, host, port, name)
	c.AdminDatabaseURL = dsn(env("POSTGRES_USER", "sitetrack"), env("POSTGRES_PASSWORD", "sitetrack"), host, port, name)

	var err error
	if c.AccessTTL, err = time.ParseDuration(env("ACCESS_TOKEN_TTL", "15m")); err != nil {
		return c, fmt.Errorf("ACCESS_TOKEN_TTL: %w", err)
	}
	if c.RefreshTTL, err = time.ParseDuration(env("REFRESH_TOKEN_TTL", "720h")); err != nil {
		return c, fmt.Errorf("REFRESH_TOKEN_TTL: %w", err)
	}
	maxConns, err := strconv.Atoi(env("DB_MAX_CONNS", "10"))
	if err != nil || maxConns < 1 {
		return c, fmt.Errorf("DB_MAX_CONNS: must be a positive number")
	}
	c.DBMaxConns = int32(maxConns)
	return c, nil
}

func (c Config) Validate() error {
	if len(c.JWTSecret) < 32 {
		return fmt.Errorf("JWT_SECRET: must be at least 32 characters")
	}
	return nil
}

func dsn(user, pass, host, port, name string) string {
	u := url.URL{Scheme: "postgres", User: url.UserPassword(user, pass), Host: host + ":" + port, Path: name, RawQuery: "sslmode=disable"}
	return u.String()
}

func env(key, def string) string {
	if v, ok := os.LookupEnv(key); ok && v != "" {
		return v
	}
	return def
}
