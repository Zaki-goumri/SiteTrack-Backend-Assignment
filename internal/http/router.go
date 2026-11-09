package httpapi

import (
	"context"
	"net/http"
	"time"

	apidocs "sitetrack/api"
	"sitetrack/internal/auth"
	"sitetrack/internal/db"
	"sitetrack/internal/http/handlers"
	"sitetrack/internal/http/middleware"
	"sitetrack/internal/http/respond"
)

type Deps struct {
	DB         *db.DB
	Tokens     *auth.Tokens
	Hasher     *auth.Hasher
	RefreshTTL time.Duration
}

func NewRouter(d Deps) http.Handler {
	mux := http.NewServeMux()
	authed := middleware.RequireAuth(d.Tokens)

	mux.HandleFunc("GET /health", health(d.DB))
	mux.HandleFunc("GET /openapi.yaml", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/yaml")
		_, _ = w.Write(apidocs.Spec)
	})
	mux.HandleFunc("GET /docs", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write([]byte(apidocs.Page))
	})
	handlers.Auth{DB: d.DB, Tokens: d.Tokens, Hasher: d.Hasher, RefreshTTL: d.RefreshTTL}.Routes(mux, authed)
	handlers.API{DB: d.DB}.Routes(mux, authed)

	return middleware.Recover(middleware.Logger(mux))
}

func health(database *db.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
		defer cancel()
		if err := database.Ping(ctx); err != nil {
			respond.JSON(w, http.StatusServiceUnavailable, map[string]string{"status": "db_down"})
			return
		}
		respond.JSON(w, http.StatusOK, map[string]string{"status": "ok"})
	}
}
