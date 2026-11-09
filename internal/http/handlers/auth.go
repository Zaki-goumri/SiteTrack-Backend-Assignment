package handlers

import (
	"encoding/json"
	"net/http"
	"net/mail"
	"strings"
	"time"
	"unicode/utf8"

	"sitetrack/internal/apperr"
	"sitetrack/internal/auth"
	"sitetrack/internal/db"
	"sitetrack/internal/http/middleware"
	"sitetrack/internal/http/respond"
)

type Auth struct {
	DB         *db.DB
	Tokens     *auth.Tokens
	Hasher     *auth.Hasher
	RefreshTTL time.Duration
}

func (h Auth) Routes(mux *http.ServeMux, authed middleware.Wrap) {
	mux.HandleFunc("POST /auth/register", h.register)
	mux.HandleFunc("POST /auth/login", h.login)
	mux.HandleFunc("POST /auth/refresh", h.refresh)
	mux.Handle("POST /auth/logout", authed(h.logout))
	mux.Handle("GET /me", authed(h.me))
}

type tokenResponse struct {
	AccessToken  string          `json:"access_token"`
	TokenType    string          `json:"token_type"`
	ExpiresIn    int             `json:"expires_in"`
	RefreshToken string          `json:"refresh_token"`
	User         json.RawMessage `json:"user,omitempty"`
}

type registerRequest struct {
	Name     string `json:"name"`
	Email    string `json:"email"`
	Password string `json:"password"`
	AppRole  string `json:"app_role"`
}

func (h Auth) register(w http.ResponseWriter, r *http.Request) {
	var req registerRequest
	if err := respond.Decode(w, r, &req); err != nil {
		respond.Error(w, r, err)
		return
	}
	email, err := validateRegister(&req)
	if err != nil {
		respond.Error(w, r, err)
		return
	}
	hash, err := h.Hasher.Hash(r.Context(), req.Password)
	if err != nil {
		respond.Error(w, r, err)
		return
	}
	user, err := h.DB.Call(r.Context(), "auth_register", db.Args{"_name": req.Name, "_email": email, "_password_hash": hash, "_app_role": req.AppRole})
	if err != nil {
		respond.Error(w, r, err)
		return
	}
	var u struct {
		ID int64 `json:"id"`
	}
	if err := json.Unmarshal(user, &u); err != nil {
		respond.Error(w, r, err)
		return
	}
	h.startSession(w, r, u.ID, http.StatusCreated)
}

type loginRequest struct {
	Email    string `json:"email"`
	Password string `json:"password"`
}

func (h Auth) login(w http.ResponseWriter, r *http.Request) {
	var req loginRequest
	if err := respond.Decode(w, r, &req); err != nil {
		respond.Error(w, r, err)
		return
	}
	failed := apperr.Unauthorized("invalid email or password")
	raw, err := h.DB.Call(r.Context(), "auth_login_lookup", db.Args{"_email": strings.TrimSpace(req.Email)})
	if err != nil {
		respond.Error(w, r, err)
		return
	}
	var found struct {
		UserID       int64  `json:"user_id"`
		PasswordHash string `json:"password_hash"`
	}
	if string(raw) == "null" {
		h.Hasher.VerifyDummy(r.Context(), req.Password)
		respond.Error(w, r, failed)
		return
	}
	if err := json.Unmarshal(raw, &found); err != nil {
		respond.Error(w, r, err)
		return
	}
	ok, err := h.Hasher.Verify(r.Context(), req.Password, found.PasswordHash)
	if err != nil {
		respond.Error(w, r, err)
		return
	}
	if !ok {
		respond.Error(w, r, failed)
		return
	}
	h.startSession(w, r, found.UserID, http.StatusOK)
}

type refreshRequest struct {
	RefreshToken string `json:"refresh_token"`
}

func (h Auth) refresh(w http.ResponseWriter, r *http.Request) {
	var req refreshRequest
	if err := respond.Decode(w, r, &req); err != nil {
		respond.Error(w, r, err)
		return
	}
	if req.RefreshToken == "" {
		respond.Error(w, r, apperr.BadRequest("refresh_token is required"))
		return
	}
	token, hash, err := auth.NewRefreshToken()
	if err != nil {
		respond.Error(w, r, err)
		return
	}
	raw, err := h.DB.Call(r.Context(), "auth_refresh", db.Args{
		"_refresh_hash":     auth.HashRefreshToken(req.RefreshToken),
		"_new_refresh_hash": hash,
		"_ttl_seconds":      int(h.RefreshTTL.Seconds()),
	})
	if err != nil {
		respond.Error(w, r, err)
		return
	}
	if string(raw) == "null" {
		respond.Error(w, r, apperr.Unauthorized("invalid or expired refresh token"))
		return
	}
	var s struct {
		SID    string `json:"sid"`
		UserID int64  `json:"user_id"`
	}
	if err := json.Unmarshal(raw, &s); err != nil {
		respond.Error(w, r, err)
		return
	}
	access, err := h.Tokens.Issue(auth.Session{UserID: s.UserID, SID: s.SID})
	if err != nil {
		respond.Error(w, r, err)
		return
	}
	respond.JSON(w, http.StatusOK, h.tokens(access, token, nil))
}

func (h Auth) logout(w http.ResponseWriter, r *http.Request) {
	s := middleware.Session(r.Context())
	if _, err := h.DB.Call(r.Context(), "auth_logout", db.Args{"_sid": s.UUID()}); err != nil {
		respond.Error(w, r, err)
		return
	}
	respond.NoContent(w)
}

func (h Auth) me(w http.ResponseWriter, r *http.Request) {
	s := middleware.Session(r.Context())
	user, err := h.DB.Call(r.Context(), "me", db.Args{"_sid": s.UUID()})
	if err != nil {
		respond.Error(w, r, err)
		return
	}
	respond.Raw(w, http.StatusOK, user)
}

func (h Auth) startSession(w http.ResponseWriter, r *http.Request, userID int64, status int) {
	token, hash, err := auth.NewRefreshToken()
	if err != nil {
		respond.Error(w, r, err)
		return
	}
	raw, err := h.DB.Call(r.Context(), "auth_session_create", db.Args{"_user_id": userID, "_refresh_hash": hash, "_ttl_seconds": int(h.RefreshTTL.Seconds())})
	if err != nil {
		respond.Error(w, r, err)
		return
	}
	var s struct {
		SID  string          `json:"sid"`
		User json.RawMessage `json:"user"`
	}
	if err := json.Unmarshal(raw, &s); err != nil {
		respond.Error(w, r, err)
		return
	}
	access, err := h.Tokens.Issue(auth.Session{UserID: userID, SID: s.SID})
	if err != nil {
		respond.Error(w, r, err)
		return
	}
	respond.JSON(w, status, h.tokens(access, token, s.User))
}

func (h Auth) tokens(access, refresh string, user json.RawMessage) tokenResponse {
	return tokenResponse{AccessToken: access, TokenType: "Bearer", ExpiresIn: int(h.Tokens.AccessTTL().Seconds()), RefreshToken: refresh, User: user}
}

func validateRegister(req *registerRequest) (string, error) {
	req.Name = strings.TrimSpace(req.Name)
	if req.Name == "" || utf8.RuneCountInString(req.Name) > 200 {
		return "", apperr.New(http.StatusUnprocessableEntity, "name is required and must be at most 200 characters")
	}
	email := strings.ToLower(strings.TrimSpace(req.Email))
	addr, err := mail.ParseAddress(email)
	if err != nil || addr.Address != email || len(email) > 320 {
		return "", apperr.New(http.StatusUnprocessableEntity, "email is not valid")
	}
	if n := utf8.RuneCountInString(req.Password); n < 8 || n > 128 {
		return "", apperr.New(http.StatusUnprocessableEntity, "password must be 8 to 128 characters")
	}
	return email, nil
}
