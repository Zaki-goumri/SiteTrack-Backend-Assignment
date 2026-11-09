package migrate

import (
	"context"
	"fmt"
	"io/fs"
	"log/slog"
	"sort"
	"strings"

	"github.com/jackc/pgx/v5"
)

const lockKey = 7_420_001

type Runner struct {
	Conn          *pgx.Conn
	Files         fs.FS
	APIDBUser     string
	APIDBPassword string
}

func (r Runner) Up(ctx context.Context) error {
	if _, err := r.Conn.Exec(ctx, "select pg_advisory_lock($1)", lockKey); err != nil {
		return fmt.Errorf("take migration lock: %w", err)
	}
	defer r.Conn.Exec(context.Background(), "select pg_advisory_unlock($1)", lockKey)

	steps := []func(context.Context) error{r.ensureAPIRole, r.applyMigrations, r.applyDir("views"), r.applyDir("functions"), r.grantAPIRole}
	for _, step := range steps {
		if err := step(ctx); err != nil {
			return err
		}
	}
	return nil
}

func (r Runner) Seed(ctx context.Context) error {
	sql, err := fs.ReadFile(r.Files, "seed/seed.sql")
	if err != nil {
		return err
	}
	if strings.TrimSpace(string(sql)) == "" {
		return fmt.Errorf("seed/seed.sql is empty")
	}
	slog.Info("seeding")
	_, err = r.Conn.Exec(ctx, string(sql))
	return err
}

func (r Runner) ensureAPIRole(ctx context.Context) error {
	var exists bool
	if err := r.Conn.QueryRow(ctx, "select exists(select 1 from pg_roles where rolname = $1)", r.APIDBUser).Scan(&exists); err != nil {
		return err
	}
	verb := "create"
	if exists {
		verb = "alter"
	}
	var stmt string
	if err := r.Conn.QueryRow(ctx, "select format('"+verb+" role %I with login password %L', $1::text, $2::text)", r.APIDBUser, r.APIDBPassword).Scan(&stmt); err != nil {
		return err
	}
	_, err := r.Conn.Exec(ctx, stmt)
	return err
}

func (r Runner) applyMigrations(ctx context.Context) error {
	if _, err := r.Conn.Exec(ctx, "create table if not exists public.schema_migrations (version text primary key, applied_at timestamptz not null default now())"); err != nil {
		return err
	}
	names, err := sqlFiles(r.Files, "migrations")
	if err != nil {
		return err
	}
	for _, name := range names {
		var done bool
		if err := r.Conn.QueryRow(ctx, "select exists(select 1 from public.schema_migrations where version = $1)", name).Scan(&done); err != nil {
			return err
		}
		if done {
			continue
		}
		sql, err := fs.ReadFile(r.Files, "migrations/"+name)
		if err != nil {
			return err
		}
		if strings.TrimSpace(string(sql)) == "" {
			continue
		}
		err = pgx.BeginFunc(ctx, r.Conn, func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, string(sql)); err != nil {
				return err
			}
			_, err := tx.Exec(ctx, "insert into public.schema_migrations (version) values ($1)", name)
			return err
		})
		if err != nil {
			return fmt.Errorf("migration %s: %w", name, err)
		}
		slog.Info("migration applied", "file", name)
	}
	return nil
}

func (r Runner) applyDir(dir string) func(context.Context) error {
	return func(ctx context.Context) error {
		names, err := sqlFiles(r.Files, dir)
		if err != nil {
			return err
		}
		return pgx.BeginFunc(ctx, r.Conn, func(tx pgx.Tx) error {
			for _, name := range names {
				sql, err := fs.ReadFile(r.Files, dir+"/"+name)
				if err != nil {
					return err
				}
				if strings.TrimSpace(string(sql)) == "" {
					continue
				}
				if _, err := tx.Exec(ctx, string(sql)); err != nil {
					return fmt.Errorf("%s/%s: %w", dir, name, err)
				}
			}
			slog.Info("sql applied", "dir", dir, "files", len(names))
			return nil
		})
	}
}

func (r Runner) grantAPIRole(ctx context.Context) error {
	var stmt string
	err := r.Conn.QueryRow(ctx, `select format(
		'revoke all on all tables in schema app from %1$I;
		 revoke all on schema app from %1$I;
		 grant usage on schema api to %1$I;
		 grant execute on all functions in schema api to %1$I;', $1::text)`, r.APIDBUser).Scan(&stmt)
	if err != nil {
		return err
	}
	_, err = r.Conn.Exec(ctx, stmt)
	return err
}

func sqlFiles(files fs.FS, dir string) ([]string, error) {
	entries, err := fs.ReadDir(files, dir)
	if err != nil {
		return nil, err
	}
	var names []string
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".sql") {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names)
	return names, nil
}
