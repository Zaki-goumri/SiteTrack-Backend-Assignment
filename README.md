# SiteTrack Backend

Backend API for SiteTrack: construction projects, tasks with dependencies, and materials moving between the company store and project stores.

**Stack:** Go 1.26 (standard library HTTP, `pgx`), PostgreSQL 17, Docker Compose.

**Main idea:** the business rules live in PostgreSQL functions. Go handles HTTP, JWT and input checks, then calls one function per request. Every request is one database call and one transaction.

---

## Run it

```bash
docker compose up
```

This starts three services in order:

1. `postgres`: the database
2. `migrate`: runs once. It creates the schema, views and functions, then exits
3. `api`: listens on http://localhost:8080

No `.env` file is needed. Defaults are in `docker-compose.yml`. Copy `.env.example` to `.env` to change them.

- API docs (Scalar): http://localhost:8080/docs
- Raw OpenAPI spec: http://localhost:8080/openapi.yaml
- Health check: http://localhost:8080/health

### Load data at the brief's size

The database must be empty (fresh after `docker compose up`):

```bash
docker compose run --rm migrate /app/migrate seed
```

This takes about 80 seconds and loads:

| Data | Rows |
|---|---|
| Users | 5,000 |
| Projects | 2,000 (up to 50 members each) |
| Project members | ~53,000 |
| Invitations | ~52,000 |
| Tasks | 500,000 (10 projects have 3,000 each) |
| Task dependencies | ~1,004,000 |
| Materials | 20,000 |
| Deliveries | 400,000 |
| Delivery lines | 3,000,000 |

The data is consistent. Dependencies never form loops and never cross projects, and no started task waits on an unfinished one. Blocked flags, project counts, stock and in-transit amounts all match the deliveries.

Every seeded user has the password `password123`. Useful accounts:

| Email | Role |
|---|---|
| `admin@sitetrack.test` | SuperAdmin (sees all 2,000 projects) |
| `store@sitetrack.test` | Company store manager |
| `user@sitetrack.test` | User, project admin of the 10 largest projects (3,000 tasks each) |

To start again from empty: `docker compose down -v && docker compose up`.

### Shortcuts (optional)

If you have [just](https://github.com/casey/just) installed:

| Command | What it does |
|---|---|
| `just up` / `just down` | Start / stop |
| `just reset` | Stop and delete the database |
| `just seed` | Load the full data set |
| `just logs [service]` | Follow logs |
| `just psql` | Database shell |
| `just migrate` | Re-run migrations, views and functions |
| `just docs` | Open the API docs |

---

## Project layout

```
cmd/api/              API server
cmd/migrate/          Migration runner and seed loader (same Docker image)
internal/config/      Settings from environment variables
internal/auth/        Password hashing (argon2id), JWT, refresh tokens
internal/db/          Connection pool and the one helper that calls SQL functions
internal/apperr/      Maps database errors to HTTP statuses
internal/http/        Router, middleware, handlers (one file per area)
internal/migrate/     Migration runner
db/migrations/        Tables, indexes, triggers (run once, in order)
db/views/             *_bulk views (re-applied on every migrate)
db/functions/         SQL functions, one file per area (re-applied on every migrate)
db/seed/seed.sql      Full-size data set
api/openapi.yaml      API documentation
```

---

## How a request works

```
HTTP request
  → Go: check JWT signature, parse and check input
  → select api.task_start(_sid => $1, _code => $2)
      → app.auth(_sid): is the session still active? who is the user, with what role?
      → access check: member of the project? project admin? store manager?
      → rules, changes, locks, all in one transaction
      → returns JSON built by Postgres
  → Go writes the JSON as it is
```

Errors are raised in SQL with custom codes (`ST404`, `ST409`, ...). Go turns them into HTTP statuses. Every error looks like `{"code": "not_found", "message": "project not found"}`.

---

## Decisions and why

### Business rules in PostgreSQL functions

- **Correct when many requests run at once.** The hard rules are about many people acting at the same moment: stock never negative, no duplicate IDs, no dependency loops, always one project admin. They are enforced where the data and the locks are, inside one transaction.
- **One round trip per request.** A request is one function call, not many small queries, which matters on a small server.
- **The database protects itself.** The API connects as `sitetrack_api`. That user has **no access to any table**. It can only run functions in the `api` schema. A bug in Go cannot read or change data around the rules.
- **Go stays thin.** Most handlers are about 10 lines: read input, call one function, return its JSON.

The cost: the logic is in SQL, which some teams find harder to test and refactor. I kept it organised with one SQL file per area, a small set of helpers (`app.auth`, `app.require_project`, `app.require_task`), and views for read shapes.

### Auth and sessions

- Every login creates a row in `sessions`. The JWT only holds the user id and the session id. **The role is never trusted from the token.**
- Every SQL function starts with `app.auth(_sid)`, a lookup by primary key. Because of this:
  - **Logout works right away.** The session is marked revoked, and the next request with that access token gets `401`.
  - **Removing a member or changing a role applies on the very next request.** Access is always read from the current data.
- Access tokens last 15 minutes and refresh tokens 30 days. Each refresh gives a new refresh token and extends the session, so active users are never asked to log in again.
- **A reused refresh token ends the session.** Refresh tokens are stored as SHA-256 hashes. If an old one is used again more than 10 seconds after it was replaced, it was probably stolen, so the whole session is ended. The 10 seconds allow for a client that sends two refreshes at once.
- **Passwords:** argon2id (19 MB memory, 2 passes). Only a limited number of hashes run at once, so a burst of logins cannot use up the memory of a small server.
- **Failed logins reveal nothing.** A wrong email and a wrong password give the same `401` and take the same time: for an unknown email, a dummy hash is checked.

### Access rules

- If a user cannot see a project, they get **`404 project not found`**, the same as a project that does not exist. The same goes for its tasks, store, deliveries, members and invitations. A project ID that is easy to guess does not leak anything.
- Every list query is filtered by access inside SQL, so counts and searches only include what the user may see.
- A project member who is not an admin gets `403` on admin actions. They already know the project exists.
- A SuperAdmin can do every project admin action on every project.
- **At least one admin:** changing or removing an admin locks the project row first, so two admins cannot demote each other at the same time and leave the project with none.

### IDs

- **Project IDs** come from a one-row counter, updated with `UPDATE ... RETURNING`. That locks the row until the transaction ends, so projects created at the same moment wait in line. No duplicates and no gaps.
- **Task IDs** come from a `next_task_no` column on the project, used the same way. It is per project and never reset.
- Removing a project or task never lowers a counter, so **IDs are never reused**.
- After `PRJ-9999` the number simply grows (`PRJ-10000`) instead of being cut off.
- Inside the database, ids are `bigint`. The `PRJ-...` text is a separate unique column and is the public ID in the API.

### Tasks and dependencies

- **Same project.** A composite foreign key makes the database refuse a dependency between tasks of different projects.
- **No loops.** Before adding a dependency, a recursive query follows the dependencies of `depends_on`. If it reaches the task, the dependency is refused. A project has at most 3,000 tasks, so this stays fast (about 4 ms at full size).
- **Every task change locks the project row**: status changes, adding and removing dependencies, deleting tasks. Two changes in the same project then run one after the other. This stops two requests from creating a loop together, or starting a task while the task it waits on is being reopened. The cost is that writes inside one project don't run in parallel. That is fine for one site's task list.
- **Start and Reopen only check direct links.** This is enough because of three rules together:
  - A task can only start when everything it waits on is done.
  - A done task cannot reopen once a task waiting on it has started.
  - Dependencies cannot be added to a task that has already started.

  So a started task can never have an unfinished task anywhere in its chain.
- **Blocked is stored.** It is recalculated in the same transaction after Done, Reopen, adding or removing a dependency, and deleting a task, with one recursive query over the project. Because it is stored, lists can filter, count and sort by it quickly. Recalculating only the affected tasks would be faster in theory, but harder to get right for little gain at 3,000 tasks.
- **Late is calculated, never stored.** A generated column `late_from` holds the date after which the task is late: the planned start while not started, the planned end while in progress, empty when done. A task is late when `late_from < today`. It always reflects today's date with no background job, and a partial index makes late counts per project fast.
- **"Waits on" lists.** The task details screen lists every task a task waits on, and every task that waits on it, with the fewest steps to each. This is built level by level in a plpgsql loop that visits each task once. A plain recursive query can blow up in size when several paths lead to the same task.

### Materials and deliveries

- **Stock never goes negative**, even with many senders at once. Three layers make sure of it:
  1. The stock rows are locked, always in the same order (company store first, then by material id), so two deliveries cannot get stuck waiting on each other.
  2. The subtraction only applies where enough stock remains: `UPDATE ... SET quantity = quantity - x WHERE quantity >= x`. If any line has too little, the whole delivery is refused (`409 not enough stock of <material>`).
  3. `CHECK (quantity >= 0)` on the table is the final guard.

  Tested: 20 deliveries sent at the same moment against stock for 14. Exactly 14 succeeded, and the stock ended at exactly 0.
- **All or nothing.** Adding stock, sending, recording, rejecting and cancelling are each one function, so each happens completely or not at all.
- **In transit** is a column on the sender's stock row, updated in the same transaction. The company stock screen reads it directly.
- **Every material has a company stock row**, created with the material, so "every material" on the company stock screen is a simple read.
- **Stock status** (`out_of_stock`, `low_stock`, `available`) is a generated column, so it can be filtered and indexed.
- **Quantities are `numeric(14,3)`**, so units like tons work. Go passes them to Postgres as exact decimal values, never as floats.
- **Safe retries.** Sending a delivery accepts an `Idempotency-Key` header. A retry with the same key returns the first delivery instead of creating a second one.
- **Deliveries cannot be edited.** There is no update endpoint. Only record, reject and cancel change them.

### Views (`*_bulk`)

- Each view keeps the base row as a `jsonb` column and puts only the fields used for filtering and sorting in their own columns. Related data (project, users, counts) is added on top.
- **Plain views, no materialized views.** A materialized view is a saved copy that goes out of date. Late and Blocked must always be current.
- **List functions build JSON only for the rows they return.** They filter and sort on narrow columns, pick the keys for the page, then join back to the view for those rows. This one change took the SuperAdmin projects list from 118 ms to 20 ms.
- Counts that are only sometimes needed (late tasks per project, dependents per task) are subqueries inside the view, so Postgres only runs them when a query uses them.

### Paging

- **Lists the brief caps** use `limit` + `offset` and return `total`: projects (≤2,000), tasks (≤3,000 per project), stock (≤20,000) and materials. A user can jump to any page, and the cost is bounded.
- **Long lists** use a cursor: deliveries (400k) and notifications. Pages stay fast no matter how deep you go, and new rows don't shift the pages.
- **The deliveries list and the company stock list build their SQL from only the filters actually used.** With fixed SQL full of `(param is null or ...)` checks, Postgres can pick one plan that is bad for some filter combinations. Small lists keep fixed SQL, because that problem doesn't matter at their size.

### Migrations

I wrote a small migration runner (`cmd/migrate`) instead of using an extra tool:

- **Migrations** (`db/migrations`) run once each, in order, inside a transaction, and are recorded in `schema_migrations`.
- **Views and functions** (`db/views`, `db/functions`) are re-applied on every run with `CREATE OR REPLACE`, so changing a function is just editing its file.
- An advisory lock stops two runners from working at once.
- It creates the API's database user and gives it permission to run `api.*` functions only.
- All SQL files are built into the binary, so the Docker image needs nothing else.

### Performance at full size

Measured with the seeded data, on the same Postgres settings as `docker-compose.yml`, through the API (best of 3):

| Screen | Time |
|---|---|
| Projects (SuperAdmin, all 2,000; any sort or filter) | 20–56 ms |
| Project tasks (3,000 tasks; any sort or filter) | 16–35 ms |
| Task details (full chain both ways) | 7–48 ms |
| Company stock (20,000 materials) | 20–53 ms |
| Company deliveries (400,000) | 25–51 ms |
| Project deliveries, project store, members, notifications | 2–26 ms |
| Done / reopen in a 3,000-task project (recalculates Blocked) | ~60 ms |
| Add a dependency (worst-case loop check) | ~4–70 ms |
| Send / record a delivery | ~15 ms |
| Log in (argon2id) | ~60 ms |

**Postgres needs more shared memory than Docker gives by default.** Docker gives containers only 64 MB of shared memory, and parallel queries on these table sizes ran out of it (`could not resize shared memory segment`). `docker-compose.yml` sets `shm_size: 256mb`.

---

## Trade-offs I accepted

| Choice | Benefit | Cost |
|---|---|---|
| Rules in SQL functions | Correct when requests run at once, one round trip, database guards itself | Logic is less familiar to Go-only developers; harder to unit test |
| Lock the project row on every task change | No loops or broken status rules from requests that race | No parallel writes inside one project |
| Recalculate Blocked for the whole project | Simple and always correct | More work than needed per change (still about 60 ms at 3,000 tasks) |
| Session lookup on every request | Instant logout and role changes | One extra primary-key read per request (it runs inside the same database call) |
| Offset paging for capped lists | Jump to any page, show totals | Deep pages are slower (last page of company stock: about 70 ms) |
| Register accepts any app role, including SuperAdmin | Matches the brief ("chosen when registering") | Anyone can register as SuperAdmin. In real life only an admin would grant roles |
| Register returns `409` for an email already in use | Clear message for the user | Shows whether an email is registered (the brief only requires login to hide this) |
| Soft delete for projects and materials | History stays and IDs are never reused | Deleted rows stay in the tables |
| Project delete refused while its store holds stock or a delivery is in transit | Material is never lost | The team must send materials back first |
| Dependencies only added to tasks that have not started | Keeps the status rules simple and always true | A forgotten dependency cannot be added once work has begun |

## Choices the brief left open

- Who edits or deletes a project: project admins (and SuperAdmins).
- Who creates, edits and deletes materials: store managers and SuperAdmins. Everyone logged in can read them.
- A material's unit cannot change once it has stock or deliveries.
- Withdrawn invitations disappear from the invited user's notifications. Deleting a project withdraws its pending invitations.
- Notifications are marked read with `POST /notifications/read`. Answering an invitation also marks it read.
- `GET /users?search=` lets admins find people to invite.
- Deleting a task removes its dependency links and recalculates Blocked for the tasks that waited on it.

---

## What I would add with more time

- **Automated tests.** Integration tests against a real Postgres (Testcontainers) for the rules that matter most when requests run at once: parallel deliveries, parallel project and task creation, loops added at the same moment, non-members getting `404`, logout ending the session. I checked all of these by hand with scripts during development, but they belong in CI.
- **Rate limiting** on login and register.
- **Admin-only role changes** instead of choosing the role at registration.
- **History tables** for stock movements and task status changes, for audit and reports.
- **Recalculate Blocked only for affected tasks** if projects grow far beyond 3,000 tasks.
- **Partition `deliveries` and `delivery_lines` by month** once they grow into tens of millions of rows.
- **Metrics and tracing** (Prometheus, OpenTelemetry), and SQL timings in the request logs.
- **A dedicated database owner role** for the functions, instead of the admin user that runs migrations.
- **Pin the Scalar version** on the docs page, or serve it from the binary so `/docs` works offline.
