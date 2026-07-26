# Homelab Drive Web UI — Developer Notes

## Mobile-First Standard

Every new UI feature **must** include mobile and tablet CSS rules. This is non-negotiable.

### How device detection works

The BFF (`App.pm`) detects the User-Agent on every request and adds a CSS class to `<body>`:

| Class | Devices |
|-------|---------|
| `mobile` | Phones (iPhone, Android Mobile, BlackBerry, etc.) |
| `tablet` | iPad, Android tablet |
| `desktop` | Everything else (no extra class) |

When a mobile user chooses "Request Desktop Version" in their browser, the browser
sends a desktop UA → BFF detects desktop → serves full desktop layout. No extra code needed.

### Rules for new features

1. **New table columns** — must have a hide rule in the responsive section:
   ```css
   .mobile .col-newcol, .mobile th.col-newcol { display: none; }
   .tablet .col-newcol, .tablet th.col-newcol { display: none; }
   ```

2. **New modals** — must size correctly on mobile:
   ```css
   .mobile .my-new-modal { width: calc(100vw - 24px); max-height: 85vh; overflow-y: auto; }
   ```

3. **Touch targets** — any new button/tap target must be ≥ 44px tall on mobile:
   ```css
   .mobile .my-new-btn { min-height: 44px; }
   ```

4. **New toolbar buttons** — add to `.mobile #my-toolbar { flex-wrap: wrap; }` if needed.

5. **All responsive CSS goes** in the `/* === RESPONSIVE === */` section at the end of
   `public/style.css`. Never scatter mobile rules through the file.

### Testing

- Phone: 375×667 (iPhone SE) — most constrained
- Tablet: 768×1024 (iPad)
- Desktop: 1280×800+

In Chrome DevTools: toggle device toolbar, pick iPhone SE, hard-refresh to get mobile UA
detection from the server. (DevTools UA spoofing only works if the BFF re-renders the page.)
