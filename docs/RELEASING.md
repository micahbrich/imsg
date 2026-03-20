# Releasing

## Steps

1. **Update version and changelog**
   - Bump `version` in `package.json`
   - Move entries from the top of `CHANGELOG.md` into a new `## X.Y.Z - YYYY-MM-DD` section
   - Credit contributors (e.g., `thanks @user`)

2. **Verify**
   - `npm test` — all tests pass
   - `npx tsc --noEmit` — no type errors
   - `make build` — clean build succeeds

3. **Commit, tag, push**
   ```bash
   git add -A && git commit -m "vX.Y.Z"
   git tag -a vX.Y.Z -m "vX.Y.Z"
   git push origin main --tags
   ```

4. **Create GitHub release**
   ```bash
   gh release create vX.Y.Z -t "vX.Y.Z" --generate-notes
   ```

## What CI does

- `.github/workflows/ci.yml` runs typecheck + tests on every push and PR
