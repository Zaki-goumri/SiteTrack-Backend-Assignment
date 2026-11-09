package handlers

import (
	"net/http"
	"time"

	"sitetrack/internal/apperr"
	"sitetrack/internal/db"
	"sitetrack/internal/http/middleware"
	"sitetrack/internal/http/respond"
)

func (a API) taskRoutes(mux *http.ServeMux, authed middleware.Wrap) {
	mux.Handle("GET /projects/{code}/tasks", authed(a.listTasks))
	mux.Handle("POST /projects/{code}/tasks", authed(a.createTask))
	mux.Handle("GET /tasks/{code}", authed(a.getTask))
	mux.Handle("PATCH /tasks/{code}", authed(a.updateTask))
	mux.Handle("DELETE /tasks/{code}", authed(a.deleteTask))
	mux.Handle("POST /tasks/{code}/start", authed(a.taskAction("start")))
	mux.Handle("POST /tasks/{code}/done", authed(a.taskAction("mark_done")))
	mux.Handle("POST /tasks/{code}/reopen", authed(a.taskAction("reopen")))
}

func (a API) listTasks(w http.ResponseWriter, r *http.Request) {
	args := db.Args{"_code": r.PathValue("code"), "_status": queryStr(r, "status"), "_search": queryStr(r, "search")}
	for key, param := range map[string]string{"_late": "late", "_blocked": "blocked"} {
		v, err := queryBool(r, param)
		if err != nil {
			respond.Error(w, r, err)
			return
		}
		args[key] = v
	}
	for key, param := range map[string]string{"_from": "from", "_to": "to"} {
		v, err := queryDate(r, param)
		if err != nil {
			respond.Error(w, r, err)
			return
		}
		args[key] = v
	}
	for key, param := range map[string]string{"_limit": "limit", "_offset": "offset"} {
		v, err := queryInt(r, param)
		if err != nil {
			respond.Error(w, r, err)
			return
		}
		args[key] = v
	}
	if v := queryStr(r, "sort"); v != nil {
		args["_sort"] = v
	}
	if v := queryStr(r, "dir"); v != nil {
		args["_dir"] = v
	}
	a.call(w, r, http.StatusOK, "get_tasks_list", args)
}

type taskRequest struct {
	Name         *string `json:"name"`
	PlannedStart *Date   `json:"planned_start"`
	PlannedEnd   *Date   `json:"planned_end"`
}

func (a API) createTask(w http.ResponseWriter, r *http.Request) {
	var req taskRequest
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
	a.call(w, r, http.StatusCreated, "task_create", db.Args{
		"_code":          r.PathValue("code"),
		"_name":          strArg(req.Name),
		"_planned_start": dateArg(req.PlannedStart),
		"_planned_end":   dateArg(req.PlannedEnd),
	})
}

func (a API) getTask(w http.ResponseWriter, r *http.Request) {
	a.call(w, r, http.StatusOK, "task_get", db.Args{"_code": r.PathValue("code")})
}

func (a API) updateTask(w http.ResponseWriter, r *http.Request) {
	var req taskRequest
	if err := respond.Decode(w, r, &req); err != nil {
		respond.Error(w, r, err)
		return
	}
	if err := checkName(req.Name, false); err != nil {
		respond.Error(w, r, err)
		return
	}
	a.call(w, r, http.StatusOK, "task_update", db.Args{
		"_code":          r.PathValue("code"),
		"_name":          strArg(req.Name),
		"_planned_start": dateArg(req.PlannedStart),
		"_planned_end":   dateArg(req.PlannedEnd),
	})
}

func (a API) deleteTask(w http.ResponseWriter, r *http.Request) {
	a.call(w, r, http.StatusNoContent, "task_delete", db.Args{"_code": r.PathValue("code")})
}

func (a API) taskAction(action string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		a.call(w, r, http.StatusOK, "task_action", db.Args{"_code": r.PathValue("code"), "_action": action})
	}
}

func queryBool(r *http.Request, key string) (any, error) {
	switch r.URL.Query().Get(key) {
	case "":
		return nil, nil
	case "true", "1":
		return true, nil
	case "false", "0":
		return false, nil
	}
	return nil, apperr.BadRequest(key + " must be true or false")
}

func queryDate(r *http.Request, key string) (any, error) {
	v := r.URL.Query().Get(key)
	if v == "" {
		return nil, nil
	}
	t, err := time.Parse(time.DateOnly, v)
	if err != nil {
		return nil, apperr.BadRequest(key + " must use YYYY-MM-DD")
	}
	return t, nil
}
