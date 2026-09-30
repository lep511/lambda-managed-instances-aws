# LMI Rust Cost Calculator

A React web app that compares monthly costs between **Standard Lambda**, **Lambda Managed Instances (LMI)**, and **Self-Managed EC2** for Rust workloads running on Graviton (arm64).

Adapted from the [AWS Lambda Managed Instances sample calculator](https://github.com/aws-samples/sample-aws-lambda-managed-instances) — the original supports Python, Node.js, Java, and .NET. This version is Rust-only, with concurrency limits matching the `run_concurrent` Tokio runtime (default 8 tasks/vCPU).

## Quick Start

```bash
npm install
npm run dev
```

For production build:

```bash
npm run build
npm run preview
```

## What It Calculates

Given a workload profile (concurrency, memory, request volume, duration), the calculator computes:

- **Capacity plan**: instances needed, environments per instance, scaling buffer
- **11-column cost comparison table**: Standard Lambda (3 pricing tiers), LMI (5 tiers), Self-Managed EC2 (3 tiers)
- **Suitability score**: whether LMI is a good fit for the workload
- **Step-by-step methodology**: shows every calculation with formulas

## Supported Instance Types

The calculator includes all Graviton families that Lambda may assign to LMI capacity providers:

| Family | Generations | Type |
|--------|------------|------|
| c*g | c6g (Graviton2), c7g (Graviton3), c8g (Graviton4) | Compute Optimized |
| m*g | m6g (Graviton2), m7g (Graviton3), m8g (Graviton4), m9g (Graviton5) | General Purpose |
| r*g | r6g (Graviton2), r7g (Graviton3), r8g (Graviton4) | Memory Optimized |

Each family includes xlarge, 2xlarge, and 4xlarge sizes. Prices are for **us-east-1, Linux, On-Demand**.

> **Note**: Lambda chooses which instance type to provision — the capacity provider only specifies `Architectures=[arm64]`. The dropdown lets you estimate costs based on the family Lambda is likely to assign. Check your actual instances with `aws ec2 describe-instances --include-managed-resources`.

## Updating Instance Prices

Prices are hardcoded in `src/utils/calculator.js` in the `INSTANCE_TYPES` object. To update them, query the public AWS Pricing bulk data endpoint (no credentials required):

```bash
curl -s "https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonEC2/current/us-east-1/index.csv" \
  | grep '"m9g.xlarge"' \
  | grep '"Linux"' \
  | grep '"Shared"' \
  | grep '"NA"' \
  | grep '"Used"' \
  | head -1
```

The On-Demand hourly price is in column 10 (the value with many decimal places like `0.1956800000`). The CSV also includes Reserved Instance and Savings Plan prices in separate rows.

To extract all Graviton On-Demand prices at once:

```bash
curl -s "https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonEC2/current/us-east-1/index.csv" \
  | grep -E '"(c6g|c7g|c8g|m6g|m7g|m8g|m9g|r6g|r7g|r8g)\.(xlarge|2xlarge|4xlarge)"' \
  | grep '"Linux"' | grep '"Shared"' | grep '"NA"' | grep '"Used"' \
  | awk -F',' '{gsub(/"/, "", $20); gsub(/"/, "", $10); gsub(/"/, "", $23); gsub(/"/, "", $26); if ($10 ~ /^0\./) print $20, $23, $26, "$"$10"/hr"}' \
  | sort
```

The output shows: `instance_type vCPUs memory price/hr`. Update `INSTANCE_TYPES` in `calculator.js` with the new values.

Alternatively, use the **AWS Price List API** (requires `pricing:GetProducts` IAM permission):

```bash
aws pricing get-products \
  --service-code AmazonEC2 --region us-east-1 \
  --filters Type=TERM_MATCH,Field=instanceType,Value=m9g.xlarge \
            Type=TERM_MATCH,Field=location,Value="US East (N. Virginia)" \
            Type=TERM_MATCH,Field=operatingSystem,Value=Linux \
            Type=TERM_MATCH,Field=tenancy,Value=Shared \
            Type=TERM_MATCH,Field=preInstalledSw,Value=NA \
            Type=TERM_MATCH,Field=capacitystatus,Value=Used
```

## Tech Stack

- React 19 + Vite 7
- Zero third-party UI or charting libraries (hand-built SVG charts, plain CSS)
- AWS Console color palette (dark navy, action orange, info blue)
