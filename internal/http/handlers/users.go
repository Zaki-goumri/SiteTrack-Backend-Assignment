package handlers

import (
	"net/http"

	"sitetrack/internal/db"
	"sitetrack/internal/http/middleware"
	"sitetrack/internal/http/respond"
)

func (a API) userRoutes(mux *http.ServeMux, authed middleware.Wrap) {
	mux.Handle("GET /users", authed(a.listUsers))
}

func (a API) listUsers(w http.ResponseWriter, r *http.Request) {
	limit, err := queryInt(r, "limit")
	if err != nil {
		respond.Error(w, r, err)
		return
	}
	a.call(w, r, http.StatusOK, "get_users_list", db.Args{"_search": queryStr(r, "search"), "_limit": limit})
}
