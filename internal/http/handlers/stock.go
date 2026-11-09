package handlers

import (
	"encoding/json"
	"net/http"

	"sitetrack/internal/db"
	"sitetrack/internal/http/middleware"
	"sitetrack/internal/http/respond"
)

func (a API) stockRoutes(mux *http.ServeMux, authed middleware.Wrap) {
	mux.Handle("GET /store/stock", authed(a.listCompanyStock))
	mux.Handle("POST /store/stock", authed(a.addStock))
	mux.Handle("PUT /store/stock/{materialID}/reorder-point", authed(a.setReorderPoint))
	mux.Handle("GET /projects/{code}/stock", authed(a.listProjectStock))
}

func stockListArgs(r *http.Request) (db.Args, error) {
	args := db.Args{"_search": queryStr(r, "search"), "_category": queryStr(r, "category")}
	for key, param := range map[string]string{"_limit": "limit", "_offset": "offset"} {
		v, err := queryInt(r, param)
		if err != nil {
			return nil, err
		}
		args[key] = v
	}
	if v := queryStr(r, "sort"); v != nil {
		args["_sort"] = v
	}
	if v := queryStr(r, "dir"); v != nil {
		args["_dir"] = v
	}
	return args, nil
}

func (a API) listCompanyStock(w http.ResponseWriter, r *http.Request) {
	args, err := stockListArgs(r)
	if err != nil {
		respond.Error(w, r, err)
		return
	}
	args["_status"] = queryStr(r, "status")
	a.call(w, r, http.StatusOK, "get_company_stock_list", args)
}

func (a API) listProjectStock(w http.ResponseWriter, r *http.Request) {
	args, err := stockListArgs(r)
	if err != nil {
		respond.Error(w, r, err)
		return
	}
	args["_code"] = r.PathValue("code")
	a.call(w, r, http.StatusOK, "get_project_stock_list", args)
}

type addStockRequest struct {
	MaterialID int64       `json:"material_id"`
	Quantity   json.Number `json:"quantity"`
	Note       *string     `json:"note"`
}

func (a API) addStock(w http.ResponseWriter, r *http.Request) {
	var req addStockRequest
	if err := respond.Decode(w, r, &req); err != nil {
		respond.Error(w, r, err)
		return
	}
	qty, err := numArg(req.Quantity, "quantity")
	if err != nil {
		respond.Error(w, r, err)
		return
	}
	a.call(w, r, http.StatusOK, "stock_add", db.Args{"_material_id": req.MaterialID, "_quantity": qty, "_note": strArg(req.Note)})
}

type reorderPointRequest struct {
	ReorderPoint json.Number `json:"reorder_point"`
}

func (a API) setReorderPoint(w http.ResponseWriter, r *http.Request) {
	id, err := pathInt64(r, "materialID")
	if err != nil {
		respond.Error(w, r, err)
		return
	}
	var req reorderPointRequest
	if err := respond.Decode(w, r, &req); err != nil {
		respond.Error(w, r, err)
		return
	}
	point, err := numArg(req.ReorderPoint, "reorder_point")
	if err != nil {
		respond.Error(w, r, err)
		return
	}
	a.call(w, r, http.StatusOK, "stock_set_reorder_point", db.Args{"_material_id": id, "_reorder_point": point})
}
