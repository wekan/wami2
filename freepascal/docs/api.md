# WeKan-Lite — REST API — v0.1

WeKan-Lite serves a subset of WeKan's REST API (the contract frozen in
[`public/api/wekan.yml`](../public/api/wekan.yml), OpenAPI 2.0), so WeKan's Python CLI
[`api.py`](https://github.com/wekan/wekan/blob/main/api.py) works against the FreePascal server
unchanged. Code: `wlapi.pas`.

## Auth (Bearer token)

Exactly as `api.py` does it:

```
POST /users/login        JSON {"username","password"}  -> {"id","token","tokenExpires"}
Authorization: Bearer <token>   on every /api/... request
```

Tokens are stored in `schema.sql` `login_tokens` (`hashedToken = HashText(token)`) — the same
table the no-cookie web sessions use. Multitenancy is by `Host:` header, so point `api.py`'s
`wekanurl` at the tenant's domain. (Password verification is still the skeleton placeholder —
same TODO as the web sign-in; it does not yet check the hash in `users.services_json`.)

## Implemented endpoints

| Method & path | api.py command | Response |
|---------------|----------------|----------|
| `POST /users/login` | (login) | `{"id","token","tokenExpires"}` |
| `GET /api/user` | `user` | `{"_id","username"}` |
| `GET /api/users` | `users` | `[{"_id","username"}]` |
| `GET /api/boards` | `boards` | public boards `[{"_id","title"}]` |
| `GET /api/users/:userId/boards` | `boards USERID` | that user's boards |
| `GET /api/boards/:boardId` | `board BOARDID` | `{"_id","title","slug","permission","color"}` |
| `PUT /api/boards/:boardId/title` | `editboardtitle` | `{"_id","title"}` |
| `POST /api/boards/:boardId/copy` | `copyboard` | `{"_id"}` (deep copy) |
| `PUT /api/boards/:boardId/labels` | `createlabel` | `{"_id"}` (nested `{label:{color,name}}`) |
| `GET /api/boards/:boardId/cards_count` | `get_board_cards_count` | `{"board_cards_count"}` |
| `GET /api/boards/:boardId/swimlanes` | `swimlanes BOARDID` | `[{"_id","title"}]` |
| `GET /api/boards/:boardId/swimlanes/:swimlaneId/cards` | `cardsbyswimlane` | `[{"_id","title"}]` |
| `GET /api/boards/:boardId/lists` | `lists BOARDID` | `[{"_id","title"}]` |
| `POST /api/boards/:boardId/lists` | `createlist` | `{"_id"}` |
| `GET /api/boards/:boardId/lists/:listId` | `list` | `{"_id","title"}` |
| `GET /api/boards/:boardId/lists/:listId/cards` | (list cards) | `[{"_id","title"}]` |
| `POST /api/boards/:boardId/lists/:listId/cards` | `addcard` | `{"_id"}` |
| `GET /api/boards/:boardId/lists/:listId/cards_count` | `get_list_cards_count` | `{"list_cards_count"}` |
| `GET /api/boards/:boardId/lists/:listId/cards/:cardId` | `getcard` | card object (incl. `labelIds`) |
| `PUT /api/boards/:boardId/lists/:listId/cards/:cardId` | `editcard` / `editcardcolor` / `addlabel` | updated card |
| `GET`/`POST /api/boards/:boardId/cards/:cardId/checklists` | `checklistid` / `addchecklist` | list / `{"_id"}` |
| `GET /api/boards/:boardId/cards/:cardId/checklists/:checklistId` | `checklistinfo` | checklist + items |
| `POST /api/boards/:boardId/cards/:cardId/checklists/:checklistId/items` | (addchecklist items) | `{"_id"}` |

Verified end-to-end against the real `api.py` on FPC 3.2.3: login → board/swimlanes/lists →
createlist → addcard → cardsbyswimlane → editcard/editcardcolor → counts → editboardtitle →
copyboard → createlabel → addchecklist/checklistid, with rows persisting to the tenant's
SQLite DB.

## Notes & TODO

- Routes use httproute `:param` patterns; handlers read `aRequest.RouteParams['boardId']` etc.
- `wekan.yml` is itself served (statically, from `public/api/`) at `/api/wekan.yml`.
- Bodies are accepted as JSON **or** form-encoded (`BodyField` tries both), matching `api.py`'s
  mix of `json=` (login) and `data=` (other calls).
- Still TODO (remaining `wekan.yml` endpoints): delete card/list/board, custom fields,
  card comments, swimlane create/edit, attachments, rules/webhooks, org/teams, settings,
  import/export, label edit/delete and checklist-item toggle, and real password hashing +
  per-board authorization checks.
