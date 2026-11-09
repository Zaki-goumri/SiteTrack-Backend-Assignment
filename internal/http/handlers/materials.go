package handlers

import (
	"net/http"

	"sitetrack/internal/db"
	"sitetrack/internal/http/middleware"
	"sitetrack/internal/http/respond"
)

func (a API) materialRoutes(mux *http.ServeMux, authed middleware.Wrap) {
	mux.Handle("GET /materials", authed(a.listMaterials))
	mux.Handle("GET /materials/categories", authed(a.materialCategories))
	mux.Handle("POST /materials", authed(a.createMaterial))
	mux.Handle("GET /materials/{id}", authed(a.getMaterial))
	mux.Handle("PATCH /materials/{id}", authed(a.updateMaterial))
	mux.Handle("DELETE /materials/{id}", authed(a.deleteMaterial))
}

func (a API) listMaterials(w http.ResponseWriter, r *http.Request) {
	args := db.Args{"_search": queryStr(r, "search"), "_category": queryStr(r, "category")}
	for key, param := range map[string]string{"_limit": "limit", "_offset": "offset"} {
		v, err := queryInt(r, param)
		if err != nil {
			respond.Error(w, r, err)
			return
		}
		args[key] = v
	}
	a.call(w, r, http.StatusOK, "get_materials_list", args)
}

func (a API) materialCategories(w http.ResponseWriter, r *http.Request) {
	a.call(w, r, http.StatusOK, "get_material_categories", db.Args{})
}

type materialRequest struct {
	Name     *string `json:"name"`
	Category *string `json:"category"`
	Unit     *string `json:"unit"`
}

func (req materialRequest) check(required bool) error {
	if err := checkText(req.Name, "name", required, 200); err != nil {
		return err
	}
	if err := checkText(req.Category, "category", required, 100); err != nil {
		return err
	}
	return checkText(req.Unit, "unit", required, 30)
}

func (a API) createMaterial(w http.ResponseWriter, r *http.Request) {
	var req materialRequest
	if err := respond.Decode(w, r, &req); err != nil {
		respond.Error(w, r, err)
		return
	}
	if err := req.check(true); err != nil {
		respond.Error(w, r, err)
		return
	}
	a.call(w, r, http.StatusCreated, "material_create", db.Args{"_name": strArg(req.Name), "_category": strArg(req.Category), "_unit": strArg(req.Unit)})
}

func (a API) getMaterial(w http.ResponseWriter, r *http.Request) {
	id, err := pathInt64(r, "id")
	if err != nil {
		respond.Error(w, r, err)
		return
	}
	a.call(w, r, http.StatusOK, "material_get", db.Args{"_material_id": id})
}

func (a API) updateMaterial(w http.ResponseWriter, r *http.Request) {
	id, err := pathInt64(r, "id")
	if err != nil {
		respond.Error(w, r, err)
		return
	}
	var req materialRequest
	if err := respond.Decode(w, r, &req); err != nil {
		respond.Error(w, r, err)
		return
	}
	if err := req.check(false); err != nil {
		respond.Error(w, r, err)
		return
	}
	a.call(w, r, http.StatusOK, "material_update", db.Args{"_material_id": id, "_name": strArg(req.Name), "_category": strArg(req.Category), "_unit": strArg(req.Unit)})
}

func (a API) deleteMaterial(w http.ResponseWriter, r *http.Request) {
	id, err := pathInt64(r, "id")
	if err != nil {
		respond.Error(w, r, err)
		return
	}
	a.call(w, r, http.StatusNoContent, "material_delete", db.Args{"_material_id": id})
}
