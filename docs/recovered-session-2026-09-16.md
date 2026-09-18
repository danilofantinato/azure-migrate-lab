# Recovered Copilot Session: Azure Migrate Lab

This document reconstructs the interrupted VS Code Copilot session from the
local Chronicle index and raw Copilot event transcript. It is a
conversation-level recovery rather than a byte-for-byte Chat History export.
Long command output is condensed except for the final deployment failure.

## Recovery metadata

- Session ID: `a4be1e09-ad89-47da-8418-789048b99f83`
- Original title: `Bicep infrastructure as code setup`
- Session start: `2026-09-16T18:08:36.388Z`
- Last recovered conversation turn: `2026-09-16T23:49:37.814Z`
- Recovered conversation turns: 15
- Pending edits recorded by VS Code: none
- Deployment state at interruption: Azure validation was running in
  `centralus`; no deployment had started
- Password in recovered logs: masked
- Subscription IDs and public IP address in this document: redacted

The original Chat History file survived but contains zero requests, so VS Code
does not display it as a conversation. The raw event transcript remains at:

```text
%APPDATA%\Code\User\workspaceStorage\34c501c81409f44034fc6315865f4f57\GitHub.copilot-chat\transcripts\a4be1e09-ad89-47da-8418-789048b99f83.jsonl
```

## Recovered continuation point

The `westus3` preview failed because Azure lacked transient capacity for all
four requested VM sizes. The script correctly recommended `westus2`,
`centralus`, and `eastus2`. A retry using `centralus` passed local PowerShell
parsing and Bicep compilation, then entered the Azure validation gates. The
computer restarted before the validation result was recorded.

No resources were known to have been deployed. Before continuing, verify the
Azure deployment history and resource groups, then rerun validation rather
than assuming the interrupted process completed.

Intended retry command:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\deploy-lab.ps1 -Location centralus
```

## Recovered conversation

### Turn 1 - Initial infrastructure plan

**User:** Create Bicep infrastructure across two subscriptions in the same
tenant: one subscription simulates on-premises infrastructure and the other is
the Azure migration target. Parameterize VM sizes, minimize cost, and simulate
one Linux and one Windows physical machine. Ask follow-up questions and provide
an updated plan.

**Recovered result:** A draft two-subscription plan was produced. It selected
`westus3`, Windows Server 2022 and Ubuntu 22.04 LTS source VMs, IIS and Nginx
workloads, restricted public access for appliance VMs, secure deployment-time
credentials, and parameterized automatic shutdown. No files were changed.

### Turn 2 - Plan approval

**User:** Approved.

**Recovered result:** The Bicep lab was implemented with subscription-scope
orchestration, parameter files, documentation, a lab guide, a sizing worksheet,
and infrastructure planning metadata.

### Turn 3 - README deployment workflow

**User:** Improve the README so parameter setup and execution are simple and
copy-paste ready.

**Recovered result:** The README gained interactive setup, provider
registration, Bicep compilation, `what-if`, deployment, and password-cleanup
steps. PowerShell and Markdown validation passed; nothing was deployed.

### Turn 4 - Guided script proposal

**User:** The rendered README was still difficult to follow line by line.

**Recovered result:** A guided PowerShell deployment script was proposed, with
the README reduced to a one-command quick start and preview option.

### Turn 5 - Interactive parameters

**User:** Make PowerShell ask for parameters such as subscriptions while
providing defaults where possible, including the region.

**Recovered result:** `scripts/deploy-lab.ps1` was added or updated to prompt
for subscriptions and credentials, accept defaults for optional settings, run
compile and `what-if`, require `DEPLOY` confirmation, and clean temporary
values. Validation passed; nothing was deployed.

### Turn 6 - Azure sign-in

**User:** Does the user need to run `az login` before the deployment script?
Update it if necessary.

**Recovered result:** The script already checked Azure CLI authentication and
ran `az login` when required, so no README change was considered necessary.

### Turn 7 - SSH key workflow

**User:** Document `az login` anyway. Simplify SSH setup, offer to create a new
key, and place generated keys in an `ssh` folder.

**Recovered result:** Optional `az login` guidance was documented. The SSH
prompt defaulted to creating or reusing `ssh/azure-migrate-lab`, existing public
keys remained supported, passphrases stayed optional, generated keys were
ignored by Git, and `ssh/README.md` was added. Validation passed.

### Turn 8 - Preflight failure

**User:** Ran the script and supplied subscriptions, CIDR, generated SSH key,
regions, VM sizes, automatic-shutdown settings, and target NAT/Migrate options.
Azure Resource Manager validation later failed.

**Recovered result:** Pre-deployment checks were added for Azure Migrate
metadata-region support, requested VM-size availability, total regional vCPU
quota, VM-family quotas, ARM policy/template constraints, and final `what-if`.
Live checks confirmed `westus2` as a valid metadata region, rejected `westus3`
as a metadata region, and found 100 available vCPUs against 20 required.

### Turn 9 - Cache non-secret settings

**User:** Avoid asking for all parameters on every run by caching them in a
parameter file specific to the PowerShell script.

**Recovered result:** The proposed design used
`scripts/deploy-lab.local.json`, cached only non-secret values, let command-line
parameters override cached values, supported `-Reconfigure`, displayed loaded
settings, and never cached passwords or SSH passphrases.

### Turn 10 - Cache approval

**User:** Yes.

**Recovered result:** Local configuration caching was implemented. Normal runs
would ask only for the Windows administrator password and final `DEPLOY`
confirmation. Validation passed.

### Turn 11 - VM size recommendations

**User:** Confirm that preflight checks all four VM sizes and recommends other
regions when they are unavailable.

**Recovered result:** All four sizes and the combined regional/family quotas
were checked, but alternate-region recommendations were not yet implemented.
A same-geography region scan with up to three recommendations was proposed.

### Turn 12 - Recommendation approval

**User:** Yes.

**Recovered result:** Alternate-region scanning was implemented. Live checks
recommended `westus2`, `centralus`, and `eastus2`; each showed 100 available
vCPUs against 20 required.

### Turn 13 - Settings and provider handling

**User:** Reported another run in which cached settings were saved and resource
providers were registered, but additional changes were needed.

**Recovered result:** The script gained a `[U]se / [C]hange / [Q]uit` cached
settings prompt. Change mode re-prompted with current defaults. Provider
registration skipped providers already in the `Registered` state and verified
the final state. PowerShell, mocked prompt flows, provider tests, Bicep,
Markdown, and editor diagnostics passed.

### Turn 14 - West US 3 capacity failure

**User:** Reported that the script still did not work.

**Recovered result:** The settings/provider changes had worked. The actual
failure was transient VM capacity in `westus3`. The script was updated to
detect `SkuNotAvailable`, scan alternate regions, and print copy-ready retry
commands. The README was updated. Validation passed; no resources were
deployed and no commit was made.

### Turn 15 - Interrupted deployment attempt

**User:** Requested a working deployment and allowed a temporary password that
would be rotated later. The script loaded cached settings with these relevant
values:

```text
Location                   : westus3
MigrateProjectLocation     : westus2
NamePrefix                 : amiglab
AdminUsername              : labadmin
DiscoveryApplianceVmSize   : Standard_D8as_v5
ReplicationApplianceVmSize : Standard_F8s_v2
WindowsSourceVmSize        : Standard_B2ms
LinuxSourceVmSize          : Standard_B2s
AutoShutdownEnabled        : False
DeployTargetNatGateway     : True
DeployAzureMigrateProject  : True
```

Provider registration was already complete. Azure Migrate metadata validation
passed for `westus2`, and the preliminary quota check reported 20 required
vCPUs with 100 available in `westus3`. ARM preview then failed:

```text
InvalidTemplateDeployment
Microsoft.Compute/virtualMachines (2024-11-01) reported preflight errors.

SkuNotAvailable
Standard_D8as_v5, Standard_B2ms, Standard_B2s, and Standard_F8s_v2 were
currently unavailable in WestUS3 because of capacity restrictions.

Recommended compute regions:
- westus2: 100 vCPUs available
- centralus: 100 vCPUs available
- eastus2: 100 vCPUs available
```

**Recovered result:** A `centralus` retry passed PowerShell parsing and Bicep
compilation and was still running Azure validation. The last recovered agent
message was:

> Validation is still running in `centralus`; no resources have been deployed
> yet.

The restart occurred before a validation result or deployment confirmation was
captured.

## Files involved

- `README.md`
- `docs/lab-guide.md`
- `docs/sizing-experiment.md`
- `infra/main.bicep`
- `infra/main.bicepparam`
- `infra/modules/source-compute.bicep`
- `infra/modules/source-network.bicep`
- `infra/modules/source-subscription.bicep`
- `infra/modules/target-network.bicep`
- `infra/modules/target-subscription.bicep`
- `scripts/deploy-lab.ps1`
- `scripts/deploy-lab.local.json`
- `ssh/README.md`

## Recovery limitations

- VS Code cannot reopen the original conversation because its Chat History
  JSONL contains no requests.
- Chronicle preserved the 15 user/assistant turns used above.
- The separate raw transcript preserves event-level assistant messages and tool
  activity, but it is not directly importable into Chat History.
- Any terminal process running during the restart was terminated and cannot be
  resumed.