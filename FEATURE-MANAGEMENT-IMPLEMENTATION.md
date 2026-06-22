# Implementation Prompt: User-Defined Feature Set Management

## Overview

Add the ability to create, edit, and delete user-defined firewall feature sets
through both the controller web UI and the `fw` CLI. Built-in features remain
toggle-only.

---

## Architecture

### Storage

- User-created features live in `/policy/features.d/<name>.list`
- This directory is on the shared `/policy` Docker volume (read-write by both
  the firewall and control containers; persists across container restarts)
- Built-in features remain in `/policy/features.defs/` (wiped and re-seeded
  from the image on each container start by `entrypoint.sh`)

### File format (unchanged from built-in features)

```
# Human-readable description
# depends: github, npm
example.com
.example.org
api.foo.com
```

---

## Changes Required

### 1. `/workspace/.devcontainer/firewall/build-acl.sh`

Currently scans only `$DEFS` (`/policy/features.defs/`). Must also scan
`/policy/features.d/`.

**Changes:**

- Add a `USER_DEFS` variable: `USER_DEFS="${USER_FEATURE_DEFS:-$POLICY/features.d}"`
- Update `_feat_domains()` to check `$USER_DEFS/$1.list` if not found in `$DEFS`
- Update `_feat_deps()` to check `$USER_DEFS/$1.list` if not found in `$DEFS`
- Update the `[ -f "$DEFS/$_f.list" ] || continue` guard in the closure loop to
  also accept `$USER_DEFS/$_f.list`
- After emitting built-in feature domains in the closure, also emit domains from
  user features that are in the closure
- Emit `_baseline` from user defs too (if it existed — but validation prevents
  creating one named `_baseline`)

### 2. `/workspace/.devcontainer/firewall/fw`

Extend the `feature` subcommand. Current subcommands: `list`, `on`, `off`.
Add: `create`, `edit`, `delete`, `show`.

**New variables:**

```bash
USER_DEFS=/policy/features.d
```

**New subcommands:**

#### `fw feature create <name> [-d "description"] [--depends a,b] [--domain x.com]...`

- Validate name: regex `[A-Za-z0-9_-]{1,40}`, not `_baseline`
- Reject if name collides with a built-in (`$DEFS/$name.list` exists)
- Reject if name collides with an existing user feature (`$USER_DEFS/$name.list` exists)
- Validate each domain against the hostname regex (labels separated by dots,
  optional leading `.` for wildcard, at least one dot, no paths/ports/protocols/spaces)
- Validate dependencies: each must resolve to an existing `.list` in either
  `$DEFS` or `$USER_DEFS`
- If no `--domain` flags provided, read domains from stdin (one per line)
- Write the `.list` file to `$USER_DEFS/$name.list`
- Add `$name=on` to `$STATE` (using `_set_feature`)
- Print confirmation message

#### `fw feature edit <name> [-d "description"] [--depends a,b] [--domain x.com]...`

- Reject if name is a built-in feature (error: "built-in feature, cannot edit")
- Reject if `$USER_DEFS/$name.list` does not exist
- Full replacement semantics: all fields are required (description can be empty)
- Same validation as create (domains, dependencies)
- If no `--domain` flags provided, read domains from stdin
- Overwrite `$USER_DEFS/$name.list`
- Print confirmation message

#### `fw feature delete <name>`

- Reject if name is a built-in feature (error: "built-in feature, cannot delete")
- Reject if `$USER_DEFS/$name.list` does not exist
- Remove `$USER_DEFS/$name.list`
- Remove the `$name=...` line from `$STATE`
- No confirmation prompt
- Print confirmation message

#### `fw feature show <name>`

- Look up in both `$DEFS` and `$USER_DEFS`
- Print the raw file content (shows description, depends, domains)
- Indicate whether it's built-in or user-created

#### `fw feature list` (updated)

- Scan both `$DEFS/*.list` and `$USER_DEFS/*.list`
- Show a `[user]` or `[built-in]` tag next to each feature name
- Otherwise same format as current (name, on/off, dependency info, domains)

**Update usage/help text** to document new subcommands.

### 3. `/workspace/.devcontainer/control/dashboard.py`

#### New config constant

```python
USER_DEFS_DIR = os.environ.get("USER_FEATURE_DEFS", "/policy/features.d")
```

#### Startup initialization

In the `if __name__ == "__main__"` block (or wherever the server starts),
add:

```python
os.makedirs(USER_DEFS_DIR, exist_ok=True)
```

#### Update `_read_feature_defs()`

Scan both `DEFS_DIR` and `USER_DEFS_DIR`. Return an additional piece of
metadata per feature: `"builtin": True/False`. The baseline is always from
`DEFS_DIR`.

#### Update `_read_features()`

Include the `builtin` flag in each feature dict returned to the API.

#### Update `_read_state()`

Include user features in the state map (currently only iterates `defs` keys
which will now include user features).

#### New API endpoints

All three accept `Content-Type: application/json`. Body limit: **64KB**
(only for these endpoints; keep 4KB for existing ones).

##### `POST /api/feature/create`

Request body:
```json
{
  "name": "myfeature",
  "description": "Optional description",
  "domains": ["example.com", ".example.org"],
  "depends": ["github"]
}
```

Logic:
1. Validate `name` with `_FEATURE_RE`
2. Reject if name is `_baseline`
3. Reject if `name.list` exists in `DEFS_DIR` (built-in collision)
4. Reject if `name.list` exists in `USER_DEFS_DIR` (already exists)
5. Validate every domain in `domains` with `_DOMAIN_RE` (must be non-empty list)
6. Validate every dependency in `depends`: must have a `.list` in either
   `DEFS_DIR` or `USER_DEFS_DIR`
7. Write the `.list` file to `USER_DEFS_DIR/name.list`
8. Add `name=on` to `STATE_FILE` (same logic as `feature.sh` / `_set_feature`)
9. Return `{"ok": true, "message": "Feature 'name' created and enabled"}`

##### `POST /api/feature/update`

Request body: same schema as create.

Logic:
1. Validate `name`
2. Reject if `name.list` exists in `DEFS_DIR` (cannot edit built-in)
3. Reject if `name.list` does NOT exist in `USER_DEFS_DIR` (not found)
4. Validate domains and dependencies (same as create)
5. Overwrite `USER_DEFS_DIR/name.list`
6. Return `{"ok": true, "message": "Feature 'name' updated"}`

##### `POST /api/feature/delete`

Request body:
```json
{
  "name": "myfeature"
}
```

Logic:
1. Validate `name`
2. Reject if `name.list` exists in `DEFS_DIR` (cannot delete built-in)
3. Reject if `name.list` does NOT exist in `USER_DEFS_DIR` (not found)
4. Remove `USER_DEFS_DIR/name.list`
5. Remove `name=...` line from `STATE_FILE`
6. Return `{"ok": true, "message": "Feature 'name' deleted"}`

#### Update `GET /api/features` response

Each feature object gains:
```json
{
  "name": "...",
  "builtin": true,
  ...existing fields...
}
```

#### Update URL routing

The existing `do_POST` handler matches paths. Add routing for the three new
paths. For these three paths only, override `MAX_BODY` to 65536.

### 4. Controller Web UI (embedded HTML/JS in `dashboard.py`)

#### Feature list table changes

- Add a column or badge indicating **Built-in (read-only)** vs **User** for
  each feature
- Built-in features: show only the Enable/Disable toggle (existing behavior)
  with a note: "Built-in features are read-only. Edit the source .list file on
  the host to modify."
- User features: show Enable/Disable toggle + **Edit** button + **Delete** button

#### "Create Feature" button

- Placed above the feature table
- Opens the shared create/edit modal

#### Shared modal (create and edit)

Fields:
- **Name** — text input, validated on blur and submit (`[A-Za-z0-9_-]{1,40}`)
  - Disabled (read-only) when editing
- **Description** — text input (optional)
- **Domains** — textarea, one per line, placeholder: "example.com\n.example.org"
- **Dependencies** — checkboxes listing all available features (built-in + user,
  excluding the feature being edited). Checkboxes show the feature name as label.

Buttons:
- **Create** / **Save** (depending on mode)
- **Cancel**

On submit:
- Client-side validation (name format, at least one domain, domain format)
- POST to `/api/feature/create` or `/api/feature/update`
- On success: close modal, refresh feature list
- On error: show error message in the modal

#### Edit button behavior

- Opens the modal pre-populated with current name (disabled), description,
  domains (joined by newlines), and dependencies (checkboxes pre-checked)

#### Delete button behavior

- `confirm("Delete feature 'name'? This cannot be undone.")`
- On confirm: POST to `/api/feature/delete`
- On success: refresh feature list

#### Visual distinction for built-in features

- Show a badge/tag: e.g., `<span class="badge badge-builtin">Built-in</span>`
- Tooltip or subtle note: "Built-in features are read-only. Edit the source
  .list file on the host to modify."

---

## Validation Rules (shared across all interfaces)

### Feature name
- Regex: `[A-Za-z0-9_-]{1,40}`
- Cannot be `_baseline`
- Cannot match an existing built-in feature name
- Cannot match an existing user feature name (except when editing that feature)

### Domain
- Regex (same as `_DOMAIN_RE` in dashboard.py):
  `^\.?(?!-)[A-Za-z0-9-]{1,63}(?<!-)(\.(?!-)[A-Za-z0-9-]{1,63}(?<!-))+$`
- This enforces: valid hostname labels, optional leading `.` for wildcard,
  at least two labels (i.e., at least one dot), no bare TLDs

### Dependencies
- Each dependency name must resolve to a `.list` file in either `$DEFS` or
  `$USER_DEFS`
- Built-in features must never be modified to depend on user features

---

## Error Messages

| Condition | Message |
|-----------|---------|
| Name invalid | "Invalid feature name. Use 1-40 characters: letters, digits, hyphens, underscores." |
| Name is `_baseline` | "The name '_baseline' is reserved." |
| Name collides with built-in | "Name 'X' is already used by a built-in feature." |
| Name already exists (user) | "A user feature named 'X' already exists." |
| Feature not found (edit/delete) | "No user feature named 'X' found." |
| Cannot edit built-in | "'X' is a built-in feature and cannot be modified. Edit the source file on the host." |
| Cannot delete built-in | "'X' is a built-in feature and cannot be deleted." |
| No domains | "At least one domain is required." |
| Invalid domain | "Invalid domain on line N: 'value'" |
| Unknown dependency | "Unknown dependency: 'X'. Available features: ..." |

---

## Files to modify

| File | Nature of change |
|------|-----------------|
| `.devcontainer/firewall/build-acl.sh` | Dual-directory scan (read-only mount — requires host-side script) |
| `.devcontainer/firewall/fw` | New subcommands: create, edit, delete, show; updated list (read-only mount — requires host-side script) |
| `.devcontainer/control/dashboard.py` | New API endpoints + UI changes (read-only mount — requires host-side script) |

**Note:** All three files are on read-only bind mounts inside the container.
Generate a shell script at `/workspace/apply-feature-management.sh` containing
the actual edits (using `sed`, `cat <<'EOF'`, `patch`, or full file rewrites)
for the user to run from the host.

---

## Documentation and Presentation Updates

All the following must be updated to reflect the new create/edit/delete
capabilities. Each entry lists the file and what specifically to change.

### Must update

| File | What to update |
|------|---------------|
| `.devcontainer/firewall/fw` (lines 1-10, 148-157) | Add `fw feature create/edit/delete/show` to the header synopsis comment and the usage/help output in the default case |
| `docs/allowlist.md` (lines 1-19 CLI reference, lines 23-35 dashboard section, lines 37-83 feature-sets section) | Add new CLI commands to the reference table; document the "Create Feature" button, modal, edit/delete actions in the dashboard section; document `/policy/features.d/` as user-managed features directory |
| `README.md` (lines 51-77 "Manage the allowlist" section) | Add `fw feature create/edit/delete/show` to the command listing; mention the web UI now supports creating features |

### Should update

| File | What to update |
|------|---------------|
| `AGENTS.md` (lines 25-34 firewall section) | Add `fw feature create <name>` and `fw feature delete <name>` to the command examples so agents know how to manage user features; mention `/policy/features.d/` |
| `CLAUDE.md` (lines 25-34) | Keep in sync with AGENTS.md — identical content |
| `docs/operations.md` (lines 165-189 "without the control container" section) | Add the new `fw feature` subcommands to the CLI reference table for control-less operation |
| `docs/file-guide.md` (lines 37-41) | Add `/policy/features.d/` to the `.devcontainer/firewall/` entry; note that user-created features are stored here |
| `.devcontainer/control/dashboard.py` (module docstring, lines 1-10) | Update docstring to mention feature CRUD endpoints alongside toggle |

### If relevant

| File | What to update |
|------|---------------|
| `docs/security.md` | Note that user-created features follow the same validation and dependency rules as built-in features |
| `USAGE.md` (lines 145-230 troubleshooting) | Add example showing `fw feature create` as a way to bulk-allow domains for a new tool/service |

### Presentation (UI text and help)

- **Dashboard `#features` view**: add explanatory text above the feature table:
  "User-created features are stored in `/policy/features.d/` and persist across
  container restarts. Built-in features are image-managed and read-only."
- **Modal form**: include helper text for each field (e.g., "One domain per line.
  Prefix with `.` for wildcard subdomains." for the domains textarea)
- **`fw feature --help`** or `fw feature` (no args): print a comprehensive
  usage block covering all subcommands with examples:
  ```
  usage: fw feature list
         fw feature show <name>
         fw feature on|off <name>
         fw feature create <name> [-d "desc"] [--depends a,b] [--domain x]...
         fw feature edit <name> [-d "desc"] [--depends a,b] [--domain x]...
         fw feature delete <name>
  ```

---

## Sequencing

1. Modify `build-acl.sh` (dual-directory scan) — foundational
2. Extend `fw` CLI (create/edit/delete/show + updated list + help text)
3. Add API endpoints to `dashboard.py`
4. Add UI components (modal, buttons, badges) to the embedded HTML/JS

> **STOP — user verification required.**
> After step 4, pause and ask the user to review the implementation
> (UI, API, and CLI behaviour) and confirm it matches their expectations.
> Do **not** proceed to documentation updates or commit/push until the
> user explicitly says the implementation is correct.

5. Update documentation (`docs/allowlist.md`, `README.md`, `AGENTS.md`,
   `CLAUDE.md`, `docs/operations.md`, `docs/file-guide.md`)

> **STOP — user verification required.**
> After step 5, pause and ask the user to confirm the documentation
> updates look correct before committing and pushing any changes.
> Do **not** commit or push until the user explicitly approves.

6. End-to-end testing

---

## Testing considerations

- Create a feature via the UI, verify it appears in `fw feature list`
- Create a feature via `fw feature create`, verify it appears in the UI
- Edit a feature (change domains), verify the ACL updates within ~5 seconds
- Delete a feature, verify it's gone from both interfaces and `features.state`
- Attempt to create a feature with a built-in name — expect rejection
- Attempt to delete a built-in feature — expect rejection
- Create a feature with `depends: github`, enable it, verify github domains
  are included in the effective ACL
- Create a feature with an invalid dependency — expect rejection
- Restart the containers, verify user features persist and built-in features
  are unaffected
