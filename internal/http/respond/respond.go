package respond

import (
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"

	"sitetrack/internal/apperr"
)

const maxBodyBytes = 1 << 20

func JSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func Raw(w http.ResponseWriter, status int, body []byte) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_, _ = w.Write(body)
}

func NoContent(w http.ResponseWriter) { w.WriteHeader(http.StatusNoContent) }

func Error(w http.ResponseWriter, r *http.Request, err error) {
	var e *apperr.Error
	if errors.As(err, &e) {
		JSON(w, e.Status, e)
		return
	}
	slog.ErrorContext(r.Context(), "request failed", "method", r.Method, "path", r.URL.Path, "err", err)
	JSON(w, http.StatusInternalServerError, apperr.New(http.StatusInternalServerError, "internal error"))
}

func Decode(w http.ResponseWriter, r *http.Request, dst any) error {
	r.Body = http.MaxBytesReader(w, r.Body, maxBodyBytes)
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(dst); err != nil {
		if errors.Is(err, io.EOF) {
			return apperr.BadRequest("request body is empty")
		}
		return apperr.BadRequest("invalid json: " + err.Error())
	}
	if dec.More() {
		return apperr.BadRequest("request body must hold one json object")
	}
	return nil
}
