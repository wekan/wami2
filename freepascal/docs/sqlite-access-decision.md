# WeKan-Lite — FreePascal SQLite access decision — v0.1

Companion to `architecture.md`. The two prototypes in this tree reach SQLite in **opposite
ways**, so this is a real fork to settle. The `goals.md` constraints (G1 single binary, G3
SQLite-only, G2 runs on 68k/Haiku/AROS) drive the answer.

## The two observed approaches

| | **A. `sqlite3` CLI via `TProcess`** | **B. Linked SQLite (`sqlite3`/`sqldb` units)** |
|---|---|---|
| Seen in | [`omi/public/server.pas`](https://github.com/wekan/omi/blob/main/public/server.pas) (`ExecSqlOnDb`) | implied by `contract.md` / `goals.md` |
| How | spawn `sqlite3 <db> -separator '|' -batch -noheader "<sql>"`, parse stdout | call libsqlite3 in-process (statically linked or `.so`/`.dll`) |
| Deps | a **`sqlite3` executable** on PATH | libsqlite3 (bundle the amalgamation → static) |
| Single binary (G1) | ✗ needs an external program too | ✓ one file, nothing else |
| Retro targets (G2) | needs a 68k/Amiga `sqlite3` build present | ✓ amalgamation is C89, compiles into the binary |
| Param binding | ✗ string-built SQL → must escape (`SqlEscape`) | ✓ real prepared statements / bound params |
| Result fidelity | text parsing; `|`/newlines in data are hazards | typed columns, BLOBs, NULL vs '' all exact |
| Concurrency/perf | a process per query | in-process, prepared-statement reuse |
| Bring-up cost | trivial — works the moment `sqlite3` exists | need the FPC binding + amalgamation in the build |

## Decision

**Target B (linked SQLite) as the production default; keep A behind the same interface as a
bootstrap/fallback.** Reasons, in order of the goals they serve:

- **G1 + G3**: "one executable, SQLite is the only datastore" is only literally true with
  B. A leaves a second required binary on disk — exactly the 42k-files-vs-one-binary problem
  WeKan-Lite exists to fix.
- **G2**: the SQLite **amalgamation is C89** and already compiles on the retro targets we
  care about; linking it statically is more portable than assuming a `sqlite3` CLI exists for
  Amiga/AROS/Haiku.
- **Correctness**: B gives prepared statements and bound parameters, killing the SQL-escaping
  and `|`-separator-collision risks visible in the omi text-parsing path — important once
  real user data (card text with newlines, pipes, NULs) hits the DB.

A stays useful and is **not** thrown away:
- It already works in omi, so it's the fastest path to a running WeKan-Lite on day one.
- On a platform where the FPC SQLite binding isn't built yet, A keeps the server functional.
- So both live behind `wldb.pas`'s interface, selected by a compile-time define
  (`{$DEFINE WLDB_CLI}` → A, default → B). Endpoints never see the difference.

## Consequences
- `wldb.pas` exposes a tiny surface (`Open`, `Query`→rows, `Exec`, `Prepare`/bind) so the two
  backends are swappable and endpoints stay backend-agnostic.
- Ship the **SQLite amalgamation** (`sqlite3.c`/`sqlite3.h`) vendored in-tree for offline
  static builds (G5: no Internet at build time).
- Keep `SqlEscape` only inside the CLI backend; the linked backend must use bound params, not
  escaping.
- Per-tenant DBs (`data/domains/<domain>/db/data.db`) mean many open handles — the linked
  backend should pool/cache connection handles (see `wltenant.pas`), which A cannot do (it
  re-spawns every call).

## SQLite on Amiga / retro targets

**FreePascal does not bundle SQLite on any platform** — its `sqlite3` unit (and `sqldb`'s
`sqlite3conn`) are only *header bindings* to a SQLite C library that must be provided
separately. On Linux/Windows/macOS/BSD that's the system `libsqlite3`. On **Amiga (68k/PPC),
MorphOS, AROS there is no system SQLite**, so the binding alone has nothing to call — SQLite
must be supplied. Three ways, in order of fit with the single-binary goal:

1. **Statically link the official amalgamation (recommended).** SQLite ships as one C89 file
   (`sqlite3.c` + `sqlite3.h`); it compiles with the Amiga C toolchain (gcc/vbcc) and links
   into the FPC binary. "Newest SQLite" = drop in the latest amalgamation from sqlite.org and
   compile it for the target — **no Aminet port needed**, you build the official source. This
   is the same vendored-amalgamation step the Consequences above already require (G5 offline
   build), just compiled for the retro target.
2. **Bind to an Aminet SQLite port / shared library.** Works, but pins you to that port's
   version and adds an external dependency (against "one binary").
3. **CLI backend (`-dWLDB_CLI`)** — shell out to an Amiga `sqlite3` executable (also on
   Aminet). The bootstrap path; needs that binary present.

### Build notes for the amalgamation on retro targets
- **No WAL.** WAL needs shared-memory/mmap, which classic Amiga filesystems don't provide.
  `wldb.pas` already switches `journal_mode` to `DELETE` under `{$IF DEFINED(AMIGA) or
  DEFINED(MORPHOS) or DEFINED(AROS)}` (rollback journal, fully portable).
- **Shrink + port flags:** compile with `SQLITE_THREADSAFE=0` (single-writer server),
  `SQLITE_OMIT_*` for unused features, and — if the default unix/win VFS doesn't map to
  AmigaDOS file locking — a small custom VFS via `SQLITE_OS_OTHER`. Compiled size is
  ~0.7–1 MB, feasible on 68k.
- The bundled FPC `sqlite3` binding tracks a stable, backward-compatible API, so statically
  linking a newer amalgamation is fine.

(Not verified on real Amiga hardware/toolchain here — this is from how FPC + SQLite build.)
