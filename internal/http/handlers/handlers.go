package handlers

import (
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5/pgtype"

	"sitetrack/internal/apperr"
	"sitetrack/internal/db"
	"sitetrack/internal/http/middleware"
	"sitetrack/internal/http/respond"
)

type API struct {
	DB *db.DB
}

func (a API) Routes(mux *http.ServeMux, authed middleware.Wrap) {
	a.projectRoutes(mux, authed)
	a.memberRoutes(mux, authed)
	a.invitationRoutes(mux, authed)
	a.notificationRoutes(mux, authed)
	a.taskRoutes(mux, authed)
	a.dependencyRoutes(mux, authed)
	a.materialRoutes(mux, authed)
	a.stockRoutes(mux, authed)
	a.deliveryRoutes(mux, authed)
	a.userRoutes(mux, authed)
}

func (a API) call(w http.ResponseWriter, r *http.Request, status int, fn string, args db.Args) {
	args["_sid"] = middleware.Session(r.Context()).UUID()
	raw, err := a.DB.Call(r.Context(), fn, args)
	if err != nil {
		respond.Error(w, r, err)
		return
	}
	if status == http.StatusNoContent {
		respond.NoContent(w)
		return
	}
	respond.Raw(w, status, raw)
}

type Date struct{ time.Time }

func (d *Date) UnmarshalJSON(b []byte) error {
	var s string
	if err := json.Unmarshal(b, &s); err != nil {
		return err
	}
	t, err := time.Parse(time.DateOnly, s)
	if err != nil {
		return apperr.BadRequest("dates must use YYYY-MM-DD")
	}
	d.Time = t
	return nil
}

func dateArg(d *Date) any {
	if d == nil {
		return nil
	}
	return d.Time
}

func strArg(s *string) any {
	if s == nil {
		return nil
	}
	return strings.TrimSpace(*s)
}

func queryStr(r *http.Request, key string) any {
	v := strings.TrimSpace(r.URL.Query().Get(key))
	if v == "" {
		return nil
	}
	return v
}

func queryInt(r *http.Request, key string) (any, error) {
	v := r.URL.Query().Get(key)
	if v == "" {
		return nil, nil
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return nil, apperr.BadRequest(key + " must be a whole number")
	}
	return n, nil
}

func queryInt64(r *http.Request, key string) (any, error) {
	v := r.URL.Query().Get(key)
	if v == "" {
		return nil, nil
	}
	n, err := strconv.ParseInt(v, 10, 64)
	if err != nil {
		return nil, apperr.BadRequest(key + " must be a whole number")
	}
	return n, nil
}

func pathInt64(r *http.Request, key string) (int64, error) {
	n, err := strconv.ParseInt(r.PathValue(key), 10, 64)
	if err != nil || n < 1 {
		return 0, apperr.NotFound("not found")
	}
	return n, nil
}

func numArg(n json.Number, field string) (pgtype.Numeric, error) {
	var v pgtype.Numeric
	if n == "" {
		return v, apperr.New(http.StatusUnprocessableEntity, field+" is required")
	}
	if err := v.Scan(string(n)); err != nil {
		return v, apperr.BadRequest(field + " must be a number")
	}
	return v, nil
}

func checkText(v *string, field string, required bool, max int) error {
	if v == nil {
		if required {
			return apperr.New(http.StatusUnprocessableEntity, field+" is required")
		}
		return nil
	}
	n := utf8.RuneCountInString(strings.TrimSpace(*v))
	if n == 0 || n > max {
		return apperr.New(http.StatusUnprocessableEntity, field+" must be 1 to "+strconv.Itoa(max)+" characters")
	}
	return nil
}

func checkName(name *string, required bool) error {
	if name == nil {
		if required {
			return apperr.New(http.StatusUnprocessableEntity, "name is required")
		}
		return nil
	}
	n := utf8.RuneCountInString(strings.TrimSpace(*name))
	if n == 0 || n > 200 {
		return apperr.New(http.StatusUnprocessableEntity, "name must be 1 to 200 characters")
	}
	return nil
}
