package handlers

import (
	"net/http"

	"sitetrack/internal/apperr"
	"sitetrack/internal/db"
	"sitetrack/internal/http/middleware"
	"sitetrack/internal/http/respond"
)

func (a API) memberRoutes(mux *http.ServeMux, authed middleware.Wrap) {
	mux.Handle("GET /projects/{code}/members", authed(a.listMembers))
	mux.Handle("PATCH /projects/{code}/members/{userID}", authed(a.updateMember))
	mux.Handle("DELETE /projects/{code}/members/{userID}", authed(a.removeMember))
}

func (a API) listMembers(w http.ResponseWriter, r *http.Request) {
	a.call(w, r, http.StatusOK, "get_members_list", db.Args{"_code": r.PathValue("code")})
}

type memberRequest struct {
	IsAdmin *bool `json:"is_admin"`
}

func (a API) updateMember(w http.ResponseWriter, r *http.Request) {
	userID, err := pathInt64(r, "userID")
	if err != nil {
		respond.Error(w, r, err)
		return
	}
	var req memberRequest
	if err := respond.Decode(w, r, &req); err != nil {
		respond.Error(w, r, err)
		return
	}
	if req.IsAdmin == nil {
		respond.Error(w, r, apperr.New(http.StatusUnprocessableEntity, "is_admin is required"))
		return
	}
	a.call(w, r, http.StatusOK, "member_set_admin", db.Args{"_code": r.PathValue("code"), "_user_id": userID, "_is_admin": *req.IsAdmin})
}

func (a API) removeMember(w http.ResponseWriter, r *http.Request) {
	userID, err := pathInt64(r, "userID")
	if err != nil {
		respond.Error(w, r, err)
		return
	}
	a.call(w, r, http.StatusNoContent, "member_remove", db.Args{"_code": r.PathValue("code"), "_user_id": userID})
}
