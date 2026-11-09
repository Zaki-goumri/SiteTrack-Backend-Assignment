package middleware

import (
	"context"
	"net/http"
	"strings"

	"sitetrack/internal/apperr"
	"sitetrack/internal/auth"
	"sitetrack/internal/http/respond"
)

type sessionKey struct{}

type Wrap func(http.HandlerFunc) http.Handler

func RequireAuth(tokens *auth.Tokens) Wrap {
	return func(next http.HandlerFunc) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			raw, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
			if !ok || raw == "" {
				respond.Error(w, r, apperr.Unauthorized("missing bearer token"))
				return
			}
			s, err := tokens.Parse(strings.TrimSpace(raw))
			if err != nil {
				respond.Error(w, r, apperr.Unauthorized("invalid or expired token"))
				return
			}
			next(w, r.WithContext(context.WithValue(r.Context(), sessionKey{}, s)))
		})
	}
}

func Session(ctx context.Context) auth.Session {
	s, _ := ctx.Value(sessionKey{}).(auth.Session)
	return s
}
