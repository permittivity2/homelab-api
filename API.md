# API Reference

Base URL: `http://<host>:3000` (or your reverse-proxied HTTPS host).

All responses are JSON. Successful responses generally include `"success": 1`
(the health endpoint and `/api/v1/auth/introspect` are the exceptions — see
below). Error responses include `"error": "<message>"` and use a non-2xx HTTP
status code.

CORS is wide open (`Access-Control-Allow-Origin: *`) on every response.
Note: `Access-Control-Allow-Methods` currently advertises `GET, POST, PUT,
DELETE, OPTIONS` and omits `PATCH`, even though `PATCH /files/:id` and
`PATCH /directories/:id` are real routes — a strict browser client may fail
CORS preflight on those two. `curl` is unaffected since it doesn't preflight.

The examples below assume:
```bash
BASE=http://localhost:3000
TOKEN="<jwt from /api/v1/auth/login>"
```

## Authentication

Two credential mechanisms are used together:

- **Bearer JWT** — short-lived access token. Send as `Authorization: Bearer <token>`.
  Required for all `/api/v1/drive/*` endpoints under the auth bridge (see below),
  and for `/api/v1/auth/validate` and `/api/v1/auth/introspect`.
- **`homelab-token` cookie** — long-lived refresh token, set as an httpOnly cookie
  by `/auth/login` and `/auth/refresh`. Used only by `/auth/logout` and `/auth/refresh`.

Beyond authentication, every non-public endpoint also checks **role-based
permissions**: the caller's role(s) must include that exact `METHOD /path`
in `api.role_permissions`, or the request gets `403 Forbidden` even with a
valid token. New accounts default to the `user` role, which is seeded with
every endpoint below except the Admin Routes. See [Admin Routes](#admin-routes-site_admin-only).

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

```bash
curl -c cookies.txt -X POST "$BASE/api/v1/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"email":"user@example.com","password":"secret"}'
```

### `POST /api/v1/auth/logout`

Requires the `homelab-token` cookie (set by login). Revokes the refresh token
and clears the cookie.

Response (200): `{ "success": 1 }`. `401` if the cookie is missing.

```bash
curl -b cookies.txt -X POST "$BASE/api/v1/auth/logout"
```

### `GET /api/v1/auth/validate`

Requires `Authorization: Bearer <jwt>`.

Response (200): `{ "success": 1, "valid": 1, "user": { "email": "..." } }`.
`401` if the token is missing, invalid, or expired.

```bash
curl "$BASE/api/v1/auth/validate" \
  -H "Authorization: Bearer $TOKEN"
```

### `GET /api/v1/auth/introspect`

Requires `Authorization: Bearer <jwt>`.

Used by external services (Dovecot/Roundcube OAuth2 flows) that need a flat,
single-attribute response rather than the nested `user.email` shape used
elsewhere in this API — this endpoint deliberately breaks from the usual
response envelope. There is **no `success` key** on success.

Response (200):
```json
{ "email": "user@example.com" }
```
`401` on missing/invalid/expired token: `{ "error": "<message>" }`.

```bash
curl "$BASE/api/v1/auth/introspect" \
  -H "Authorization: Bearer $TOKEN"
```

### `POST /api/v1/auth/refresh`

Requires the `homelab-token` cookie. Issues a new JWT + refresh token pair
(refresh token rotation) and re-sets the cookie.

Response (200):
```json
{ "success": 1, "token": "<new jwt>", "refresh_token": "<new refresh token>", "expires_in": 1800 }
```
`401` if the cookie is missing, or the refresh token is invalid/expired/revoked.

```bash
curl -b cookies.txt -c cookies.txt -X POST "$BASE/api/v1/auth/refresh"
```

### `GET /api/v1/health`

No auth required. Checks database connectivity.

Response: `{ "status": "ok"|"error", "version": "<string>", "database": "connected"|"disconnected" }`
(200 if ok, 500 if the database is unreachable).

```bash
curl "$BASE/api/v1/health"
```

---

## Drive — Public Share Routes (no auth required)

### `GET /api/v1/drive/s/:token/meta`
File share metadata. `404` if the token is invalid/expired.

```bash
curl "$BASE/api/v1/drive/s/abc123/meta"
```

### `GET /api/v1/drive/s/:token/dir`
Directory share metadata + top-level file list. `404` if invalid/expired.

```bash
curl "$BASE/api/v1/drive/s/abc123/dir"
```

### `GET /api/v1/drive/s/:token`
Legacy: streams the shared file directly (kept for backward compatibility;
prefer `/meta` + the web UI's X-Accel-Redirect pattern for new integrations).

```bash
curl "$BASE/api/v1/drive/s/abc123" -o downloaded_file
```

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
| POST | `/files/:id/share` | Create a share. Body: `{ share_with?, permission? }` (`share_with` omitted = public link; `permission` defaults to `read`). Returns `201` with `{ share_id, token }`. Errors (`400`): `'Specify file_id or dir_id, not both'`, `'file_id or dir_id required'`, `'File not found'`, `"User '<x>' not found on this server"`, `'Cannot share with yourself'`. |
| POST | `/directories/:id/share` | Same as above, for a directory (`'Directory not found'` instead of `'File not found'`). |
| GET | `/shares` | List shares you created. |
| GET | `/shares/with-me` | List shares others created targeting you. Only non-expired shares are returned. |
| DELETE | `/shares/:id` | Revoke a share you own (soft-deactivates; `404` if not found/not owned). |
| POST | `/bulk/trash` | Body: `{ file_ids: [], dir_ids: [], current_dir_id }`. Only trashes file_ids that are actually in `current_dir_id` (stale-selection guard). |
| POST | `/bulk/restore` | Body: `{ file_ids: [], dir_id }` (`dir_id` omitted = root). |
| POST | `/bulk/move` | Body: `{ file_ids: [], dir_ids: [], dir_id }`. Returns `{ moved: [...], skipped: [{id, name, reason}] }`. |
| POST | `/bulk/copy` | Body: `{ file_ids: [], dir_ids: [], dir_id? }` (`dir_id` = destination, omitted = root). Mirrors `/bulk/move`'s shape and error handling but copies instead of moving. |
| POST | `/zip` | Queue an async zip of the given files/directories. Body: `{ file_ids: [], dir_ids: [], dir_id }` (`dir_id` = destination). Returns `202`. |

### Notes on async operations

Upload, copy, and zip are queued as tasks for `homelab-api-backend-processor` to
execute out-of-band (checksum computation, actual file copy/archive creation).
The API returns immediately once the task is queued; poll `GET /files/:id/meta`
or `/fileinfo` to observe when a task completes (pending tasks are surfaced in
the `tasks` array on each file record).

### Examples

All examples below send `-H "Authorization: Bearer $TOKEN"`.

#### Quota

```bash
curl "$BASE/api/v1/drive/quota" \
  -H "Authorization: Bearer $TOKEN"
```

#### File listing & upload

```bash
# Root listing (flat, paginated)
curl -X POST "$BASE/api/v1/drive/fileinfo" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{}'

# Listing by path, recursive
curl -X POST "$BASE/api/v1/drive/fileinfo" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"path":"/Documents","recursive":1}'

# Listing by dir_id, paginated
curl -X POST "$BASE/api/v1/drive/fileinfo" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"dir_id":5,"startat":1000}'

# Upload
curl -X POST "$BASE/api/v1/drive/files" \
  -H "Authorization: Bearer $TOKEN" \
  -F "file=@/path/to/local/file.txt" \
  -F "dir_id=5"
```

#### File operations

```bash
# Metadata (no disk I/O)
curl "$BASE/api/v1/drive/files/42/meta" \
  -H "Authorization: Bearer $TOKEN"

# Metadata for a specific version
curl "$BASE/api/v1/drive/files/42/meta?version=7" \
  -H "Authorization: Bearer $TOKEN"

# Download
curl "$BASE/api/v1/drive/files/42" \
  -H "Authorization: Bearer $TOKEN" \
  -o file.txt

# Download a specific version
curl "$BASE/api/v1/drive/files/42?version=7" \
  -H "Authorization: Bearer $TOKEN" \
  -o file_v7.txt

# Trash a file
curl -X DELETE "$BASE/api/v1/drive/files/42" \
  -H "Authorization: Bearer $TOKEN"

# Move by path
curl -X PATCH "$BASE/api/v1/drive/files/42" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"to_path":"/Documents/Archive"}'

# Move by dir_id
curl -X PATCH "$BASE/api/v1/drive/files/42" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"dir_id":8}'

# Queue an async copy
curl -X POST "$BASE/api/v1/drive/files/42/copy" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"dir_id":8,"name":"file-copy.txt"}'

# List versions
curl "$BASE/api/v1/drive/files/42/versions" \
  -H "Authorization: Bearer $TOKEN"
```

#### Trash

```bash
# List trashed files
curl "$BASE/api/v1/drive/trash" \
  -H "Authorization: Bearer $TOKEN"

# Restore one file
curl -X POST "$BASE/api/v1/drive/files/42/restore" \
  -H "Authorization: Bearer $TOKEN"

# Empty trash permanently
curl -X DELETE "$BASE/api/v1/drive/trash" \
  -H "Authorization: Bearer $TOKEN"

# Get (or create) the Trash directory id
curl "$BASE/api/v1/drive/trash/dir" \
  -H "Authorization: Bearer $TOKEN"
```

#### Directories

```bash
# List direct children of a directory
curl "$BASE/api/v1/drive/directories?parent_id=5" \
  -H "Authorization: Bearer $TOKEN"

# List all directories (flat, for building a tree)
curl "$BASE/api/v1/drive/directories" \
  -H "Authorization: Bearer $TOKEN"

# Create a folder
curl -X POST "$BASE/api/v1/drive/directories" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"New Folder","parent_id":5}'

# Recursively trash + delete a directory tree
curl -X DELETE "$BASE/api/v1/drive/directories/5" \
  -H "Authorization: Bearer $TOKEN"

# Rename a directory
curl -X PATCH "$BASE/api/v1/drive/directories/5" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"Renamed Folder"}'

# Move a directory
curl -X PATCH "$BASE/api/v1/drive/directories/5" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"parent_id":10}'
```

#### Sharing

```bash
# Create a public share link for a file (read-only)
curl -X POST "$BASE/api/v1/drive/files/42/share" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{}'
# => 201 { "share_id": 3, "token": "abc123" }

# Share a file with a specific user, with write permission
curl -X POST "$BASE/api/v1/drive/files/42/share" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"share_with":"otheruser@example.com","permission":"write"}'

# Share a directory (public link)
curl -X POST "$BASE/api/v1/drive/directories/5/share" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{}'

# List shares you created
curl "$BASE/api/v1/drive/shares" \
  -H "Authorization: Bearer $TOKEN"
# => 200 {
#      "success": 1,
#      "shares": [
#        {
#          "id": 3, "file_id": 42, "dir_id": null,
#          "share_token": "abc123", "permission": "read",
#          "is_active": 1, "created_at": "...", "access_count": 4,
#          "shared_with_user_id": null, "share_type": "file",
#          "target_name": "file.txt", "shared_with_email": null
#        }
#      ]
#    }

# List shares others created targeting you
curl "$BASE/api/v1/drive/shares/with-me" \
  -H "Authorization: Bearer $TOKEN"
# => 200 {
#      "success": 1,
#      "shares": [
#        {
#          "id": 9, "file_id": 17, "dir_id": null,
#          "share_token": "def456", "permission": "read",
#          "created_at": "...", "access_count": 1,
#          "share_type": "file", "target_name": "shared.pdf",
#          "file_size": 20480, "mime_type": "application/pdf",
#          "owner_email": "otheruser@example.com"
#        }
#      ]
#    }

# Revoke a share you own
curl -X DELETE "$BASE/api/v1/drive/shares/3" \
  -H "Authorization: Bearer $TOKEN"
```

#### Bulk operations

```bash
# Bulk trash (only file_ids actually in current_dir_id are trashed)
curl -X POST "$BASE/api/v1/drive/bulk/trash" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"file_ids":[42,43],"dir_ids":[6],"current_dir_id":5}'

# Bulk restore to root
curl -X POST "$BASE/api/v1/drive/bulk/restore" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"file_ids":[42,43]}'

# Bulk restore into a specific directory
curl -X POST "$BASE/api/v1/drive/bulk/restore" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"file_ids":[42,43],"dir_id":5}'

# Bulk move
curl -X POST "$BASE/api/v1/drive/bulk/move" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"file_ids":[42,43],"dir_ids":[6],"dir_id":8}'
# => 200 { "moved": [...], "skipped": [{"id":43,"name":"file.txt","reason":"..."}] }

# Bulk copy
curl -X POST "$BASE/api/v1/drive/bulk/copy" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"file_ids":[42,43],"dir_ids":[6],"dir_id":8}'
```

#### Zip

```bash
curl -X POST "$BASE/api/v1/drive/zip" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"file_ids":[42,43],"dir_ids":[6],"dir_id":8}'
# => 202 (queued; poll /fileinfo or /files/:id/meta on the destination dir)
```

## Admin Routes (`site_admin` only)

All routes below are under `/api/v1/admin` and require `Authorization: Bearer <jwt>`
for an account holding the `site_admin` role (`401` if unauthenticated, `403` if
authenticated but not a `site_admin`). Unlike every other endpoint in this API,
these are **not** gated through `api.role_permissions` — access is hardcoded to
the `site_admin` role check alone, so a bad edit to the permissions table can
never lock every admin out.

| Method | Path | Description |
|---|---|---|
| GET | `/roles` | List all roles (`id`, `name`, `description`). |
| GET | `/roles/:role/permissions` | List the endpoint keys (`"METHOD /path"`) granted to a role. |
| POST | `/roles/:role/permissions` | Grant an endpoint to a role. Body: `{ endpoint: "GET /api/v1/drive/quota" }`. `400` if the endpoint string doesn't match any actually-registered route. |
| DELETE | `/roles/:role/permissions` | Revoke an endpoint from a role. Endpoint passed as `?endpoint=` (query param) or JSON body, not a path segment. |
| GET | `/users/:email/roles` | List a user's current roles. |
| POST | `/users/:email/roles` | Assign a role to a user. Body: `{ role: "site_admin" }`. |
| DELETE | `/users/:email/roles/:role` | Revoke a role from a user. `400` if this would revoke `site_admin` from the last remaining admin. |
| POST | `/users/:email/reset-password` | Resets the target user's password to a randomly generated passphrase — **never accepts a client-supplied password** (any `new_password`-shaped body key is ignored outright). Returns `{ success, user: { email }, password: "<generated-plaintext>" }`, shown exactly once. Passphrase is always exactly two lowercase dictionary words joined by `-`, total length 12-20 characters, each word at least 3 characters (e.g. `river-otter`). Does **not** revoke existing sessions — call `/force-relogin` separately if that's also wanted. |
| POST | `/users/:email/revoke-tokens` | Revokes all of a user's refresh tokens, forcing re-login on their next token refresh. |
| POST | `/users/:email/force-relogin` | Identical to `/revoke-tokens` — same underlying action under a name that reads better for "kick them out and make them log back in." |

### Examples

```bash
# Grant site_admin to a user
curl -X POST "$BASE/api/v1/admin/users/alice@example.com/roles" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"role":"site_admin"}'

# Reset a user's password
curl -X POST "$BASE/api/v1/admin/users/alice@example.com/reset-password" \
  -H "Authorization: Bearer $ADMIN_TOKEN"
# => 200 { "success": 1, "user": {"email":"alice@example.com"}, "password": "cedar-finch" }

# Revoke a permission from the default user role
curl -X DELETE "$BASE/api/v1/admin/roles/user/permissions?endpoint=GET%20/api/v1/drive/quota" \
  -H "Authorization: Bearer $ADMIN_TOKEN"
```
