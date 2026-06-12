# Deadlock Migration — Simulation

This project reproduces a PostgreSQL deadlock that can occur when a migration
adding a foreign key runs concurrently with web traffic during a Kubernetes rolling update.

---

## The Theory

### What happens during a rolling update

During a rolling update, two pods run simultaneously:
- **Pod A (old code)**: already serving HTTP requests, no new migration to run
- **Pod B (new code)**: init container runs `rails db:migrate`, finds a pending FK migration

The migration adds a FK from a child table to a parent table.

At the same time, Pod A handles a web request that writes to **both tables** inside a
transaction — but in the **opposite lock-acquisition order** from the migration.

### Lock acquisition order

```
Migration (process A):                    Web request on Pod A (process B):

1. Acquires SHARE ROW EXCLUSIVE           1. Acquires ROW EXCLUSIVE
   on tickets (child table) ✅               on teams (parent table) ✅
   (altering the table structure)            (INSERT into teams)

2. Tries SHARE ROW EXCLUSIVE              2. Tries ROW EXCLUSIVE
   on teams (parent table)...                on tickets (child table)...
   --> BLOCKED by process B                   --> BLOCKED by process A
       (ROW EXCLUSIVE conflicts                   (SHARE ROW EXCLUSIVE conflicts
        with SHARE ROW EXCLUSIVE)                  with ROW EXCLUSIVE)
```

### The deadlock cycle

```
process A ──── holds ──── tickets ──── blocks ──── process B
    |                                                   |
 blocks                                              holds
    |                                                   |
process B ──── wants ──── teams ──── held by ───── process A
```

Each process holds the lock the other needs. PostgreSQL detects the cycle and
kills the migration as the victim (`PG::TRDeadlockDetected`).

### Why the migration leaves the DB in a partial state

The migration uses `disable_ddl_transaction!`, which means each DDL statement is
auto-committed immediately with no wrapping transaction. When the deadlock kills
the process mid-migration, any `add_column` calls that already ran are permanently
committed to the database.

Since Rails only records a migration in `schema_migrations` after the entire `up`
method completes, the migration is **not recorded as done**. On the next boot,
Rails tries to run it again — but the columns already exist — causing
`PG::DuplicateColumn` on every subsequent init container attempt.

Key operations:
- `INSERT / UPDATE / DELETE` → **ROW EXCLUSIVE**
- `ADD FOREIGN KEY` → **SHARE ROW EXCLUSIVE** on child + **ROW SHARE** on parent
- `ADD COLUMN` → **ACCESS EXCLUSIVE** (blocks everything)

---

## How to reproduce locally

### 1. Start PostgreSQL

```bash
docker compose up -d
```

### 2. Install dependencies and set up the database

Run only the first two migrations (tables without the FK constraint):

```bash
bundle install
bundle exec rails db:create db:migrate VERSION=20240101000002
```

### 3. Start the Rails server

```bash
bundle exec rails server -p 3000
```

### 4. Trigger the simulation request

In a separate terminal:

```bash
curl -X POST http://localhost:3000/simulate
```

The controller opens a transaction, INSERTs into `teams` (acquires ROW EXCLUSIVE on teams),
then sleeps 15 seconds. You will see in the Rails log:

```
[SIMULATE] Team created (id=1). Sleeping 15s — run the FK migration now!
```

### 5. Run the FK migration while the request sleeps

In another terminal, **within the 15-second window**:

```bash
bundle exec rails db:migrate
```

The migration will:
1. Acquire `SHARE ROW EXCLUSIVE` on `tickets` ✅
2. Try `SHARE ROW EXCLUSIVE` on `teams` → **BLOCKED** (transaction holds ROW EXCLUSIVE on teams)

### 6. Watch the deadlock

When the 15 seconds are up, the transaction wakes and tries `ROW EXCLUSIVE` on `tickets` →
**BLOCKED** by the migration's `SHARE ROW EXCLUSIVE` on `tickets`.

PostgreSQL detects the cycle and kills one of the processes. The endpoint returns:

```json
{ "error": "deadlock_detected", "message": "..." }
```

The Rails log will show:

```
[SIMULATE] DEADLOCK DETECTED: PG::TRDeadlockDetected: ERROR: deadlock detected
DETAIL: Process X waits for ShareRowExclusiveLock on relation ...; blocked by process Y.
        Process Y waits for RowExclusiveLock on relation ...; blocked by process X.
```