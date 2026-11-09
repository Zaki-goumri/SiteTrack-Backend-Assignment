package db

import (
	"context"
	"encoding/json"
	"fmt"
	"regexp"
	"sort"
	"strings"

	"sitetrack/internal/apperr"
)

type Args map[string]any

var ident = regexp.MustCompile(`^[a-z_][a-z0-9_]*$`)

func (d *DB) Call(ctx context.Context, fn string, args Args) (json.RawMessage, error) {
	query, values, err := buildCall(fn, args)
	if err != nil {
		return nil, err
	}
	var out []byte
	if err := d.Pool.QueryRow(ctx, query, values...).Scan(&out); err != nil {
		return nil, apperr.FromDB(err)
	}
	if out == nil {
		return json.RawMessage("null"), nil
	}
	return json.RawMessage(out), nil
}

func buildCall(fn string, args Args) (string, []any, error) {
	if !ident.MatchString(fn) {
		return "", nil, fmt.Errorf("db: invalid function name %q", fn)
	}
	names := make([]string, 0, len(args))
	for name := range args {
		if !ident.MatchString(name) {
			return "", nil, fmt.Errorf("db: invalid argument name %q", name)
		}
		names = append(names, name)
	}
	sort.Strings(names)

	var b strings.Builder
	b.WriteString("select api.")
	b.WriteString(fn)
	b.WriteByte('(')
	values := make([]any, len(names))
	for i, name := range names {
		if i > 0 {
			b.WriteString(", ")
		}
		fmt.Fprintf(&b, "%s => $%d", name, i+1)
		values[i] = args[name]
	}
	b.WriteString(")::text")
	return b.String(), values, nil
}
