# Linxi AI gateway on AWS

```
viewers ── CloudFront (+ WAF, us-east-1) ── ALB (CloudFront-only) ── ECS Fargate
                                                                      ├─ RDS PostgreSQL (Multi-AZ)
                                                                      ├─ ElastiCache Valkey (primary + replica)
                                                                      └─ NAT gateway + Elastic IP ── upstream providers
```

| Stack | Region | Template | Contents |
|---|---|---|---|
| `linxi-app` | `REGION` in `config.env` | `app-stack.yaml` | private subnets, NAT + fixed egress IP, security groups, ALB, ECS cluster and services, RDS, cache, secrets, logs |
| `linxi-edge` | us-east-1 | `edge-stack.yaml` | CloudFront distribution, WAF web ACL |

## Access control

- The ALB security group admits HTTPS only from the CloudFront origin-facing prefix list.
- The listener answers 403 unless the request carries the `X-Origin-Verify` secret that only this
  distribution sends, so other CloudFront distributions cannot reach it either.
- Tasks, database and cache sit in private subnets; each accepts traffic only from the tier in front of it.
- To admit extra office/partner IP ranges, add ingress rules to `AlbSg` and a listener rule for them.

## Timeouts

CloudFront waits `ORIGIN_READ_TIMEOUT` seconds (180, the account quota) for the first byte and
between packets. Streaming responses are unaffected as long as data keeps flowing; a non-streaming
request that takes longer than that to produce its first byte gets a 504 from CloudFront.
The ALB idle timeout is 900 s. For production, point the API hostname straight at the ALB.

## Nodes

`linxi-master` runs exactly one task (migrations, scheduled jobs). `linxi-slave` runs
`NODE_TYPE=slave` tasks and scales on CPU between `SlaveMinCount` and `SlaveMaxCount`.
Both register in the same target group.

## Usage

```bash
cp deploy/aws/config.env.example deploy/aws/config.env   # fill in
deploy/aws/deploy.sh all        # image -> app -> edge
deploy/aws/deploy.sh image && deploy/aws/deploy.sh app   # roll out a new commit
```

Secrets: database password, DSN, session and crypto secrets are generated in Secrets Manager
(`linxi/*`). The origin secret is generated into `deploy/aws/.origin-secret` (git-ignored).

## DNS

Point the public hostnames (CNAME) at the distribution domain printed by `deploy.sh edge`.
