package handlers

import (
	"net/http"

	"sitetrack/internal/apperr"
	"sitetrack/internal/db"
	"sitetrack/internal/http/middleware"
	"sitetrack/internal/http/respond"
)

func (a API) invitationRoutes(mux *http.ServeMux, authed middleware.Wrap) {
	mux.Handle("POST /projects/{code}/invitations", authed(a.createInvitation))
	mux.Handle("DELETE /projects/{code}/invitations/{id}", authed(a.withdrawInvitation))
	mux.Handle("POST /invitations/{id}/accept", authed(a.answerInvitation(true)))
	mux.Handle("POST /invitations/{id}/reject", authed(a.answerInvitation(false)))
}

type invitationRequest struct {
	UserID *int64 `json:"user_id"`
}

func (a API) createInvitation(w http.ResponseWriter, r *http.Request) {
	var req invitationRequest
	if err := respond.Decode(w, r, &req); err != nil {
		respond.Error(w, r, err)
		return
	}
	if req.UserID == nil {
		respond.Error(w, r, apperr.New(http.StatusUnprocessableEntity, "user_id is required"))
		return
	}
	a.call(w, r, http.StatusCreated, "invitation_create", db.Args{"_code": r.PathValue("code"), "_user_id": *req.UserID})
}

func (a API) withdrawInvitation(w http.ResponseWriter, r *http.Request) {
	id, err := pathInt64(r, "id")
	if err != nil {
		respond.Error(w, r, err)
		return
	}
	a.call(w, r, http.StatusNoContent, "invitation_withdraw", db.Args{"_code": r.PathValue("code"), "_invitation_id": id})
}

func (a API) answerInvitation(accept bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id, err := pathInt64(r, "id")
		if err != nil {
			respond.Error(w, r, err)
			return
		}
		a.call(w, r, http.StatusOK, "invitation_answer", db.Args{"_invitation_id": id, "_accept": accept})
	}
}
