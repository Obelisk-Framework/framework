# Contributing to Obelisk Framework

Thanks for taking the time to contribute.

## Getting set up

```bash
git clone git@github.com:Obelisk-Framework/framework.git
cd framework
npm install
```

## Running tests

```bash
npm test
```

CI runs this same command on every push and pull request — a PR won't merge with a red build.

## Coding conventions

- **Modules vs. plugins.** Core-owned domain logic lives in `modules/`; third-party/game-specific features live in `plugins/`. Scaffold new ones with the CLI rather than hand-rolling the structure:

  ```bash
  npm run cli -- make:module <name>
  npm run cli -- make:plugin <name>
  npm run cli -- make:model <name>
  npm run cli -- make:migration <name>
  npm run cli -- make:action <name>
  npm run cli -- make:policy <name>
  ```

- **Migrations** are timestamp-prefixed and must be listed explicitly, in order, in that module/plugin's `server/migrations.json` — they are not auto-discovered.
- **Interactions, actions, and policies** each follow the fixed interface documented in the [README](README.md#key-concepts). Match that shape exactly so the dispatcher can call them.
- **Tests** use a fake in-memory `QueryBuilder` (see `tests/support/fake_query_builder.lua` and any existing `*_spec.lua` for the pattern) rather than a live database, and run with `lua5.4 <file>_spec.lua`.
- Keep commit messages and docs free of unnecessary em/en dashes; code and SQL are unaffected.

## Submitting a change

1. Fork the repo and create a branch off `main`.
2. Make your change, following the conventions above.
3. Add or update tests covering it, and run `npm test` locally.
4. Open a pull request describing what changed and why. Link any related issue.

## Reporting bugs / requesting features

Open a GitHub issue with a clear description, reproduction steps if applicable, and your environment (FXServer version, database dialect).

## License

By contributing, you agree that your contributions will be licensed under the project's [CC BY-NC 4.0](LICENSE) license.
