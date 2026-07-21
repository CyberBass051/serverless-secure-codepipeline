The README Opening Section (The Pitch)
Markdown
# Secure & Resilient AWS CI/CD Orchestrator

## Overview
This repository contains a production-style, event-driven CI/CD pipeline built from scratch on AWS. Moving away from standard native polling, this architecture uses a secure **Lambda-powered webhook gatekeeper** to validate incoming GitHub events via **HMAC SHA-256 signatures** before programmatically triggering **AWS CodePipeline**. 

Designed with enterprise DevOps principles in mind, it includes automated failure notifications, manual approval gating, and a fully documented operational postmortem demonstrating real-world incident management.

---

## Architecture Flow

```mermaid
graph TD
    A[GitHub Push / PR] -->|Webhook + HMAC Header| B(API Gateway)
    B -->|Payload| C[Lambda: HMAC Verification]
    C -->|Valid Token| D[AWS CodePipeline]
    D --> E[AWS CodeBuild: Test & Build]
    E --> F{Manual Approval Gate}
    F -->|Triggered| G[Amazon EventBridge]
    G -->|State Change| H[Amazon SNS / Slack Alert]
    H -->|Approve/Reject| I[Production Deploy]
Tech Stack & Key Components
Compute / Security: AWS Lambda (Python/Node.js) handling cryptographic signature verification.

Orchestration: AWS CodePipeline & AWS CodeBuild (buildspec.yml).

Event Routing: Amazon EventBridge (capturing pipeline states and manual approval requests).

Observability / Alerting: Amazon SNS (routing approval links and failure alerts).

Infrastructure as Code: [Terraform / AWS CDK - choose your tool] for repeatable, version-controlled provisioning.

Key DevOps Highlights
Secure Ingress: Bypasses native polling by using an API Gateway + Lambda pattern to enforce strict HMAC payload validation against secrets stored securely in AWS Secrets Manager.

Gated Deployments: Integrates manual approval gates for production stages, reducing the risk of unauthorized or accidental releases.

Observability & Incident Response: Employs EventBridge to react instantly to pipeline failures and approval needs, paired with a documented Incident Postmortem tracking a deliberate deployment failure and automated recovery.

Chaos Engineering & Failure Recovery
To prove operational readiness, this repository includes a documented failure scenario where a breaking configuration was intentionally introduced. Check out the Postmortem Document for a deep dive into MTTD (Mean Time to Detection), Root Cause Analysis (RCA), and remediation steps.
