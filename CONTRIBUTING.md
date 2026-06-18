# Contributing

Thanks for considering a contribution to AgenticFortress.

## License

By intentionally submitting a contribution to this repository, you agree that
your contribution is licensed under the Apache License, Version 2.0, unless you
explicitly state otherwise in writing.

See `LICENSE` for the full license text.

## Secret Handling

Do not include real secrets, provider tokens, private keys, credentials, or
secret-derived logs in issues, pull requests, tests, fixtures, screenshots, or
documentation.

Use synthetic placeholder values for examples and tests.

## Verification

Before proposing a production-ready change, run the relevant checks for the
area you changed. The full local verification gate is:

```sh
swift build
swift run agentic-fortress-contract-tests
./script/ui_smoke.sh
./script/build_and_run.sh --verify
./scripts/ci.sh
./scripts/tahoe_compatibility_check.sh
./scripts/check_secret_authority.sh
git diff --check
```

If a check cannot be run in your environment, mention that in the pull request
with the reason.
