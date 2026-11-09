package handlers

import (
	"encoding/json"
	"net/http"
	"strings"

	"sitetrack/internal/apperr"
	"sitetrack/internal/db"
	"sitetrack/internal/http/middleware"
	"sitetrack/internal/http/respond"
)

func (a API) deliveryRoutes(mux *http.ServeMux, authed middleware.Wrap) {
	mux.Handle("GET /store/deliveries", authed(a.listDeliveries(false)))
	mux.Handle("POST /store/deliveries", authed(a.sendToProject))
	mux.Handle("GET /projects/{code}/deliveries", authed(a.listDeliveries(true)))
	mux.Handle("POST /projects/{code}/deliveries", authed(a.sendToCompany))
	mux.Handle("GET /deliveries/{id}", authed(a.getDelivery))
	mux.Handle("POST /deliveries/{id}/record", authed(a.closeDelivery("record")))
	mux.Handle("POST /deliveries/{id}/reject", authed(a.closeDelivery("reject")))
	mux.Handle("POST /deliveries/{id}/cancel", authed(a.closeDelivery("cancel")))
}

func (a API) listDeliveries(projectScope bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		args := db.Args{"_direction": queryStr(r, "direction"), "_status": queryStr(r, "status")}
		if projectScope {
			args["_code"] = r.PathValue("code")
		} else {
			args["_project"] = queryStr(r, "project")
		}
		for key, param := range map[string]string{"_from": "from", "_to": "to"} {
			v, err := queryDate(r, param)
			if err != nil {
				respond.Error(w, r, err)
				return
			}
			args[key] = v
		}
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
		args["_limit"] = limit
		args["_cursor"] = cursor
		a.call(w, r, http.StatusOK, "get_deliveries_list", args)
	}
}

type deliveryLine struct {
	MaterialID int64       `json:"material_id"`
	Quantity   json.Number `json:"quantity"`
}

type deliveryRequest struct {
	Project *string        `json:"project"`
	Lines   []deliveryLine `json:"lines"`
	Note    *string        `json:"note"`
}

func (a API) sendToProject(w http.ResponseWriter, r *http.Request) {
	req, args, err := deliveryArgs(w, r)
	if err != nil {
		respond.Error(w, r, err)
		return
	}
	if req.Project == nil || strings.TrimSpace(*req.Project) == "" {
		respond.Error(w, r, apperr.New(http.StatusUnprocessableEntity, "project is required"))
		return
	}
	args["_code"] = strings.TrimSpace(*req.Project)
	a.call(w, r, http.StatusCreated, "delivery_send_to_project", args)
}

func (a API) sendToCompany(w http.ResponseWriter, r *http.Request) {
	_, args, err := deliveryArgs(w, r)
	if err != nil {
		respond.Error(w, r, err)
		return
	}
	args["_code"] = r.PathValue("code")
	a.call(w, r, http.StatusCreated, "delivery_send_to_company", args)
}

func deliveryArgs(w http.ResponseWriter, r *http.Request) (deliveryRequest, db.Args, error) {
	var req deliveryRequest
	if err := respond.Decode(w, r, &req); err != nil {
		return req, nil, err
	}
	if req.Note != nil && len(*req.Note) > 1000 {
		return req, nil, apperr.New(http.StatusUnprocessableEntity, "note must be at most 1000 characters")
	}
	key := strings.TrimSpace(r.Header.Get("Idempotency-Key"))
	if len(key) > 100 {
		return req, nil, apperr.BadRequest("Idempotency-Key must be at most 100 characters")
	}
	if req.Lines == nil {
		req.Lines = []deliveryLine{}
	}
	lines, err := json.Marshal(req.Lines)
	if err != nil {
		return req, nil, err
	}
	var keyArg any
	if key != "" {
		keyArg = key
	}
	return req, db.Args{"_lines": json.RawMessage(lines), "_note": strArg(req.Note), "_key": keyArg}, nil
}

func (a API) getDelivery(w http.ResponseWriter, r *http.Request) {
	id, err := pathInt64(r, "id")
	if err != nil {
		respond.Error(w, r, err)
		return
	}
	a.call(w, r, http.StatusOK, "delivery_get", db.Args{"_delivery_id": id})
}

func (a API) closeDelivery(action string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id, err := pathInt64(r, "id")
		if err != nil {
			respond.Error(w, r, err)
			return
		}
		a.call(w, r, http.StatusOK, "delivery_close", db.Args{"_delivery_id": id, "_action": action})
	}
}
