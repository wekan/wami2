# WeKan-Lite — schema decision: `schema.sql` vs `../kanboard/` vs `../minio-metadata/` — v0.1

Companion to `contract.md`, `schema.sql`, and `web-stack-decision.md`. This doc decides
**which schema WeKan-Lite is built on**, and how the two *source* datasets in this
directory map into it. The driving use case: **import Kanboard data (the BigBoard
instance and any other Kanboard SQLite database) into WeKan-Lite**, alongside data
migrated from existing Meteor WeKan (MongoDB).

---

## The three artifacts and their roles

| Path | What it is | Role in WeKan-Lite |
|------|-----------|--------------------|
| **`schema.sql`** | The WeKan-Lite native SQLite DDL (24 tables), derived from Meteor WeKan's `SimpleSchema` definitions. TEXT Mongo-style IDs, ISO-8601 TEXT dates, child tables for nested arrays, JSON blobs for sparse data. | **Destination / canonical schema.** Everything imports *into* this. |
| **`../kanboard/`** | A full checkout of the Kanboard PHP app. The schema that matters is `app/Schema/Sqlite.php` — 128 sequential migrations that build Kanboard's own SQLite DB (`db.sqlite`): INTEGER autoincrement PKs, epoch-INTEGER dates, a `projects → columns → tasks` model. | **Import source #1.** Defines the shape of the Kanboard/BigBoard data we are importing. We read its `db.sqlite`, not its PHP. |
| **`../minio-metadata/`** | Bash + `mongoexport` tooling that pulls existing Meteor WeKan data out of MongoDB: text → CSV → SQLite, files → MinIO/S3. The `fields/*.txt` files (41 of them) are the authoritative per-collection field lists of real production WeKan data. | **Import source #2** *and* the **validation oracle** for `schema.sql` (it tells us the real Mongo field names/shapes `schema.sql` must round-trip). |

**These are not three competing schemas to choose between.** `schema.sql` is the target;
the other two are inputs that must be transformed into it. The "decision" is to keep
`schema.sql` canonical and build two importers, *not* to adopt Kanboard's relational model
or to keep WeKan-Lite on MongoDB.

---

## Decision 1 — Canonical schema

| Option | Pros | Cons | Verdict |
|--------|------|------|---------|
| **Keep `schema.sql` (WeKan-native) canonical** | 1:1 with WeKan's domain model, JSON API (`wekan.yml`), and import/export formats; Mongo-style IDs let existing WeKan exports load unchanged; already the contract. | Must write a Kanboard→WeKan transform (ID/date/color remapping). | **CHOSEN** |
| Adopt Kanboard's `Sqlite.php` schema | Battle-tested, Kanboard data imports trivially. | Loses WeKan semantics (swimlanes-per-card, labels, custom fields, assignees vs members, OpenAPI surface); INTEGER PKs break WeKan export compatibility; WeKan-Lite would no longer *be* WeKan. | Reject |
| Stay on MongoDB (no SQLite) | Zero migration of WeKan data. | Defeats the whole WeKan-Lite goal (single-binary, no 800 GB Mongo); Kanboard has no Mongo path anyway. | Reject |

WeKan-Lite **is** a WeKan reimplementation, so its schema must be WeKan's. Kanboard is a
*data donor*, not the model. Keep `schema.sql` as the single source of truth.

---

## Decision 2 — Import strategy

Both sources converge on `schema.sql` through small, scriptable ETL passes; neither
extends the canonical schema.

```
  Kanboard db.sqlite ──┐
                       ├──►  id-remap + type-coerce  ──►  WeKan-Lite (schema.sql)
  WeKan Mongo CSVs  ───┘                                        │
  (minio-metadata)                                              └─► files → MinIO/S3
```

- **WeKan Mongo → WeKan-Lite** is mostly a *rename/reshape*: same domain, same field
  names (see `fields/cards-fields.txt` ≈ `cards` table). Nested arrays (`labelIds`,
  `members`, `assignees`, `customFields`) explode into the child tables; `vote`/`poker`/
  `*_gantt` round-trip into `cards.extra_json` per the DEFERRED note in `contract.md`.
- **Kanboard → WeKan-Lite** is a genuine *model translation*; the mapping and the
  impedance mismatches are below.

---

## Kanboard → WeKan-Lite table mapping

(Kanboard source columns from `app/Schema/Sqlite.php`; current schema = `VERSION = 128`,
so `tasks`/`users`/`projects` have more columns than the v1 `CREATE TABLE` — read them
from the live `db.sqlite`, not from the first migration.)

| Kanboard | → WeKan-Lite | Notes |
|----------|--------------|-------|
| `projects` | `boards` | `is_active` → `archived` (inverted). `name`→`title`; synthesize `slug`. |
| `project_has_users` | `board_members` | Map Kanboard role → `isAdmin`/`isCommentOnly`/`isReadOnly` flags. |
| `swimlanes` | `swimlanes` | `position`→`sort`; `is_active`→`archived` (inverted). Kanboard's implicit "Default swimlane" must be materialized. |
| `columns` | `lists` | `position`→`sort`; `title`→`title`. Kanboard WIP `task_limit` → `wip_enabled`/`wip_value`. |
| `tasks` | `cards` | The big one. `column_id`→`listId`, `swimlane_id`→`swimlaneId`, `project_id`→`boardId`, `owner_id`→`userId`/assignee, `position`→`sort`, `is_active`→`archived`. Dates below. |
| `task_has_subtasks` | `checklists` + `checklist_items` | Kanboard subtasks (title/status/time) → one checklist per card, items with `isFinished = status==2`. Time tracking → `extra_json`. |
| `comments` | `card_comments` | `comment`→`text`; epoch `date_creation`→ISO `createdAt`. |
| `tags` + `task_has_tags` | `board_labels` + `card_labels` | Kanboard tags are project-scoped → board labels; assign a color. |
| `links` + `task_has_links` | `card_dependencies` | Map Kanboard link labels (`blocks`, `is blocked by`, `relates to`…) → WeKan `type` enum. |
| `task_has_files` | attachments (deferred) → MinIO | Out of scope for v0.1 schema; route file bytes to MinIO like the WeKan path. |
| `task_has_metadata` / `user_has_metadata` | `card_custom_field_values` or `…extra_json` | Free-form `name`/`value` pairs; no WeKan equivalent — park in `extra_json` unless a real custom field is intended. |
| `task_has_external_links` | `cards.extra_json` | No WeKan column; preserve verbatim. |
| `project_has_categories` | `board_labels` *or* a custom field | Kanboard categories are single-select; closest WeKan analog is a label or a dropdown custom field. Pick one and document it. |
| `users` | `users` | `password` (bcrypt) → `services_json` if reusable, else force reset; `is_admin`→`isAdmin`. |
| `groups`, `actions`, `project_daily_stats`, `sessions`, `config`, … | — (drop) | Automation rules, analytics, sessions, settings have no v0.1 target. Log what is dropped. |

### BigBoard and other Kanboard plugins
"BigBoard" is a **Kanboard plugin**, not in this checkout (the `plugins/` dir is empty and
there are no `bigboard` references). It does **not** define its own data store — it renders
the standard `projects/columns/tasks` model. So importing "BigBoard data" = importing from
the **same `db.sqlite`** using the mapping above. Plugins that *do* add tables register them
under `plugin_schema_versions`; enumerate that table on the source DB and decide per plugin
(most are view/automation-only and can be dropped for v0.1).

---

## Impedance mismatches to handle in the importer

| Concern | Kanboard | WeKan-Lite (`schema.sql`) | Action |
|---------|----------|---------------------------|--------|
| **Primary keys** | `INTEGER` autoincrement | 17-char Mongo-style `TEXT` | Generate a WeKan-compatible random ID per row; keep a `kanboard_int_id → wekan_text_id` crosswalk table per entity to fix up all FKs (`column_id`, `task_id`, `swimlane_id`, link targets…). Do this **before** inserting, in dependency order. |
| **Dates** | `INTEGER` epoch seconds | `TEXT` ISO-8601 UTC `…sssZ` | Convert with millisecond precision; Kanboard `0`/NULL → leave NULL (don't write epoch 1970). |
| **Booleans / active flag** | `is_active = 1` means *visible* | `archived = 1` means *hidden* | Invert: `archived = (is_active == 0)`. |
| **Colors** | `color_id` = palette key (`yellow`, `green`, `blue_light`, …) | WeKan `BOARD_COLORS`/`LABEL_COLORS`/card colors | Build a fixed lookup table; fall back to a default when no match. |
| **Swimlanes** | optional; a project may use one implicit default | every card has `swimlaneId` | Materialize a real swimlane row for the Kanboard default so no card has a dangling `swimlaneId`. |
| **Members vs assignees** | one `owner_id` per task | distinct `card_members` and `card_assignees` | Decide policy: owner → assignee (recommended) and/or member; document it. |
| **Subtasks vs subtask-cards** | `task_has_subtasks` (lightweight) | WeKan has both checklists *and* real subtask cards (`parentId`) | v0.1: map to checklist items (simplest, lossless enough). Revisit if hierarchy matters. |
| **Referential integrity** | FK CASCADE on, INTEGER FKs | FK CASCADE on, TEXT FKs | Import parents first (boards→swimlanes→lists→cards→children); run with `PRAGMA foreign_keys=ON` to catch missed remaps. |

---

## How `../minio-metadata/` informs `schema.sql`

`../minio-metadata/fields/*.txt` are the real Meteor WeKan collection field lists — they are
why `schema.sql` looks the way it does. Spot-check: `fields/cards-fields.txt` lists
`title, archived, archivedAt, parentId, listId, swimlaneId, boardId, coverId, color,
customFields, dateLastActivity, members, assignees, labelIds, vote, poker,
targetId_gantt, …` — which is exactly the `cards` table plus the child tables
(`card_members`, `card_assignees`, `card_labels`, `card_custom_field_values`) plus the
`extra_json` deferrals (`vote`, `poker`, `*_gantt`). Treat these field files as the
**conformance checklist**: every field listed there must land somewhere on import — a
column, a child row, or a JSON blob — with nothing silently dropped.

The `minio-metadata` scripts also settle the **files** question for *both* importers:
attachments/avatars go to MinIO/S3 (or an alternative — the README tracks MinIO's
license/maintenance concerns), never into the SQLite file. Kanboard `task_has_files` and
WeKan GridFS attachments take the same exit.

---

## Open questions

1. **ID crosswalk persistence** — keep the `kanboard_int_id → wekan_text_id` maps only for
   the duration of one import run, or persist them to support *incremental* re-imports?
2. **User identity merge** — if a person exists in both Kanboard and WeKan, merge by email
   (from `user_emails`) or import as separate users?
3. **Categories** — import Kanboard `project_has_categories` as board labels (multi, lossy
   on single-select semantics) or as a dropdown custom field (faithful, heavier)?
4. **Password reuse** — are Kanboard bcrypt hashes acceptable to WeKan-Lite's auth, or do
   imported users get a forced password reset?
5. **Plugin tables** — once a real `db.sqlite` is in hand, enumerate `plugin_schema_versions`
   and decide per plugin what (if anything) maps.
