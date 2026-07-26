# API Reference

Base URL: `http://<host>:3000` (or your reverse-proxied HTTPS host).

All responses are JSON. Successful responses generally include `"success": 1`
(the health endpoint is the one exception — see below). Error responses include
`"error": "<message>"` and use a non-2xx HTTP status code.

CORS is wide open (`Access-Control-Allow-Origin: *`) on every response.

## Authentication

Two credential mechanisms are used together:

- **Bearer JWT** — short-lived access token. Send as `Authorization: Bearer <token>`.
  Required for all `/api/v1/drive/*` endpoints under the auth bridge (see below).
- **`homelab-token` cookie** — long-lived refresh token, set as an httpOnly cookie
  by `/auth/login` and `/auth/refresh`. Used only by `/auth/logout` and `/auth/refresh`.

### `POST /api/v1/auth/login`

Request body:
```json
{ "email": "user@example.com", "password": "secret" }
```

Rate limited: 5 failed attempts per email per 15-minute window (429 once exceeded).

Response (200):
```json
{
  "success": 1,
  "token": "<jwt>",
  "refresh_token": "<refresh token>",
  "expires_in": 1800,
  "user": { "email": "user@example.com", "quota_mb": 1024 }
}
```
Also sets the `homelab-token` httpOnly cookie (30-day expiry).

Errors: `400` missing email/password, `401` invalid credentials, `429` rate limited.

### `POST /api/v1/auth/logout`

Requires the `homelab-token` cookie (set by login). Revokes the refresh token
and clears the cookie.

Response (200): `{ "success": 1 }`. `401` if the cookie is missing.

### `GET /api/v1/auth/validate`

Requires `Authorization: Bearer <jwt>`.

Response (200): `{ "success": 1, "valid": 1, "user": { "email": "..." } }`.
`401` if the token is missing, invalid, or expired.

### `POST /api/v1/auth/refresh`

Requires the `homelab-token` cookie. Issues a new JWT + refresh token pair
(refresh token rotation) and re-sets the cookie.

Response (200):
```json
{ "success": 1, "token": "<new jwt>", "refresh_token": "<new refresh token>", "expires_in": 1800 }
```
`401` if the cookie is missing, or the refresh token is invalid/expired/revoked.

### `GET /api/v1/health`

No auth required. Checks database connectivity.

Response: `{ "status": "ok"|"error", "version": "<string>", "database": "connected"|"disconnected" }`
(200 if ok, 500 if the database is unreachable).

---

## Drive — Public Share Routes (no auth required)

### `GET /api/v1/drive/s/:token/meta`
File share metadata. `404` if the token is invalid/expired.

### `GET /api/v1/drive/s/:token/dir`
Directory share metadata + top-level file list. `404` if invalid/expired.

### `GET /api/v1/drive/s/:token`
Legacy: streams the shared file directly (kept for backward compatibility;
prefer `/meta` + the web UI's X-Accel-Redirect pattern for new integrations).

---

## Drive — Authenticated Routes

All routes below are under `/api/v1/drive` and require `Authorization: Bearer <jwt>`
(`401 Unauthorized` otherwise).

| Method | Path | Description |
|---|---|---|
| GET | `/quota` | Usage/limit/file count for the current user. |
| POST | `/fileinfo` | List files. Body: `{ path? , dir_id?, startat?, recursive? }` — provide `path` XOR `dir_id`, neither means "root, flat, paginated list of all root files"; either means a directory listing (optionally recursive). Paginated 1000/page via `startat`. |
| POST | `/files` | Upload. Multipart form: `file` (the upload), `dir_id` (optional). Auto-renames on name collision (`file.txt` → `file (1).txt`). Queues async `sha256` (and `thumbnail` for images) processing. Returns `201`. |
| GET | `/files/:id/meta` | Lightweight metadata (uuid, mime, file_name) — no disk I/O. Optional `?version=<id>`. |
| GET | `/files/:id` | Download (streams the file). Optional `?version=<id>`. |
| DELETE | `/files/:id` | Move to Trash (soft delete; quota unchanged until Empty Trash). |
| PATCH | `/files/:id` | Move or rename. Body: `{ to_path }` or `{ dir_id }` (mutually exclusive) to move; `{ name }` is not yet implemented (`501`). |
| POST | `/files/:id/copy` | Queue an async copy. Body: `{ to_path }` or `{ dir_id }`, optional `name`. Returns `202`. |
| GET | `/files/:id/versions` | List all versions of a file. |
| GET | `/trash` | List trashed files (with original path). |
| POST | `/files/:id/restore` | Restore one file from Trash. |
| DELETE | `/trash` | Permanently empty Trash (frees quota, deletes on-disk data). |
| GET | `/trash/dir` | Returns `{ dir_id }` of the user's Trash directory (creates it if missing). |
| GET | `/directories` | List directories. With `?parent_id=`, direct children only; without it, **all** directories for the user (flat list, for building trees). |
| POST | `/directories` | Create a folder. Body: `{ name, parent_id? }`. |
| DELETE | `/directories/:id` | Recursively trash all files under this directory tree, then delete the directory tree. |
| PATCH | `/directories/:id` | Body: `{ parent_id }` to move, or `{ name }` to rename. |
| POST | `/files/:id/share` | Create a share. Body: `{ share_with?, permission? }` (`share_with` omitted = public link; `permission` defaults to `read`). Returns `201` with `{ share_id, token }`. |
| POST | `/directories/:id/share` | Same as above, for a directory. |
| GET | `/shares` | List shares you created. |
| GET | `/shares/with-me` | List shares others created targeting you. |
| DELETE | `/shares/:id` | Revoke a share you own. |
| POST | `/bulk/trash` | Body: `{ file_ids: [], dir_ids: [], current_dir_id }`. Only trashes file_ids that are actually in `current_dir_id` (stale-selection guard). |
| POST | `/bulk/restore` | Body: `{ file_ids: [], dir_id }` (`dir_id` omitted = root). |
| POST | `/bulk/move` | Body: `{ file_ids: [], dir_ids: [], dir_id }`. Returns `{ moved: [...], skipped: [{id, name, reason}] }`. |
| POST | `/zip` | Queue an async zip of the given files/directories. Body: `{ file_ids: [], dir_ids: [], dir_id }` (`dir_id` = destination). Returns `202`. |

### Notes on async operations

Upload, copy, and zip are queued as tasks for `homelab-api-backend-processor` to
execute out-of-band (checksum computation, actual file copy/archive creation).
The API returns immediately once the task is queued; poll `GET /files/:id/meta`
or `/fileinfo` to observe when a task completes (pending tasks are surfaced in
the `tasks` array on each file record).
