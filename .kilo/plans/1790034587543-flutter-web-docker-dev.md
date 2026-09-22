# Plan: Run Flutter Web App Locally in Docker with Live Reload

## Context

This repo is an unmodified `flutter create` boilerplate from ~2021:
- `pubspec.yaml` pins `sdk: ">=2.15.0-178.1.beta <3.0.0"` (pre-null-safety-stable era) and `flutter_lints: ^1.0.0`.
- `lib/main.dart` uses `Key? key` constructor params and `Theme.of(context).textTheme.headline4`, both of which are gone/deprecated in current stable Flutter/Dart (Dart 3 requires modern syntax; `headline4` was removed from `TextTheme` years ago in favor of `headlineMedium`).
- `web/index.html` uses the pre-2022 manual service-worker bootstrap script. Current stable Flutter's web build tooling expects the newer `flutter_bootstrap.js`/`flutter.js` loader pattern; the old template can trigger build warnings or fail to load correctly under a modern Flutter SDK.
- No Docker, devcontainer, or CI files exist yet. No mobile platform folders (android/ios/macos/windows/linux) are present — web is the only target, consistent with "portfolio website."
- Confirmed via user answers: (1) modernize the project to current stable Flutter/Dart rather than pinning an ancient toolchain, and (2) use a community-maintained Flutter Docker image (`ghcr.io/cirruslabs/flutter`) rather than hand-rolling an SDK install from a bare Debian base.

Per the org's front-end exemption ("These guidelines... will be ignored for isolated front-end... projects"), the Novacoast backend/infra standards (Alpine-only images, floating `latest` tags, `/health` + `/metrics` endpoints, OIDC, Postgres, etc.) do not apply to this static Flutter web app and are intentionally **not** applied here. A specific, pinned image tag is used instead of `latest` because reproducible local dev builds matter more than picking up unreviewed daily SDK changes for a project with no CI yet.

## Goals

1. Bring the project to a modern, working, lint-clean Flutter/Dart baseline.
2. Add Docker assets that let the developer run `flutter run -d web-server` in a container with source bind-mounted from the host, so edits to `lib/` are reflected in the browser via Flutter's hot reload — no rebuild/restart needed for most changes.
3. Document the workflow in `README.md`.

Explicitly out of scope for this plan: actual portfolio content/design, CI/CD pipeline, deployment/hosting, mobile targets.

## Step 1 — Modernize the Flutter project

1. Pick a pinned current stable Flutter version for both local tooling and the Docker image (e.g. `3.24.x` at time of writing). **Implementer must confirm the actual latest stable tag** available at `ghcr.io/cirruslabs/flutter` (see https://github.com/cirruslabs/docker-images-flutter) before finalizing the Dockerfile tag, since this plan cannot verify live registry contents.
2. Update `pubspec.yaml`:
   - `environment: sdk: '>=3.3.0 <4.0.0'` (adjust lower bound to match the Dart version bundled with the chosen Flutter tag).
   - Bump `flutter_lints` to a current major version (`^4.0.0` or whatever is current — verify on pub.dev) and `cupertino_icons` similarly.
   - After the Dockerfile exists (Step 2), run `flutter pub upgrade --major-versions` inside the container to regenerate `pubspec.lock` against the modern SDK rather than hand-editing lock-file versions.
3. Fix now-invalid/deprecated API usage in `lib/main.dart`:
   - Replace `{Key? key}) : super(key: key)` constructors with `super.key` parameters on both `MyApp` and `MyHomePage`.
   - Replace `Theme.of(context).textTheme.headline4` with `Theme.of(context).textTheme.headlineMedium` (the old getter was removed, not just deprecated — this will fail to compile on current Flutter otherwise).
   - Run `flutter analyze` after the change set and resolve any remaining lint errors introduced by the newer `flutter_lints` rule set.
4. Regenerate the `web/` scaffold for the current build-loader format: run `flutter create . --platforms=web` inside the modernized SDK (container or local) and let it overwrite `web/index.html` / `web/manifest.json` with the current template. Then manually re-apply the existing customizations that are worth keeping (`<title>`, `meta name="description"`, `apple-mobile-web-app-title`) into the new template. Verify `web/favicon.png` and `web/icons/*` are untouched/still referenced correctly.
5. Leave `.metadata` alone — the Flutter tool rewrites its `channel`/`revision` fields automatically on next SDK-aware command; manual edits aren't required and risk drifting from what the toolchain expects.

## Step 2 — Docker assets

Create three new files at the repo root:

### `Dockerfile`
- `FROM ghcr.io/cirruslabs/flutter:<pinned-version>` (see Step 1.1).
- `WORKDIR /app`
- `ENV PUB_CACHE=/pub-cache` (explicit, known path we control for the cache volume below, rather than relying on the image's default cache location).
- Copy only `pubspec.yaml` and `pubspec.lock` first, run `flutter pub get`, then `COPY . .` — standard layer-caching so dependency fetches aren't repeated on every source change.
- `EXPOSE 8080`
- Default `CMD`: run `flutter pub get` again (cheap no-op if already satisfied, but guards against the bind mount in Step 2's compose file shadowing the image's baked-in `.dart_tool`/lockfile state) and then start `flutter run -d web-server --web-hostname=0.0.0.0 --web-port=8080`.

### `docker-compose.yml`
- Single `web` service building from the `Dockerfile`.
- `volumes:`
  - `.:/app` (bind mount full repo so host edits are visible to the running Flutter process).
  - a named volume mounted at `/pub-cache` (matches `PUB_CACHE` above) so downloaded packages persist across container rebuilds instead of re-downloading every time.
  - a named volume mounted at `/app/.dart_tool` so the container's own build tool state isn't clobbered by the host's (gitignored/absent) `.dart_tool`, and vice versa — this sub-path volume takes precedence over the broader bind mount at `/app`.
- `ports: ["8080:8080"]`
- `stdin_open: true` and `tty: true` — required so `flutter run`'s interactive keys (`r` hot reload, `R` hot restart, `q` quit) work when attached, used as a manual fallback if file-change auto-detection lags (see caveat below).

### `.dockerignore`
- Exclude `build/`, `.dart_tool/`, `.git/`, `.kilo/`, `*.iml`, `.idea/`, `.DS_Store`, and any `.pub-cache/` — keeps the build context small and avoids leaking host-specific tool state into the image.

## Step 3 — README update

Add a "Running Locally (Docker)" section to `README.md` covering:
- `docker compose up --build` to start the dev server.
- Open `http://localhost:8080` in a browser.
- Edit files under `lib/`; `flutter run` auto-triggers hot reload on save, and changes should appear in the already-open browser tab without a manual refresh (Flutter web hot reload patches the running Dart app in place over the same debug connection used for asset serving — no second port needed).
- **Caveat:** on macOS, Docker Desktop's bind-mount file-change notifications can occasionally lag. If a save doesn't trigger a reload within a couple seconds, attach to the running container's terminal and press `r` (hot reload) or `R` (hot restart) manually.
- One-off commands without starting the dev server: `docker compose run --rm web flutter analyze`, `docker compose run --rm web flutter test`, `docker compose run --rm web flutter pub upgrade --major-versions`.

## Validation

1. `docker compose up --build` completes with no errors; log shows `flutter run` serving on port 8080.
2. `http://localhost:8080` loads the (still-boilerplate) counter page in a browser.
3. Edit visible text in `lib/main.dart`, save, confirm the open browser tab updates without a manual page refresh.
4. `docker compose run --rm web flutter analyze` — zero issues.
5. `docker compose run --rm web flutter test` — existing `test/widget_test.dart` passes (note: this test currently asserts counter-tap behavior tied to the boilerplate `MyHomePage`; it will need to be rewritten once real portfolio content replaces `main.dart`, but should still pass unmodified against the current boilerplate logic).

## Risks / Open Items for Implementer

- Exact latest stable Flutter tag must be confirmed against the `cirruslabs/docker-images-flutter` registry at implementation time (this plan's authoring environment cannot query it live).
- `flutter create . --platforms=web` regeneration may also touch `web/manifest.json` icon/theme-color defaults — diff before committing to make sure nothing app-specific is silently lost.
- `pubspec.lock` will change substantially after `flutter pub upgrade --major-versions`; review the diff for any transitive dependency surprises before committing.
