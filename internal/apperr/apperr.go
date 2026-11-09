package apperr

import (
	"errors"
	"net/http"
	"strconv"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

type Error struct {
	Status  int    `json:"-"`
	Code    string `json:"code"`
	Message string `json:"message"`
}

func (e *Error) Error() string { return e.Code + ": " + e.Message }

func New(status int, message string) *Error {
	return &Error{Status: status, Code: codeFor(status), Message: message}
}

func BadRequest(message string) *Error   { return New(http.StatusBadRequest, message) }
func Unauthorized(message string) *Error { return New(http.StatusUnauthorized, message) }
func NotFound(message string) *Error     { return New(http.StatusNotFound, message) }

func FromDB(err error) error {
	if err == nil {
		return nil
	}
	if errors.Is(err, pgx.ErrNoRows) {
		return NotFound("not found")
	}
	var pg *pgconn.PgError
	if !errors.As(err, &pg) {
		return err
	}
	if strings.HasPrefix(pg.Code, "ST") {
		if status, convErr := strconv.Atoi(pg.Code[2:]); convErr == nil && status >= 400 && status < 500 {
			return New(status, pg.Message)
		}
	}
	switch pg.Code {
	case "23505":
		return New(http.StatusConflict, "already exists")
	case "23514", "23P01":
		return New(http.StatusConflict, "request breaks a data rule")
	case "23502":
		return New(http.StatusUnprocessableEntity, "a required value is missing")
	case "23503":
		return New(http.StatusUnprocessableEntity, "referenced record does not exist")
	case "40P01", "40001", "55P03":
		return New(http.StatusConflict, "another request changed the same data, please retry")
	case "22P02", "22007", "22008", "22003":
		return BadRequest("invalid input value")
	}
	return err
}

func codeFor(status int) string {
	switch status {
	case http.StatusBadRequest:
		return "bad_request"
	case http.StatusUnauthorized:
		return "unauthorized"
	case http.StatusForbidden:
		return "forbidden"
	case http.StatusNotFound:
		return "not_found"
	case http.StatusConflict:
		return "conflict"
	case http.StatusUnprocessableEntity:
		return "invalid"
	case http.StatusTooManyRequests:
		return "too_many_requests"
	}
	return "error"
}
