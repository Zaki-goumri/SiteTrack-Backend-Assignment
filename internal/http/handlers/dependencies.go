package handlers

import (
	"net/http"
	"strings"

	"sitetrack/internal/apperr"
	"sitetrack/internal/db"
	"sitetrack/internal/http/middleware"
	"sitetrack/internal/http/respond"
)

func (a API) dependencyRoutes(mux *http.ServeMux, authed middleware.Wrap) {
	mux.Handle("POST /tasks/{code}/dependencies", authed(a.addDependency))
	mux.Handle("DELETE /tasks/{code}/dependencies/{dependsOn}", authed(a.removeDependency))
}

type dependencyRequest struct {
	DependsOn string `json:"depends_on"`
}

func (a API) addDependency(w http.ResponseWriter, r *http.Request) {
	var req dependencyRequest
	if err := respond.Decode(w, r, &req); err != nil {
		respond.Error(w, r, err)
		return
	}
	if strings.TrimSpace(req.DependsOn) == "" {
		respond.Error(w, r, apperr.New(http.StatusUnprocessableEntity, "depends_on is required"))
		return
	}
	a.call(w, r, http.StatusOK, "dependency_add", db.Args{"_code": r.PathValue("code"), "_depends_on": req.DependsOn})
}

func (a API) removeDependency(w http.ResponseWriter, r *http.Request) {
	a.call(w, r, http.StatusOK, "dependency_remove", db.Args{"_code": r.PathValue("code"), "_depends_on": r.PathValue("dependsOn")})
}
