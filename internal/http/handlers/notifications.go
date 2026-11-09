package handlers

import (
	"net/http"

	"sitetrack/internal/db"
	"sitetrack/internal/http/middleware"
	"sitetrack/internal/http/respond"
)

func (a API) notificationRoutes(mux *http.ServeMux, authed middleware.Wrap) {
	mux.Handle("GET /notifications", authed(a.listNotifications))
	mux.Handle("GET /notifications/unread-count", authed(a.unreadCount))
	mux.Handle("POST /notifications/read", authed(a.markRead))
}

func (a API) listNotifications(w http.ResponseWriter, r *http.Request) {
	limit, err := queryInt(r, "limit")
	if err != nil {
		respond.Error(w, r, err)
		return
	}
	cursor, err := queryInt64(r, "cursor")
	if err != nil {
		respond.Error(w, r, err)
		return
	}
	a.call(w, r, http.StatusOK, "get_notifications_list", db.Args{"_limit": limit, "_cursor": cursor})
}

func (a API) unreadCount(w http.ResponseWriter, r *http.Request) {
	a.call(w, r, http.StatusOK, "notifications_unread_count", db.Args{})
}

type markReadRequest struct {
	IDs []int64 `json:"ids"`
}

func (a API) markRead(w http.ResponseWriter, r *http.Request) {
	var req markReadRequest
	if r.ContentLength != 0 {
		if err := respond.Decode(w, r, &req); err != nil {
			respond.Error(w, r, err)
			return
		}
	}
	var ids any
	if req.IDs != nil {
		ids = req.IDs
	}
	a.call(w, r, http.StatusOK, "notifications_mark_read", db.Args{"_ids": ids})
}
