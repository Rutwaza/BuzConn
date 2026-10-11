## SpotLight App Split Plan

This repository now has two independent app workspaces:

- `spotlight_social_app`
- `spotlight_traffic_app`

Both can safely use the same Firebase project/database if we keep strict data boundaries and rules.

### Phase 1 (current)

- Create separate folders
- Initialize separate git repositories
- Keep current monolith untouched while we migrate feature-by-feature

Status:
- `spotlight_traffic_app` migrated and runnable (traffic + admin modules)
- `spotlight_traffic_app` now includes standalone auth entry flow (login/register + auth redirect)
- App access gating added via `users/{uid}.apps`:
  - Traffic app enforces `apps.traffic == true`
  - Social app enforces `apps.social == true`
- `spotlight_social_app` seeded from monolith and traffic/admin routes removed
- `spotlight_social_app` traffic/admin pages removed from source tree

### Phase 2

- Bootstrap a Flutter app inside each folder
- Move social modules into `spotlight_social_app`
- Move traffic/admin modules into `spotlight_traffic_app`

### Phase 3

- Separate package names and app IDs
- Add app-specific Firebase configs
- Lock rules for each app scope

### Phase 4

- Push each folder to its own GitHub repository
- Keep shared backend functions in one backend repo (or same functions folder with clear ownership)
