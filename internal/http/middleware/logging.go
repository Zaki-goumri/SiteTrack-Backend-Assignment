package middleware

import (
	"log/slog"
	"net/http"
	"runtime/debug"
	"time"

	"sitetrack/internal/apperr"
	"sitetrack/internal/http/respond"
)

type statusWriter struct {
	http.ResponseWriter
	status int
}

func (w *statusWriter) WriteHeader(status int) {
	w.status = status
	w.ResponseWriter.WriteHeader(status)
}

func Logger(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		sw := &statusWriter{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(sw, r)
		slog.InfoContext(r.Context(), "request", "method", r.Method, "path", r.URL.Path, "status", sw.status, "ms", time.Since(start).Milliseconds())
	})
}

func Recover(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if v := recover(); v != nil {
				slog.ErrorContext(r.Context(), "panic", "value", v, "stack", string(debug.Stack()))
				respond.JSON(w, http.StatusInternalServerError, apperr.New(http.StatusInternalServerError, "internal error"))
			}
		}()
		next.ServeHTTP(w, r)
	})
}
