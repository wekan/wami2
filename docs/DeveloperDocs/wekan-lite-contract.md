# WeKan-Lite Contract — v0.1 (the keystone spec)

Source of truth: the Meteor WeKan repo (`models/*.js`, `server/models/*.js`,
`public/api/wekan.yml`). This document is the portable contract that the FreePascal
(wami/omi) reimplementation must satisfy. Any future PHP/JS port targets this same file.

The contract has three parts:
1. **SQLite schema** (below) — derived from the SimpleSchema field definitions.
2. **HTTP/route surface** — already frozen in `public/api/wekan.yml` (OpenAPI 2.0,
   ~145 endpoints). Do NOT re-derive; consume that file. Summary + auth flow below.
3. **Import/export formats** — preserve WeKan and Trello JSON (`models/wekanCreator.js`,
   `models/trelloCreator.js`); out of scope for v0.1, tracked for later.

---

## Conventions

- **IDs**: Mongo-style 17-char base-style strings, kept as `TEXT PRIMARY KEY`. Generate
  with a Meteor-compatible random-id routine in FreePascal so existing exports import cleanly.
- **Dates**: store as `TEXT` in ISO-8601 UTC (`YYYY-MM-DDTHH:MM:SS.sssZ`) to round-trip
  with the JSON API unchanged. (Epoch INTEGER is faster but breaks JSON fidelity.)
- **Booleans**: `INTEGER` 0/1.
- **Nested arrays** become child tables with a FK back to the parent + a `sort`/position
  column where order matters.
- **Polymorphic / sparse blobs** (`users.profile`, `users.services`, `activities`)
  stored as a `TEXT` JSON column rather than exploded — they're read/written whole and
  their shape varies. SQLite `json_extract()` covers the few cases needing query access.
- FK enforcement: `PRAGMA foreign_keys = ON;`

---

## Core schema (v0.1)

```sql
PRAGMA foreign_keys = ON;

-- ============================ BOARDS ============================
CREATE TABLE boards (
  id                      TEXT PRIMARY KEY,
  title                   TEXT NOT NULL,
  slug                    TEXT NOT NULL,
  description             TEXT,
  permission              TEXT NOT NULL DEFAULT 'private',   -- public|private
  type                    TEXT NOT NULL DEFAULT 'board',     -- board|template-board|template-container
  color                   TEXT NOT NULL DEFAULT 'belize',    -- BOARD_COLORS
  sort                    REAL NOT NULL DEFAULT -1,
  stars                   INTEGER NOT NULL DEFAULT 0,
  archived                INTEGER NOT NULL DEFAULT 0,
  archivedAt              TEXT,
  createdAt               TEXT NOT NULL,
  modifiedAt              TEXT,
  -- dates
  receivedAt              TEXT, startAt TEXT, dueAt TEXT, endAt TEXT,
  spentTime               REAL, isOvertime INTEGER DEFAULT 0,
  -- background
  backgroundImageURL      TEXT, backgroundImageId TEXT,
  -- defaults / linkage (self/cross refs; not FK-constrained to avoid insert ordering pain)
  subtasksDefaultBoardId  TEXT, subtasksDefaultListId TEXT,
  dateSettingsDefaultBoardId TEXT, dateSettingsDefaultListId TEXT,
  presentParentTask       TEXT DEFAULT 'no-parent',
  migrationVersion        INTEGER NOT NULL DEFAULT 1,
  -- The ~70 allows*/cardAging*/restrict* feature toggles are stored as one JSON blob
  -- to keep this table sane. They are board-level display prefs, never queried by SQL.
  settings_json           TEXT NOT NULL DEFAULT '{}'
);

CREATE TABLE board_labels (
  boardId  TEXT NOT NULL REFERENCES boards(id) ON DELETE CASCADE,
  id       TEXT NOT NULL,                 -- 6-char label id, unique within board
  name     TEXT,
  color    TEXT NOT NULL,                 -- LABEL_COLORS (24)
  PRIMARY KEY (boardId, id)
);

CREATE TABLE board_members (
  boardId               TEXT NOT NULL REFERENCES boards(id) ON DELETE CASCADE,
  userId                TEXT NOT NULL,
  isAdmin               INTEGER NOT NULL DEFAULT 0,
  isActive              INTEGER NOT NULL DEFAULT 1,
  isNoComments          INTEGER DEFAULT 0,
  isCommentOnly         INTEGER DEFAULT 0,
  isWorker              INTEGER DEFAULT 0,
  isNormalAssignedOnly  INTEGER DEFAULT 0,
  isCommentAssignedOnly INTEGER DEFAULT 0,
  isReadOnly            INTEGER DEFAULT 0,
  isReadAssignedOnly    INTEGER DEFAULT 0,
  PRIMARY KEY (boardId, userId)
);

CREATE TABLE board_orgs   (boardId TEXT NOT NULL REFERENCES boards(id) ON DELETE CASCADE,
                           orgId TEXT NOT NULL, orgDisplayName TEXT, isActive INTEGER DEFAULT 1,
                           PRIMARY KEY (boardId, orgId));
CREATE TABLE board_teams  (boardId TEXT NOT NULL REFERENCES boards(id) ON DELETE CASCADE,
                           teamId TEXT NOT NULL, teamDisplayName TEXT, isActive INTEGER DEFAULT 1,
                           PRIMARY KEY (boardId, teamId));
CREATE TABLE board_domains(boardId TEXT NOT NULL REFERENCES boards(id) ON DELETE CASCADE,
                           domain TEXT NOT NULL, isActive INTEGER DEFAULT 1,
                           PRIMARY KEY (boardId, domain));

-- ============================ SWIMLANES ============================
CREATE TABLE swimlanes (
  id         TEXT PRIMARY KEY,
  boardId    TEXT NOT NULL REFERENCES boards(id) ON DELETE CASCADE,
  title      TEXT NOT NULL,
  type       TEXT NOT NULL DEFAULT 'swimlane',
  color      TEXT,
  sort       REAL,
  height     INTEGER DEFAULT -1,
  archived   INTEGER NOT NULL DEFAULT 0,
  archivedAt TEXT,
  createdAt  TEXT NOT NULL,
  modifiedAt TEXT,
  updatedAt  TEXT
);
CREATE INDEX idx_swimlanes_board ON swimlanes(boardId, sort);

-- ============================ LISTS ============================
CREATE TABLE lists (
  id          TEXT PRIMARY KEY,
  boardId     TEXT NOT NULL REFERENCES boards(id) ON DELETE CASCADE,
  swimlaneId  TEXT DEFAULT '',                 -- optional (legacy boards have '')
  title       TEXT NOT NULL,
  type        TEXT NOT NULL DEFAULT 'list',
  color       TEXT,
  sort        REAL,
  width       INTEGER DEFAULT 272,
  starred     INTEGER DEFAULT 0,
  wip_enabled INTEGER DEFAULT 0,
  wip_value   INTEGER DEFAULT 1,
  wip_soft    INTEGER DEFAULT 0,
  archived    INTEGER NOT NULL DEFAULT 0,
  archivedAt  TEXT,
  createdAt   TEXT NOT NULL,
  modifiedAt  TEXT,
  updatedAt   TEXT
);
CREATE INDEX idx_lists_board ON lists(boardId, sort);

-- ============================ CARDS ============================
CREATE TABLE cards (
  id            TEXT PRIMARY KEY,
  boardId       TEXT REFERENCES boards(id) ON DELETE CASCADE,
  listId        TEXT,
  swimlaneId    TEXT,
  parentId      TEXT,                            -- subtask parent (self-ref)
  title         TEXT DEFAULT '',
  description   TEXT DEFAULT '',
  type          TEXT NOT NULL DEFAULT 'cardType-card',
  color         TEXT,
  coverId       TEXT,
  userId        TEXT NOT NULL,                   -- author
  requestedBy   TEXT DEFAULT '',
  assignedBy    TEXT DEFAULT '',
  sort          REAL DEFAULT 0,
  subtaskSort   REAL DEFAULT -1,
  cardNumber    INTEGER DEFAULT 0,               -- board-sequential
  linkedId      TEXT DEFAULT '',
  -- dates
  receivedAt TEXT, startAt TEXT, dueAt TEXT, endAt TEXT,
  dueComplete   INTEGER DEFAULT 0,
  dateLastActivity TEXT NOT NULL,
  spentTime     REAL DEFAULT 0,
  isOvertime    INTEGER DEFAULT 0,
  archived      INTEGER NOT NULL DEFAULT 0,
  archivedAt    TEXT,
  createdAt     TEXT NOT NULL,
  modifiedAt    TEXT NOT NULL,
  -- single-location legacy fields (Trello import)
  locationName TEXT, locationAddress TEXT, locationLatitude REAL, locationLongitude REAL,
  -- minicard display prefs (low-traffic) kept as columns since simple booleans
  showActivities INTEGER DEFAULT 0,
  showListOnMinicard INTEGER DEFAULT 0,
  showChecklistAtMinicard INTEGER DEFAULT 0,
  hideFinishedChecklistIfItemsAreHidden INTEGER DEFAULT 0,
  -- vote/poker/gantt/stickers/locations are deferred to child tables (see DEFERRED below);
  -- until implemented, round-trip them verbatim in this blob so no data is lost on import.
  extra_json    TEXT NOT NULL DEFAULT '{}'
);
CREATE INDEX idx_cards_list ON cards(listId, sort);
CREATE INDEX idx_cards_board ON cards(boardId);
CREATE INDEX idx_cards_swimlane ON cards(swimlaneId);
CREATE INDEX idx_cards_parent ON cards(parentId);

-- card many-to-many / nested arrays
CREATE TABLE card_members  (cardId TEXT NOT NULL REFERENCES cards(id) ON DELETE CASCADE,
                            userId TEXT NOT NULL, PRIMARY KEY (cardId, userId));
CREATE TABLE card_assignees(cardId TEXT NOT NULL REFERENCES cards(id) ON DELETE CASCADE,
                            userId TEXT NOT NULL, PRIMARY KEY (cardId, userId));
CREATE TABLE card_labels   (cardId TEXT NOT NULL REFERENCES cards(id) ON DELETE CASCADE,
                            labelId TEXT NOT NULL, PRIMARY KEY (cardId, labelId));
-- per-card custom field values; value kept as TEXT, app casts by customFields.type
CREATE TABLE card_custom_field_values (
  cardId        TEXT NOT NULL REFERENCES cards(id) ON DELETE CASCADE,
  customFieldId TEXT NOT NULL,
  value         TEXT,                            -- JSON-encoded for multi-select arrays
  PRIMARY KEY (cardId, customFieldId)
);
-- card dependencies ("Red Strings")
CREATE TABLE card_dependencies (
  cardId       TEXT NOT NULL REFERENCES cards(id) ON DELETE CASCADE,
  targetCardId TEXT NOT NULL,
  type         TEXT DEFAULT 'related-to',        -- related-to|blocks|is-blocked-by|fixes|is-fixed-by
  color        TEXT DEFAULT '#eb144c',
  icon         TEXT DEFAULT 'link',
  PRIMARY KEY (cardId, targetCardId, type)
);

-- ============================ CARD COMMENTS ============================
CREATE TABLE card_comments (
  id        TEXT PRIMARY KEY,
  boardId   TEXT NOT NULL REFERENCES boards(id) ON DELETE CASCADE,
  cardId    TEXT NOT NULL REFERENCES cards(id) ON DELETE CASCADE,
  userId    TEXT NOT NULL,
  text      TEXT NOT NULL,
  parentId  TEXT DEFAULT '',                     -- threaded replies (self-ref)
  createdAt TEXT NOT NULL,
  modifiedAt TEXT NOT NULL
);
CREATE INDEX idx_comments_card ON card_comments(cardId, createdAt);

-- ============================ CHECKLISTS ============================
CREATE TABLE checklists (
  id         TEXT PRIMARY KEY,
  cardId     TEXT NOT NULL REFERENCES cards(id) ON DELETE CASCADE,
  boardId    TEXT,
  title      TEXT NOT NULL DEFAULT 'Checklist',
  sort       REAL NOT NULL,
  finishedAt TEXT,
  hideCheckedChecklistItems INTEGER DEFAULT 0,
  hideAllChecklistItems     INTEGER DEFAULT 0,
  showChecklistAtMinicard   INTEGER DEFAULT 0,
  createdAt  TEXT NOT NULL,
  modifiedAt TEXT NOT NULL
);
CREATE INDEX idx_checklists_card ON checklists(cardId, sort);

CREATE TABLE checklist_items (
  id          TEXT PRIMARY KEY,
  checklistId TEXT NOT NULL REFERENCES checklists(id) ON DELETE CASCADE,
  cardId      TEXT NOT NULL,
  boardId     TEXT,
  title       TEXT NOT NULL,
  sort        REAL NOT NULL,
  isFinished  INTEGER NOT NULL DEFAULT 0,
  createdAt   TEXT,
  modifiedAt  TEXT NOT NULL
);
CREATE INDEX idx_checklist_items ON checklist_items(checklistId, sort);

-- ============================ CUSTOM FIELDS ============================
CREATE TABLE custom_fields (
  id                  TEXT PRIMARY KEY,
  name                TEXT NOT NULL,
  type                TEXT NOT NULL,             -- text|number|date|dropdown|checkbox|currency|stringtemplate
  currencyCode        TEXT,
  stringtemplateFormat    TEXT,
  stringtemplateSeparator TEXT,
  showOnCard          INTEGER DEFAULT 0,
  automaticallyOnCard INTEGER DEFAULT 0,
  alwaysOnCard        INTEGER DEFAULT 0,
  showLabelOnMiniCard INTEGER DEFAULT 0,
  showSumAtTopOfList  INTEGER DEFAULT 0,
  createdAt           TEXT,
  modifiedAt          TEXT NOT NULL
);
-- a field can apply to many boards (boardIds array)
CREATE TABLE custom_field_boards (
  customFieldId TEXT NOT NULL REFERENCES custom_fields(id) ON DELETE CASCADE,
  boardId       TEXT NOT NULL,
  PRIMARY KEY (customFieldId, boardId)
);
CREATE TABLE custom_field_dropdown_items (
  customFieldId TEXT NOT NULL REFERENCES custom_fields(id) ON DELETE CASCADE,
  id            TEXT NOT NULL,
  name          TEXT NOT NULL,
  sort          REAL,
  PRIMARY KEY (customFieldId, id)
);

-- ============================ USERS ============================
CREATE TABLE users (
  id        TEXT PRIMARY KEY,
  username  TEXT UNIQUE,
  isAdmin   INTEGER DEFAULT 0,
  loginDisabled INTEGER DEFAULT 0,
  authenticationMethod TEXT NOT NULL DEFAULT 'password',
  createdThroughApi INTEGER DEFAULT 0,
  heartbeat TEXT,
  lastConnectionDate TEXT,
  createdAt TEXT NOT NULL,
  modifiedAt TEXT NOT NULL,
  -- password hash + oauth/resume tokens live here (Meteor 'services'); opaque blob
  services_json TEXT NOT NULL DEFAULT '{}',
  -- large, sparse, per-board UI prefs; whole-object read/write
  profile_json  TEXT NOT NULL DEFAULT '{}'
);
CREATE TABLE user_emails (
  userId   TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  address  TEXT NOT NULL,
  verified INTEGER DEFAULT 0,
  PRIMARY KEY (userId, address)
);
CREATE INDEX idx_user_emails_addr ON user_emails(address);

-- ============================ AUTH TOKENS ============================
-- Bearer tokens. Meteor stores hashed tokens under services.resume.loginTokens; for a
-- clean reimplementation, normalize them out so validation is a single indexed lookup.
CREATE TABLE login_tokens (
  hashedToken TEXT PRIMARY KEY,                  -- SHA-256 of the bearer token
  userId      TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  createdAt   TEXT NOT NULL,
  expiresAt   TEXT
);
CREATE INDEX idx_login_tokens_user ON login_tokens(userId);

-- ============================ ACTIVITIES ============================
-- Intentionally schemaless in WeKan (varies per activityType). Keep common columns
-- indexed for the activity feed; stash the rest as JSON.
CREATE TABLE activities (
  id           TEXT PRIMARY KEY,
  activityType TEXT NOT NULL,
  userId       TEXT,
  boardId      TEXT,
  cardId       TEXT,
  listId       TEXT,
  swimlaneId   TEXT,
  createdAt    TEXT NOT NULL,
  modifiedAt   TEXT,
  data_json    TEXT NOT NULL DEFAULT '{}'        -- checklistId, commentId, oldListId, memberId, etc.
);
CREATE INDEX idx_activities_board ON activities(boardId, createdAt);
CREATE INDEX idx_activities_card  ON activities(cardId, createdAt);
```

### DEFERRED nested structures (round-trip via JSON now, normalize later)
On `cards`, these arrays/objects are preserved in `cards.extra_json` for v0.1 and become
child tables when their features are ported:
- `stickers[]` → `card_stickers(cardId, id, icon, name, highlight, position)`
- `locations[]` → `card_locations(cardId, id, name, address, latitude, longitude)`
- `vote{positive[],negative[],...}` → `card_votes` + `card_vote_users(cardId, userId, choice)`
- `poker{one[]..oneHundred[],unsure[],...}` → `card_poker_votes(cardId, userId, bucket)`
- `*_gantt[]` (targetId/linkType/linkId, parallel arrays) → `card_gantt_links(cardId, targetId, parentId, linkType)`

---

## HTTP / route contract (consume, don't re-derive)

- **Authoritative file**: `public/api/wekan.yml` (OpenAPI 2.0, ~145 endpoints, v9.71).
  Regenerate via `openapi/generate_openapi.py`. Treat this as the frozen JSON-API surface.
- **Routing style in WeKan**: `WebApp.handlers.[get|post|put|delete]`, auth middleware in
  `server/apiMiddleware.js`.

### Auth flow to replicate exactly
- `POST /users/login` — body `{ email|username, password, code? }` →
  `200 { id, token, tokenExpires }`; `401 { error, reason }`. (2FA via `code`.)
- `POST /users/register` — body `{ username?, email?, password }` → `200 { id, token, tokenExpires }`.
- Subsequent requests: `Authorization: Bearer <token>` (fallback `?access_token=`).
  Validate by hashing the token and looking it up → here, `login_tokens.hashedToken`
  (in WeKan: `users.services.resume.loginTokens.hashedToken`). Populate `req.userId`.

### Route surface by resource (URL shape; full schemas in wekan.yml)
- **boards** (18): `GET/POST /api/boards`, `GET/DELETE /api/boards/:id`,
  `PUT /api/boards/:id/{title,labels,cardSettings}`, `POST /api/boards/:id/copy`,
  `POST /api/boards/import`, members/domains sub-routes, `GET /api/users/:userId/boards`.
- **lists** (7): `GET/POST /api/boards/:b/lists`, `GET/PUT/DELETE …/lists/:l`, `…/copy`, `…/move`.
- **swimlanes** (7): mirror of lists under `…/swimlanes`.
- **cards** (22): list/swimlane-scoped CRUD, `…/cards/bulk`, `…/copy`, `…/archive`,
  `…/unarchive`, members/assignees add/remove, `GET /api/user/cards?due=&from=&to=`,
  `GET /api/boards/:b/cardsByCustomField/:cf/:val`.
- **checklists** (4) + **checklist items** (4), **comments** (3),
  **custom-fields** (8, incl. dropdown-items), **dependencies** (5), **rules** (5),
  **integrations/webhooks** (7), **users** (11), **settings** (2), **orgs/teams** (3+3),
  **attachments** (14), **attachment-settings** (2).

---

## What v0.1 deliberately leaves out
Attachments storage adapters, integrations/webhooks, rules engine internals, org/team
admin, and the deferred card sub-structures above. The schema + auth + board/list/
swimlane/card/checklist/comment/customField surface is the minimum viable WeKan.

## Open questions to resolve before coding the FreePascal app
1. Keep Mongo-style string IDs (recommended, for import compatibility) vs new integer PKs?
2. ISO-8601 TEXT dates (JSON fidelity) vs epoch INTEGER (speed)?
3. Store `users.profile` / `cards.extra_json` as JSON blobs (recommended) vs full normalization?
4. FreePascal web stack: fpWeb/fcl-web vs Brook vs raw fphttpserver?
