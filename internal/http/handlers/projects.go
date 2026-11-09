package handlers

import (
	"net/http"

	"sitetrack/internal/apperr"
	"sitetrack/internal/db"
	"sitetrack/internal/http/middleware"
	"sitetrack/internal/http/respond"
)

func (a API) projectRoutes(mux *http.ServeMux, authed middleware.Wrap) {
	mux.Handle("GET /projects", authed(a.listProjects))
	mux.Handle("POST /projects", authed(a.createProject))
	mux.Handle("GET /projects/{code}", authed(a.getProject))
	mux.Handle("PATCH /projects/{code}", authed(a.updateProject))
	mux.Handle("DELETE /projects/{code}", authed(a.deleteProject))
}

func (a API) listProjects(w http.ResponseWriter, r *http.Request) {
	limit, err := queryInt(r, "limit")
	if err != nil {
		respond.Error(w, r, err)
		return
	}
	offset, err := queryInt(r, "offset")
	if err != nil {
		respond.Error(w, r, err)
		return
	}
	onlyLate, err := queryBool(r, "late")
	if err != nil {
		respond.Error(w, r, err)
		return
	}
	args := db.Args{"_search": queryStr(r, "search"), "_only_late": onlyLate, "_limit": limit, "_offset": offset}
	if v := queryStr(r, "sort"); v != nil {
		args["_sort"] = v
	}
	if v := queryStr(r, "dir"); v != nil {
		args["_dir"] = v
	}
	a.call(w, r, http.StatusOK, "get_projects_list", args)
}

type projectRequest struct {
	Name         *string `json:"name"`
	PlannedStart *Date   `json:"planned_start"`
	PlannedEnd   *Date   `json:"planned_end"`
}

func (a API) createProject(w http.ResponseWriter, r *http.Request) {
	var req projectRequest
	if err := respond.Decode(w, r, &req); err != nil {
		respond.Error(w, r, err)
		return
	}
	if err := checkName(req.Name, true); err != nil {
		respond.Error(w, r, err)
		return
	}
	if req.PlannedStart == nil || req.PlannedEnd == nil {
		respond.Error(w, r, apperr.New(http.StatusUnprocessableEntity, "planned_start and planned_end are required"))
		return
	}
	a.call(w, r, http.StatusCreated, "project_create", db.Args{
		"_name":          strArg(req.Name),
		"_planned_start": dateArg(req.PlannedStart),
		"_planned_end":   dateArg(req.PlannedEnd),
	})
}

func (a API) getProject(w http.ResponseWriter, r *http.Request) {
	a.call(w, r, http.StatusOK, "project_get", db.Args{"_code": r.PathValue("code")})
}

func (a API) updateProject(w http.ResponseWriter, r *http.Request) {
	var req projectRequest
	if err := respond.Decode(w, r, &req); err != nil {
		respond.Error(w, r, err)
		return
	}
	if err := checkName(req.Name, false); err != nil {
		respond.Error(w, r, err)
		return
	}
	a.call(w, r, http.StatusOK, "project_update", db.Args{
		"_code":          r.PathValue("code"),
		"_name":          strArg(req.Name),
		"_planned_start": dateArg(req.PlannedStart),
		"_planned_end":   dateArg(req.PlannedEnd),
	})
}

func (a API) deleteProject(w http.ResponseWriter, r *http.Request) {
	a.call(w, r, http.StatusNoContent, "project_delete", db.Args{"_code": r.PathValue("code")})
}
