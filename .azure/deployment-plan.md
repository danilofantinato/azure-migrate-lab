# Azure Migrate Lab Deployment Plan

**Status:** Revalidation required after project-resource correction

## 1. Scope

Deploy the existing subscription-scope Bicep lab across two subscriptions in the same tenant:

- Source subscription: `SOURCE-SUBSCRIPTION-ID`
- Target subscription: `TARGET-SUBSCRIPTION-ID`
- Template: `infra/main.bicep`
- Parameters: `infra/main.bicepparam`
- Recipe: Azure CLI subscription deployment using Bicep

The source subscription hosts the simulated physical environment. The target subscription hosts the migration target network and a full Azure Migrate hub project with server assessment, discovery, and migration solutions.

## 2. Deployment Inputs

Non-secret inputs come from `scripts/deploy-lab.local.json`. The Windows administrator password is generated temporarily in process memory and is not written to disk. The SSH public key comes from the configured local public-key file.

## 3. Region Selection

Source and target locations are selected independently. Source compute defaults to `eastus2`, which passed subscription SKU, family quota, and ARM checks with current Dasv7 sizes. Target networking, Azure Migrate metadata, and migration setup default to supported region `westus2`. Preflight validates intended target workload SKUs and quota in the target subscription before deployment.

## 4. Validation Steps

1. Parse `scripts/deploy-lab.ps1` and compile `infra/main.bicep` and `infra/main.bicepparam`.
2. Confirm both subscriptions are enabled and no prior lab resource groups conflict.
3. Confirm source providers (`Compute`, `Network`, `DevTestLab`) and target providers (`Compute`, `Network`, `Storage`, `RecoveryServices`, `KeyVault`, `Migrate`) are registered.
4. Check source VM SKU visibility and vCPU quota in the selected source region and subscription.
5. Check intended migrated VM SKU visibility and vCPU quota in the selected target region and subscription.
6. Confirm the target region supports `Microsoft.Migrate/migrateProjects`.
7. Run Azure Resource Manager subscription deployment validation.
8. Run Azure Resource Manager subscription deployment what-if and require a successful result.
9. Review static Bicep role assignments and security-sensitive inputs.
10. Verify the `migrateProjects` resource and all three child solution contracts through ARM.

## 5. Deployment

After all validation steps pass, run one `az deployment sub create` operation in the validated region. Do not persist the temporary Windows password.

## 6. Post-Deployment Verification

1. Confirm the subscription deployment reaches `Succeeded`.
2. Confirm source and target resource groups exist in their intended subscriptions.
3. Confirm all four VMs, required disks, target subnets, and sample workloads are healthy.
4. Verify discovery and replication appliance health and registration without exposing secrets.
5. Verify project-linked migration resources after the guided portal checkpoint.

## 7. Validation Proof

The following proof was captured at `YYYY-MM-DDTHH:MM:SSZ` for the earlier
assessment-only project revision. Compute, networking, VM bootstrap, quota, and
provider evidence remains relevant; project-specific ARM validation must be
rerun after the current template is deployed.

- PowerShell parser: passed for `scripts/deploy-lab.ps1`.
- Bicep build: passed for `infra/main.bicep`.
- Bicep parameter build: passed for `infra/main.bicepparam`.
- Source and target subscription access: passed; both subscriptions are enabled in tenant `ENTRA-TENANT-ID`.
- Provider registration: the workflow now ensures `Microsoft.Compute`, `Microsoft.Network`, and `Microsoft.DevTestLab` in source; and `Microsoft.Compute`, `Microsoft.Network`, `Microsoft.Storage`, `Microsoft.RecoveryServices`, `Microsoft.KeyVault`, and `Microsoft.Migrate` in target before preflight.
- Candidate configuration: `eastus2`; discovery `Standard_D8as_v7`; replication `Standard_D16as_v7`; Windows and Linux sources `Standard_D2as_v7`.
- SKU properties: unrestricted x64 Gen2 sizes with Premium I/O; appliance and workload CPU/RAM minimums satisfied.
- Quota: total regional vCPUs `0/100`; Standard Dasv7 Family vCPUs `0/100`; deployment requires 28 vCPUs.
- ARM subscription validation: passed in `eastus2`.
- ARM subscription what-if: passed in `eastus2` with no Azure errors.
- Static security/RBAC review: administrator password uses `@secure()` through all Bicep module boundaries; no role assignments are introduced by this template.

## 8. Deployment Result

Deployment `azure-migrate-lab` succeeded at `YYYY-MM-DDTHH:MM:SSZ` in
`eastus2` with correlation ID `DEPLOYMENT-CORRELATION-ID`.

- The initial deployment failed because the Windows source data disk appeared
	as GPT with only a Microsoft Reserved partition. The bootstrap now waits for
	the disk and safely handles that state.
- The final subscription deployment completed in 70 seconds with no failed
	operations.
- All four source VMs were provisioned with the validated Dasv7 sizes.
- `ConfigureSourceWorkload` and `InitializeReplicationCache` reached
	`Succeeded`.
- Windows source validation passed: `LabData` mounted as `E:`, migration marker
	present, and IIS returned HTTP 200.
- Linux source validation passed: `/data` mounted, migration marker present,
	and Nginx returned a successful response.
- Azure Migrate assessment project `amig-example-unique-suffix` was provisioned
	successfully in `westus2`; this resource is superseded by the corrected full
	Azure Migrate project template.

## 9. Corrected Project Validation Gate

Before this plan returns to `Validated`, complete a clean deployment and run:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify-migrate-project.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-lab.ps1
```

The first command must report the project and all three server solutions as
ready. After the guided registration checkpoints, the second must report every
control-plane and guest check as passed.