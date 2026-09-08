# Oracle -> Databricks SQL conversion guide

The Oracle originals are preserved untouched in `db_oracle_original_backup/`
one level up from this folder. Every file in `db/` now has the same name and
same run order as before — only the content changed. To reconvert (go back
to Oracle, or re-derive the mapping), diff each file here against its match
in `db_oracle_original_backup/`; the rules below explain every diff you'll see.

## Run order (unchanged)

`01_schema.sql` -> `02_views.sql` -> `03_packages.sql` -> `04_triggers_scheduler.sql` -> `05_seed_data.sql`

## Type mapping (01_schema.sql)

| Oracle | Databricks SQL | Rule |
|---|---|---|
| `VARCHAR2(n)`, `CHAR(n)` | `STRING` | Databricks doesn't enforce length |
| `NUMBER(p)`, p <= 9 | `INT` | fits in 32-bit |
| `NUMBER(p)`, p >= 10 | `BIGINT` | needs 64-bit |
| `NUMBER(p,s)` | `DECIMAL(p,s)` | direct equivalent |
| `GENERATED ALWAYS AS IDENTITY` | unchanged | Delta supports this natively, no extra table property needed |
| `SYSTIMESTAMP` | `current_timestamp()` | |
| any column `DEFAULT ...` | same `DEFAULT` clause, **plus** `TBLPROPERTIES ('delta.feature.allowColumnDefaults' = 'supported')` on the `CREATE TABLE` | Unlike Oracle, Delta gates column defaults behind an explicit, per-table opt-in "table feature". Omitting it fails with `WRONG_COLUMN_DEFAULTS_FOR_DELTA_FEATURE_NOT_ENABLED` — every table here has this property set, whether or not it currently uses `DEFAULT`, so adding a default later never re-triggers the error |
| inline `CHECK (...)` | `ALTER TABLE ... ADD CONSTRAINT ... CHECK (...)` right after the `CREATE TABLE` | Databricks doesn't allow inline CHECK in the column list |
| `PRIMARY KEY` / `FOREIGN KEY ... REFERENCES` | unchanged, still inline | Unity Catalog constraints, but **informational only** (not enforced) |
| `CONSTRAINT ... UNIQUE (...)` | dropped, noted in a comment | Databricks/Delta has no UNIQUE constraint type — uniqueness is enforced by the `MERGE` statements in `03_packages.sql` instead |
| `CREATE INDEX ...` | `CLUSTER BY (...)` on the `CREATE TABLE` | Delta has no user-managed indexes; liquid clustering is the closest equivalent |
| `COMMIT;` | removed | Databricks SQL autocommits every statement |

## Query/DML mapping (02_views.sql, 03_packages.sql, 05_seed_data.sql)

| Oracle | Databricks SQL | Notes |
|---|---|---|
| `TRUNC(ts, 'HH24')` | `date_trunc('HOUR', ts)` | Oracle's format-string TRUNC has no 1:1 Databricks equivalent; `date_trunc` is the closest |
| `NVL(a, b)` | unchanged | Databricks SQL has a built-in `nvl()` too |
| `INTERVAL '72' HOUR` | unchanged | same ANSI interval literal syntax works |
| `ROWNUM = 1` in a subquery | `ORDER BY ... LIMIT 1` | |
| `DUAL` | not needed | `SELECT ... FROM (subquery)` needs no `FROM DUAL` filler |
| `MERGE INTO ... WHEN MATCHED / WHEN NOT MATCHED` | unchanged | Delta's MERGE syntax is almost identical to Oracle's |
| `DBMS_RANDOM.VALUE(a, b)` | `a + rand() * (b - a)` | |
| `q'[...]'` quoting | not needed | Databricks doesn't need Oracle's alternate quote syntax |

## Procedural logic mapping (03_packages.sql)

Oracle PL/SQL packages have no Databricks SQL equivalent, so each construct
became one of two things:

- **Pure/deterministic functions** (`rule_based_qoe`, `qoe_band`,
  `customer_impact_score`, `technical_severity_score`) -> Databricks SQL
  scalar functions: `CREATE OR REPLACE FUNCTION ... RETURNS <type>
  DETERMINISTIC RETURN <expression>`. Called exactly like the Oracle
  `pkg_x.function_name(...)` calls, minus the package prefix.
- **Procedures with side effects** (`build_call_volume_hourly`,
  `score_site_qoe_rule_based`, `flag_churn_risk`, `build_triage_queue`) ->
  plain SQL scripts. Oracle's `IN` parameters became Databricks SQL session
  variables: `DECLARE OR REPLACE VARIABLE v_name TYPE DEFAULT <value>;`
  To call one with specific arguments, run
  `SET VARIABLE v_name = <value>, v_other = <value>;` before the script's
  statements — same idea as an Oracle parameter with a default that the
  caller can override.

Other procedural constructs:

| Oracle construct | Databricks replacement |
|---|---|
| `SELECT ... WHERE ROWNUM = 1` (latest-row pick) | `ORDER BY ... DESC LIMIT 1` |
| `EXCEPTION WHEN NO_DATA_FOUND THEN NULL` | not needed — an empty source in a `MERGE` simply does nothing |
| `FOR s IN (SELECT site_id FROM site) LOOP ... END LOOP` (loop over all sites) | rewritten as one set-based `MERGE`/`UPDATE` using `ROW_NUMBER() OVER (PARTITION BY site_id ...)` instead of looping — see the "ALL SITES" block in `03_packages.sql` SECTION 2 |
| `FOR r IN (SELECT DISTINCT site_id ...) LOOP flag_churn_risk(r.site_id); END LOOP` | one set-based `UPDATE`, instead of calling the single-site procedure once per row — see the closing `UPDATE` in `build_triage_queue` |
| the churn-check condition itself (`COUNT(*) FROM (...) >= n` as a scalar subquery correlated to the row being updated) | rewritten as a `CREATE OR REPLACE TEMPORARY VIEW` that computes the eligible `site_id`s first (via `ROW_NUMBER()`/`GROUP BY ... HAVING`), followed by a plain `UPDATE ... WHERE home_site_id IN (SELECT site_id FROM that_view)` | A correlated subquery nested several levels deep inside an `UPDATE`'s `WHERE` clause is exactly the kind of construct that varies most between SQL engines. Splitting it into "compute eligible sites" then "update where site is in that set" is provably correct set logic, and each half can be run and inspected on its own (`SELECT * FROM _churn_check_...`) if something looks wrong |
| `COMPOUND TRIGGER` (`trg_qoe_churn_check`) | Databricks has no DML triggers at all. The churn-check logic is folded directly into `score_site_qoe_rule_based` (both single-site and all-sites versions) in `03_packages.sql`, right after the `MERGE INTO qoe_score` — it now runs automatically every time that script runs, same as the trigger used to fire on every `INSERT` |
| `DBMS_SCHEDULER.CREATE_JOB` (`04_triggers_scheduler.sql`) | No SQL equivalent. Recreated as two real Databricks Jobs by `create_scheduled_jobs.py` (Databricks SDK, version-controlled), with a manual SQL-Editor-only fallback documented inside `04_triggers_scheduler.sql` for a quick one-off check |

## Seed data (05_seed_data.sql)

Oracle generated ~400 subscribers and 10 days of hourly data with PL/SQL
`FOR` loops + `DBMS_RANDOM`, row by row. Databricks SQL has no such loop, so
this is rewritten as set-based generation:

| Oracle construct | Databricks replacement |
|---|---|
| `FOR i IN 1..400 LOOP` | `explode(sequence(1, 400))` |
| `FOR c IN 1..v_call_count LOOP` (variable-length inner loop) | `LATERAL VIEW explode(sequence(1, call_count))` per outer row |
| a single random value reused across several `IF`/`CASE` branches | computed once into its own column in an intermediate `TEMPORARY VIEW`, then referenced (not re-rolled) in later `CASE` expressions — needed because every `rand()` call produces an independent value, unlike a PL/SQL variable |
| `BULK COLLECT INTO` an array, then random-index into it | `collect_list(...)` to build the array once, `element_at(arr, CAST(FLOOR(rand()*n) AS INT)+1)` to pick a random element per row |
| a random value needed in two output columns that must agree with each other (e.g. `closed_ts` = `opened_ts` + a random resolution time) | computed once as a named column of an intermediate `TEMPORARY VIEW`, then both output columns reference that view's column — **not** `CROSS JOIN LATERAL (SELECT rand() ...)`. A SQL `SELECT` list can't reference one of its own aliases from another expression in the same list (unlike a PL/SQL variable), and `LATERAL` join support varies enough between engines that it's safer to avoid; a plain view is unambiguous everywhere |

**This is not a row-for-row port.** The random values and exact row counts
will differ from an Oracle run of the same script — but the same sites, the
same 3-day incident window on the same 2 sites, and the same statistical
shape (busy-hour multiplier, elevated failure rates during the incident,
depressed CSAT/NPS afterward) are preserved.

## Re-running these scripts

Oracle originals were mostly run once against a persistent schema; these
Databricks scripts are written so the whole `01` -> `05` sequence can be
re-run from scratch (e.g. to reset a demo workspace) without manual cleanup:

| File | How it's made re-runnable |
|---|---|
| `01_schema.sql` | `DROP TABLE IF EXISTS` for every table, children before parents (Unity Catalog FK dependency tracking blocks dropping a table still referenced by another table's FK), right before the `CREATE TABLE` statements |
| `02_views.sql` | `CREATE OR REPLACE VIEW` — no change needed |
| `03_packages.sql` | `CREATE OR REPLACE FUNCTION`/`TEMPORARY VIEW`, `DECLARE OR REPLACE VARIABLE`, and `MERGE`/`DELETE`-then-`INSERT` for anything with side effects — no change needed |
| `04_triggers_scheduler.sql` | comments only, nothing to run |
| `05_seed_data.sql` | plain `INSERT`s would duplicate rows (and layer a second, differently-dated incident window) on a second run, so `DELETE FROM` clears every seeded table, children before parents, before the inserts |
| `create_scheduled_jobs.py` | looks up each job by name and calls `w.jobs.reset(...)` instead of `w.jobs.create(...)` if it already exists |

## What still needs a value filled in

- `01_schema.sql`: run `USE CATALOG <catalog>; USE SCHEMA <schema>;` once
  before the rest of the scripts (table/view/function names are left
  unqualified so they match the Oracle names exactly).
- `create_scheduled_jobs.py`: set `DATABRICKS_SQL_WAREHOUSE_ID` (and a
  Databricks auth profile/token) before running it — see its docstring.
