-- WeKan-Lite SQLite schema — v0.1
-- Derived from the Meteor WeKan SimpleSchema definitions (models/*.js).
-- Companion doc: wekan-lite-contract.md (conventions, HTTP/auth contract, deferred tables).
--
-- Conventions:
--   IDs       : Mongo-style 17-char strings as TEXT PRIMARY KEY (import compatibility).
--   Dates     : TEXT, ISO-8601 UTC (YYYY-MM-DDTHH:MM:SS.sssZ) for JSON round-trip fidelity.
--   Booleans  : INTEGER 0/1.
--   Nested arrays -> child tables (FK + sort where order matters).
--   Sparse/polymorphic blobs (users.profile, users.services, cards.extra_json, activities)
--             -> TEXT JSON columns (read/written whole; json_extract() when queried).

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
  receivedAt              TEXT, startAt TEXT, dueAt TEXT, endAt TEXT,
  spentTime               REAL, isOvertime INTEGER DEFAULT 0,
  backgroundImageURL      TEXT, backgroundImageId TEXT,
  subtasksDefaultBoardId  TEXT, subtasksDefaultListId TEXT,
  dateSettingsDefaultBoardId TEXT, dateSettingsDefaultListId TEXT,
  presentParentTask       TEXT DEFAULT 'no-parent',
  migrationVersion        INTEGER NOT NULL DEFAULT 1,
  -- ~70 allows*/cardAging*/restrict* display toggles, never queried by SQL:
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

CREATE TABLE board_orgs (
  boardId TEXT NOT NULL REFERENCES boards(id) ON DELETE CASCADE,
  orgId TEXT NOT NULL, orgDisplayName TEXT, isActive INTEGER DEFAULT 1,
  PRIMARY KEY (boardId, orgId)
);
CREATE TABLE board_teams (
  boardId TEXT NOT NULL REFERENCES boards(id) ON DELETE CASCADE,
  teamId TEXT NOT NULL, teamDisplayName TEXT, isActive INTEGER DEFAULT 1,
  PRIMARY KEY (boardId, teamId)
);
CREATE TABLE board_domains (
  boardId TEXT NOT NULL REFERENCES boards(id) ON DELETE CASCADE,
  domain TEXT NOT NULL, isActive INTEGER DEFAULT 1,
  PRIMARY KEY (boardId, domain)
);

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
  receivedAt TEXT, startAt TEXT, dueAt TEXT, endAt TEXT,
  dueComplete   INTEGER DEFAULT 0,
  dateLastActivity TEXT NOT NULL,
  spentTime     REAL DEFAULT 0,
  isOvertime    INTEGER DEFAULT 0,
  archived      INTEGER NOT NULL DEFAULT 0,
  archivedAt    TEXT,
  createdAt     TEXT NOT NULL,
  modifiedAt    TEXT NOT NULL,
  locationName TEXT, locationAddress TEXT, locationLatitude REAL, locationLongitude REAL,
  showActivities INTEGER DEFAULT 0,
  showListOnMinicard INTEGER DEFAULT 0,
  showChecklistAtMinicard INTEGER DEFAULT 0,
  hideFinishedChecklistIfItemsAreHidden INTEGER DEFAULT 0,
  -- vote/poker/gantt/stickers/locations deferred to child tables; round-trip verbatim here:
  extra_json    TEXT NOT NULL DEFAULT '{}'
);
CREATE INDEX idx_cards_list ON cards(listId, sort);
CREATE INDEX idx_cards_board ON cards(boardId);
CREATE INDEX idx_cards_swimlane ON cards(swimlaneId);
CREATE INDEX idx_cards_parent ON cards(parentId);

CREATE TABLE card_members (
  cardId TEXT NOT NULL REFERENCES cards(id) ON DELETE CASCADE,
  userId TEXT NOT NULL, PRIMARY KEY (cardId, userId)
);
CREATE TABLE card_assignees (
  cardId TEXT NOT NULL REFERENCES cards(id) ON DELETE CASCADE,
  userId TEXT NOT NULL, PRIMARY KEY (cardId, userId)
);
CREATE TABLE card_labels (
  cardId TEXT NOT NULL REFERENCES cards(id) ON DELETE CASCADE,
  labelId TEXT NOT NULL, PRIMARY KEY (cardId, labelId)
);
CREATE TABLE card_custom_field_values (
  cardId        TEXT NOT NULL REFERENCES cards(id) ON DELETE CASCADE,
  customFieldId TEXT NOT NULL,
  value         TEXT,                            -- JSON-encoded for multi-select arrays
  PRIMARY KEY (cardId, customFieldId)
);
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
  services_json TEXT NOT NULL DEFAULT '{}',  -- password hash + oauth/resume tokens (Meteor 'services')
  profile_json  TEXT NOT NULL DEFAULT '{}'   -- large, sparse, per-board UI prefs
);
CREATE TABLE user_emails (
  userId   TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  address  TEXT NOT NULL,
  verified INTEGER DEFAULT 0,
  PRIMARY KEY (userId, address)
);
CREATE INDEX idx_user_emails_addr ON user_emails(address);

-- ============================ AUTH TOKENS ============================
-- Meteor stores hashed tokens under services.resume.loginTokens; normalized out here
-- so Bearer validation is a single indexed lookup.
CREATE TABLE login_tokens (
  hashedToken TEXT PRIMARY KEY,                  -- SHA-256 of the bearer token
  userId      TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  createdAt   TEXT NOT NULL,
  expiresAt   TEXT
);
CREATE INDEX idx_login_tokens_user ON login_tokens(userId);

-- ============================ ACTIVITIES ============================
-- Schemaless in WeKan (varies per activityType): common columns indexed, rest as JSON.
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
