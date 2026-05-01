# Runbook 03 — Restore from Backup

**Severity:** P2 — Recovery procedure  
**Owner:** Cloud Operations  
**Last reviewed:** 2026-05-01

---

## Trigger

One of:

- **Data corruption** detected on the workload instance (filesystem damage, accidental delete on `/var`).
- **Configuration drift** that cannot be reverted via redeploy (rare — most config is in SSM Parameter Store).
- **Disaster recovery test** — quarterly exercise to validate RPO/RTO targets.
- **Forensic investigation** — restore a point-in-time snapshot to a separate volume for analysis without touching the live workload.

## Prerequisites

- IAM permissions: `backup:StartRestoreJob`, `backup:DescribeRecoveryPoint`, `backup:ListRecoveryPointsByBackupVault`, `iam:PassRole` on the backup service role
- AWS CLI v2
- Console access to **AWS Backup** and **EC2 → Volumes**
- Recovery point ARN (from AWS Backup → Vault → Recovery points)

## Impact

- **No production impact** if restoring to a new volume (recommended path).
- **Service downtime** if replacing the live root volume — instance must be stopped and the volume detached/attached. Plan for ~10–15 minutes.
- **Cost:** restore from cold storage (>7 days old) takes longer and incurs retrieval cost. From warm storage, restore is near-instant.
- **RTO target:** 1 hour in-region (per `docs/backup-strategy.md`).

---

## Procedure

### Step 1 — Identify the recovery point

**Console:**

1. **AWS Backup → Backup vaults → `cloudops-dev-vault-platform` → Recovery points**.
2. Filter by **Resource type = EBS** and date range.
3. Note the **Recovery point ID** (begins with `arn:aws:backup:...:recovery-point:...`).
4. Confirm **Status = Completed** and **Encryption = `alias/cloudops-dev-cmk-platform`**.

**CLI:**

```bash
aws backup list-recovery-points-by-backup-vault \
  --backup-vault-name cloudops-dev-vault-platform \
  --by-resource-type EBS \
  --query 'sort_by(RecoveryPoints,&CreationDate)[-5:].[RecoveryPointArn,CreationDate,Status]' \
  --output table \
  --region us-east-1
```

### Step 2 — Decide the restore target

| Scenario | Target | Why |
|---|---|---|
| Forensic / test | **New EBS volume** in same AZ as live instance | No production impact |
| Replace corrupted root | **New EBS volume**, then swap | Faster than in-place restore |
| Full instance recovery | **New EC2 instance** from snapshot | Use ASG's existing AMI; restore data volume only if needed |

**For this workload** the root volume is ephemeral (state lives in SSM Parameter Store and the diagnostics bucket). Restore is rarely the right answer — usually `terraform apply` after a `golden-ami` rotation is faster. Prefer **new volume → forensic mount** unless you have a clear reason for in-place replacement.

### Step 3 — Start the restore (new volume)

**Console:**

1. **AWS Backup → Recovery points → select your point → Restore**.
2. **Restore role:** `cloudops-dev-role-aws-backup`.
3. **Restore options:**
   - **Volume type:** `gp3`
   - **Encryption:** `alias/cloudops-dev-cmk-platform`
   - **Availability Zone:** match live instance AZ (e.g. `us-east-1a`)
4. **Start restore job**.

**CLI:**

```bash
RP_ARN="arn:aws:backup:us-east-1:<account-id>:recovery-point:<id>"

aws backup start-restore-job \
  --recovery-point-arn $RP_ARN \
  --metadata '{"volumeType":"gp3","availabilityZone":"us-east-1a","encrypted":"true"}' \
  --iam-role-arn arn:aws:iam::<account-id>:role/cloudops-dev-role-aws-backup \
  --resource-type EBS \
  --region us-east-1
```

Note the returned `RestoreJobId`.

### Step 4 — Wait for the restore to complete

```bash
aws backup describe-restore-job \
  --restore-job-id <RestoreJobId> \
  --query '[Status,PercentDone,CreatedResourceArn]' \
  --output table \
  --region us-east-1
```

Loop every 60s until `Status = COMPLETED`. From warm storage: typically <5 min for a 30 GB volume.

### Step 5 — Mount and validate (forensic path)

1. **Console: EC2 → Volumes → select restored volume → Actions → Attach volume**. Attach to live instance as `/dev/sdf`.
2. SSM into the instance ([Runbook 01](01-access-instance-via-ssm.md)).
3. Mount and inspect:

   ```bash
   sudo mkdir -p /mnt/restore
   sudo mount -o ro /dev/nvme1n1 /mnt/restore  # nvme1n1 typical for /dev/sdf on Nitro
   ls /mnt/restore/var/log/
   ```

4. When done: `sudo umount /mnt/restore`, then **EC2 → Volumes → Detach → Delete**.

### Step 6 — Replace live root (only if Step 2 chose this path)

**Strongly prefer `terraform apply` with the latest Golden AMI over this path.**

1. **Stop the ASG instance:** ASG → Edit → Set `Desired = 0`. Wait until terminated.
2. **Detach old root** from the now-stopped placeholder (in practice the ASG already replaced it).
3. **Attach restored volume** as `/dev/xvda`.
4. **Set `Desired = 1`** on the ASG to launch a fresh instance using the Launch Template — but this **launches from the AMI, not the volume**. 
5. **Conclusion:** in this architecture, root-volume restore in-place is not the right primitive. Use AMI rotation ([Runbook 02](02-rotate-golden-ami.md)).

---

## Validation

1. Restore job status = `COMPLETED`.
2. New volume visible in **EC2 → Volumes** with correct size, type (`gp3`), encryption (`aws/cloudops-dev-cmk-platform`).
3. If mounted: filesystem readable, expected files present (e.g. `/var/log/messages`).
4. EventBridge rule `cloudops-dev-evt-backup-job-failed` did **not** fire (would have alerted via SNS).

## Rollback

- **Forensic mount:** unmount and delete the restored volume. No production impact.
- **In-place replacement:** revert by attaching the previous volume snapshot or running `terraform apply` with the current Golden AMI.

## Common failure modes

| Symptom | Likely cause | Fix |
|---|---|---|
| Restore job `FAILED` with `AccessDenied` | Backup service role missing KMS decrypt | Verify `cloudops-dev-role-aws-backup` has `kms:Decrypt` on the platform CMK |
| Restore is very slow | Recovery point is in cold storage (>7d old) | Expected — cold restores can take hours. For active recovery, use a warm point if available |
| Volume cannot attach | AZ mismatch | Restore to the same AZ as the target instance |
| Mount fails: `wrong fs type` | Volume is encrypted with a different key the kernel can't access | Confirm the instance role can `kms:Decrypt` on the CMK |

## Related

- [docs/backup-strategy.md](../docs/backup-strategy.md) — RPO/RTO, lifecycle, vault policy
- [Runbook 02 — Rotate Golden AMI](02-rotate-golden-ami.md) — preferred path for most "recovery" scenarios in this architecture
