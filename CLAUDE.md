# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A workshop for deploying Lambda functions on **Lambda Managed Instances (LMI)** with Graviton (arm64) processors, adapted from the official AWS workshop (originally Python) to Rust. The workload is a flight data processor using Polars. All workshop prose and script output is in **Spanish**; the reference material in `documents/` is the original English source.

There is one code project (`workshop/rust-function/`). Everything else is Markdown guides and bash orchestration scripts.

## Layout

- **`workshop/rust-function/`** — the only compiled project. Single-file Rust Lambda (`src/main.rs`, ~410 lines).
- **`workshop/*.md`** — the Spanish Rust adaptation, split in two guides: `WORKSHOP-RUST-LMI.md` (modules 1–10) and `WORKSHOP-MULTI-TENANCY.md` (modules 11–14).
- **`workshop/*.sh`** — the runnable path through the workshop. See "Script pipeline" below.
- **`documents/DOC-0NN.md`** — verbatim captures of the original AWS workshop pages (English, with YAML frontmatter holding the source URL). Reference only; do not treat as the spec for the Rust version. DOC-001/002/003/005 map to the Rust guide, DOC-006–010 to the multi-tenancy guide, DOC-004 is a durable-functions pattern not implemented here.
- **`files/*.png`** — diagrams referenced from the guides and README.

## Commands

```bash
# Build (from workshop/rust-function/)
cargo lambda build --release --output-format zip          # on aarch64
cargo lambda build --release --output-format zip --arm64  # on x86_64
```

Full workshop path, in order — each script depends on `.env` state written by the previous one:

```bash
bash workshop/setup-capacity-provider.sh   # interactive: discovers VPC/subnets/roles, creates CP
bash workshop/deploy-rust-function.sh      # compile, create/update, publish version, wait, invoke
bash workshop/invoke.sh -g 50000           # 50K synthetic rows
bash workshop/invoke.sh -f data.csv        # send a CSV (max ~4 MB sync)
bash workshop/invoke-parallel.sh -c 10 -r 2000000   # load test: 10 concurrent x 2M rows
bash workshop/cleanup.sh                   # delete versions, function, CP, .env
```

Multi-tenancy module (needs the main CP Active and `LMI_VERSION` set):

```bash
bash workshop/setup-tenant-b.sh            # second CP + function on it
bash workshop/demo-isolation.sh            # saturate Tenant A, show Tenant B unaffected
bash workshop/setup-encrypted-cp.sh        # CP with KMS-encrypted EBS (needs alias/lmi-workshop-ebs-key)
bash workshop/cleanup-multi-tenancy.sh     # removes only tenant-b + encrypted resources
```

There is no test suite and no linter configured.

## Architecture Notes

**`workshop/.env` is the shared state between every script.** It is `chmod 600` and sourced with `set -a` at the top of each script. It holds account-specific VPC/subnet/role identifiers and there is no root `.gitignore` covering it, so don't commit it or paste its contents. Knowing who writes what matters:

| Key | Written by | Consumed by |
|---|---|---|
| `VPC_ID`, `SUBNET_IDS`, `SECURITY_GROUP_ID`, `OPERATOR_ROLE_ARN`, `EXECUTION_ROLE_ARN` | `setup-capacity-provider.sh` (`save_env`, **truncates** the file) | `setup-tenant-b.sh`, `setup-encrypted-cp.sh` |
| `CP_ARN` | `setup-capacity-provider.sh`, appended once the CP is Active | `deploy-rust-function.sh` |
| `LMI_VERSION` | `deploy-rust-function.sh`, sed-replaced in place after `publish-version` | `invoke.sh`, `invoke-parallel.sh`, `demo-isolation.sh` (default version) |
| `TENANT_B_VERSION` | `setup-tenant-b.sh` (sed-replace, else append) | `demo-isolation.sh`; deleted by `cleanup-multi-tenancy.sh` |

`SUBNET_IDS` is comma-separated with no brackets or spaces — scripts interpolate it as `SubnetIds=[$SUBNET_IDS]`. `setup-capacity-provider.sh` regex-validates every ID before writing.

`workshop/.env.example` documents all of the above; it is a template only, since the normal path is letting `setup-capacity-provider.sh` prompt for each value. `REGION` and `ACCOUNT_ID` appear there and in `WORKSHOP-MULTI-TENANCY.md`'s prerequisites, but **no script reads or writes them** — they are only for commands the reader copies by hand.

Scripts fail fast with a pointer to the prerequisite script when a key is missing (e.g. `deploy-rust-function.sh` aborts if `CP_ARN` is absent). `cleanup.sh` deletes the whole `.env`.

**Publishing a version is what launches EC2 instances.** `$LATEST` alone does not provision LMI capacity, so every invoke path uses a qualified `function:version`. Instances take 2–5 minutes to reach Active; the deploy script polls for this.

**Crate name ≠ deployed function name.** `Cargo.toml` declares `name = "lmi-workshop-function"`, so cargo-lambda emits `target/lambda/lmi-workshop-function/bootstrap.zip`, but the deployed Lambda is **`lmi-workshop-rust-function`**. Both names appear throughout the repo and mixing them up is the most common source of "function not found". (`demo-isolation.sh` currently has the wrong one hardcoded as `TENANT_A_FN`.)

**LMI concurrency model.** `main()` calls `run_concurrent(service_fn(handler))` — the handler must be `Clone + Send`, and each instance runs **8 async Tokio tasks per vCPU** (Python's runtime does 16, which is why the throttling numbers copied from the English docs don't transfer directly). vCPUs come from memory at a 2:1 ratio, set via `ExecutionEnvironmentMemoryGiBPerVCpu=2.0` in the capacity-provider config; the function is created at 2048 MB = 1 vCPU, 120 s timeout, `provided.al2023`, `arm64`. Scale by raising `--memory-size`; Polars parallelizes across the new vCPUs on its own. Unlike standard Lambda there is no 10 GB ceiling — the ceiling is `MaxVCpuCount` on the capacity provider (30 for the main CP, 16 for the multi-tenancy ones).

**Request flow in `main.rs`.** `Request { csv_base64, generate_rows }` — Base64 CSV takes precedence, otherwise `generate_flight_csv()` synthesizes rows (default 10,000). Then `parse_csv()` → three independent analysis stages (`compute_basic_stats`, `compute_flight_analysis`, `compute_advanced_operations`), each returning a `serde_json::Value` that becomes one field of `Response`. Adding an analysis stage means adding a function plus a field on `Response`; the stages do not depend on each other.

**The multi-tenancy scripts deploy Python 3.14 inline functions, not Rust.** They demonstrate that the *capacity provider* is the security boundary, so the workload language is irrelevant — they write a small `lambda_function.py`, zip it, and deploy. Don't "fix" them to use Rust.

**Graviton microarchitecture flags live in `rust-function/.cargo/config.toml`**, not in `Cargo.toml`: `target-cpu=neoverse-n1` for both the gnu and musl aarch64 triples. Default aarch64 codegen is baseline `armv8-a` (only `neon`); `neoverse-n1` is Graviton2 and adds `lse` atomics, which matter because `run_concurrent` has 8 Tokio tasks per vCPU contending on Polars' internal refcounts. Do **not** raise this to `neoverse-v2` unless the capacity provider's `InstanceRequirements` is also narrowed to Graviton4+ — the provider only asks for `Architectures=[arm64]` and Lambda mixes families, so a too-new `target-cpu` means intermittent SIGILL under scaling. Never `native` (compiles for the build host). Editing these flags forces a full rebuild of all ~292 crates.

**Release profile is tuned for size and speed** (`lto = "thin"`, `codegen-units = 1`, `panic = "abort"`, `strip = true`). `panic = "abort"` means a panicking task takes down the whole instance rather than failing one invocation — return `Err` instead of panicking in handler code.

## Cost Warning

LMI capacity providers run EC2 instances 24/7 for as long as they exist, regardless of invocation traffic. Always finish with `bash workshop/cleanup.sh` (plus `cleanup-multi-tenancy.sh` if that module was run), then verify no instances remain tagged with the provider name.
