package auth

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"strconv"
	"strings"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

const issuer = "sitetrack"

var ErrInvalidToken = errors.New("auth: invalid token")

type Session struct {
	UserID int64
	SID    string
	uuid   [16]byte
}

func (s Session) UUID() [16]byte { return s.uuid }

type claims struct {
	SID string `json:"sid"`
	jwt.RegisteredClaims
}

type Tokens struct {
	secret    []byte
	accessTTL time.Duration
}

func NewTokens(secret []byte, accessTTL time.Duration) *Tokens {
	return &Tokens{secret: secret, accessTTL: accessTTL}
}

func (t *Tokens) AccessTTL() time.Duration { return t.accessTTL }

func (t *Tokens) Issue(s Session) (string, error) {
	now := time.Now()
	c := claims{
		SID: s.SID,
		RegisteredClaims: jwt.RegisteredClaims{
			Issuer:    issuer,
			Subject:   strconv.FormatInt(s.UserID, 10),
			IssuedAt:  jwt.NewNumericDate(now),
			ExpiresAt: jwt.NewNumericDate(now.Add(t.accessTTL)),
		},
	}
	return jwt.NewWithClaims(jwt.SigningMethodHS256, c).SignedString(t.secret)
}

func (t *Tokens) Parse(raw string) (Session, error) {
	var c claims
	_, err := jwt.ParseWithClaims(raw, &c, func(*jwt.Token) (any, error) { return t.secret, nil },
		jwt.WithValidMethods([]string{jwt.SigningMethodHS256.Alg()}),
		jwt.WithIssuer(issuer),
		jwt.WithExpirationRequired(),
	)
	if err != nil || c.SID == "" {
		return Session{}, ErrInvalidToken
	}
	userID, err := strconv.ParseInt(c.Subject, 10, 64)
	if err != nil {
		return Session{}, ErrInvalidToken
	}
	id, err := parseUUID(c.SID)
	if err != nil {
		return Session{}, ErrInvalidToken
	}
	return Session{UserID: userID, SID: c.SID, uuid: id}, nil
}

func parseUUID(s string) ([16]byte, error) {
	var id [16]byte
	h := strings.ReplaceAll(s, "-", "")
	if len(h) != 32 {
		return id, ErrInvalidToken
	}
	_, err := hex.Decode(id[:], []byte(h))
	return id, err
}

func NewRefreshToken() (string, []byte, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", nil, err
	}
	token := base64.RawURLEncoding.EncodeToString(b)
	return token, HashRefreshToken(token), nil
}

func HashRefreshToken(token string) []byte {
	sum := sha256.Sum256([]byte(token))
	return sum[:]
}
