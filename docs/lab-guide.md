# Azure Migrate Physical-Server Simulation Lab Guide

## 1. Architecture Overview

This lab uses two subscriptions in one Microsoft Entra tenant:

| Boundary | Purpose |
| --- | --- |
| Source subscription | Discovery appliance, simplified replication appliance, Windows Server 2022 Hyper-V host, and two nested source guests |
| Target subscription | Azure Migrate project, isolated test subnet, isolated final subnet, and resources created by Migration and modernization |

The simulated source environment uses `eastus2` by default. Target networking, Azure Migrate project metadata, and migration resources use supported region `westus2` by default. `SourceLocation` and `TargetLocation` can be selected independently; the target region remains shared by the target VNet, project, and region-locked Recovery Services vault.

The source and target VNets are not peered. The discovery appliance (`10.10.1.10`) and replication appliance (`10.10.1.20`) are separate Windows Server 2022 Azure VMs. A third Windows Server 2022 Azure VM at `10.10.2.10` is the Hyper-V host; it uses Standard security, NIC IP forwarding, and a 512-GB managed disk for nested guest VHDXs.

The host exposes two internal switches:

| Switch | Host address | Guest addresses | Purpose |
| --- | --- | --- | --- |
| `NestedRouted` | `10.10.3.1/24` | Windows `10.10.3.10`; Linux `10.10.3.20` | Discovery, inventory, Mobility Service push, and replication |
| `NestedNat` | `192.168.250.1/24` | Windows `192.168.250.10`; Linux `192.168.250.20` | Guest internet access through host WinNAT |

The appliance subnet has a user-defined route for `10.10.3.0/24` with virtual-appliance next hop `10.10.2.10`. The host forwards between Azure and `NestedRouted`. The guests use `NestedNat` only for outbound internet access. Azure IMDS `169.254.169.254` is blocked inside both guests, neither guest has Azure VM Agent, and neither should identify as an Azure VM.

> **Required disclaimer**
>
> This lab uses nested virtualization in Azure to simulate physical or other-cloud servers.
>
> The nested guests and routing arrangement are for testing and education. They are not a production source topology or a statement of support for nested virtualization in production migrations.
>
> It should not be interpreted as demonstrating Azure-to-Azure migration through Azure Migrate as a supported production migration architecture.
>
> The objective is to reproduce and understand the Azure Migrate discovery, assessment, Mobility Service, agent-based replication, test migration, and migration workflows normally associated with physical servers and servers running in other environments.

### Supported-outcome boundary

The source guests use ordinary Windows Server and Ubuntu installation media rather than Azure images. The former direct-Azure-image disk limitation is therefore not the expected boundary for this design. Discovery, assessment, Mobility Service, replication, test migration, and final migration remain subject to the current physical-server support matrices. Nested virtualization itself is only the lab simulation mechanism and does not represent a recommended production source topology.

## 2. Lab Prerequisites

### Azure permissions

- Permission to create subscription deployments and resource groups in both subscriptions.
- Permission to create networking, virtual machines, disks, public IPs, and schedules in the source subscription.
- Azure Migrate Owner or a higher role in the target subscription for Azure Migrate project creation and use.
- Permission to create VMs and write managed disks in the target subscription.
- Permission to register subscription features (`Microsoft.Features/*`) so setup can enable `Microsoft.Compute/UseStandardSecurityType` for the Standard-security Hyper-V host.
- Permission to register the simplified replication appliance in Microsoft Entra ID as documented by Microsoft.

Starting in November 2025, Microsoft requires Azure Migrate Owner or a higher privileged role to create new projects.

### Quota and tools

- Azure CLI and Bicep.
- At least 40 regional vCPUs in the source subscription across the relevant VM-family quotas, plus 4 target vCPUs for the initial migrated-workload sizing assumption.
- Availability of discovery `Standard_D8as_v7`, replication `Standard_D16as_v7`, and Hyper-V host `Standard_D16as_v7`, or validated fallback sizes selected by the deployment script. The replication VM requires at least eight physical cores; the host requires nested-virtualization support, at least 16 vCPUs, and 64 GB RAM.
- Secure storage for two separately displayed secrets: the Azure deployment password in step 1 and the nested guest password in step 2.
- One public administrator IPv4 CIDR, preferably `/32`.

The deployment script validates the selected region against subscription-aware
SKU restrictions plus regional and VM-family quota. If it is ineligible, the
script ranks same-geography alternatives by quota headroom and widens globally
only when the same geography has no eligible option. ARM validation and what-if
screen each presented candidate, but transient host capacity is confirmed only
when Azure allocates the VMs during deployment.

Unless VM sizes are explicitly overridden, the script tests the configured
profile and then Dasv7, Dasv6, and Dasv5 profiles against both selected regions.
It persists the first jointly eligible profile. Timestamped output shows each
SKU capability, quota row, validation phase, and final ARM operation state.

### Cost controls

Automatic shutdown defaults to 19:00 UTC. Disable or reschedule it while collecting performance data or replicating. VM deallocation stops compute billing but managed disks, public IPs, and NAT Gateways continue to incur charges.

## 3. Deploy the Simulated On-Premises Environment

**AUTOMATED**

Run the resumable setup from the repository root:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup-lab.ps1
```

Add `-ApproveDeployment` to that command to pre-approve the post-what-if
resource creation step. Both password acknowledgements and appliance registration
remain interactive.

It records non-secret progress in `scripts/setup-lab.state.local.json`, skips
completed stages on later runs, and pauses at discovery registration, migration
resource creation, and replication registration. Use `-Status` to inspect
progress or `-FromStep <name>` to rerun a selected stage.

The nine step names are `DeployInfrastructure`, `PrepareNestedGuests`, `VerifyProject`, `InstallDiscovery`, `RegisterDiscovery`, `CreateMigrationResources`, `InstallReplication`, `RegisterReplication`, and `ValidateLab`. `PrepareNestedGuests` is step 2.

Checkpoint output uses numbered actions and aligned tables. Read-only Azure
Migrate verification retries transient 429, timeout, internal-server, and HTTP
5xx responses with bounded exponential backoff; permanent failures are not
retried.

The commands below remain useful when validating or deploying Bicep separately.

Set the environment variables described in the repository README, then compile and preview:

```powershell
az bicep build --file infra/main.bicep

az account set --subscription $env:AZURE_MIGRATE_LAB_TARGET_SUBSCRIPTION_ID
az deployment sub what-if `
    --name azure-migrate-lab-preview `
    --location $env:AZURE_MIGRATE_LAB_TARGET_LOCATION `
    --template-file infra/main.bicep `
    --parameters infra/main.bicepparam
```

Review both subscription scopes in the what-if output. Deploy only after confirming that no unrelated resource will change.

At the end of the guided preview, `Resource changes: ...` is the what-if
summary, not a hang. The script then displays an action banner and waits for
`DEPLOY` or `CANCEL`. Blank or unrecognized input re-prompts. Cancellation
pauses `setup-lab.ps1` cleanly and can be resumed without resetting state.

The deployment creates:

- Appliance subnet `10.10.1.0/24`.
- Hyper-V host subnet `10.10.2.0/24`.
- Discovery appliance at `10.10.1.10`.
- Replication appliance at `10.10.1.20`.
- Hyper-V host at `10.10.2.10` with a static public IP for CIDR-restricted RDP, IP forwarding, and a 512-GB guest disk.
- UDR `10.10.3.0/24` to next hop `10.10.2.10` on the appliance subnet.
- Nested Windows source at routed `10.10.3.10` and NAT `192.168.250.10`.
- Nested Linux source at routed `10.10.3.20` and NAT `192.168.250.20`.
- Target test subnet `10.20.1.0/24`.
- Target final subnet `10.20.2.0/24`.

### Prepare nested guests independently

The primary setup runs this as step 2. To run it independently after infrastructure deployment:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
    -File .\scripts\prepare-hyperv-host.ps1 `
    -ConfigFile .\scripts\deploy-lab.local.json `
    -DeploymentName azure-migrate-lab
```

The script displays a separate one-time 24-character alphanumeric nested guest password and requires `READY` before launching provisioning. Both guest `labadmin` accounts and Linux `root` use this password. The deployment password from step 1 remains only for the Azure discovery appliance, replication appliance, and Hyper-V host.

Default public media:

- Microsoft Windows Server 2022 Evaluation through `https://go.microsoft.com/fwlink/p/?LinkID=2195280&clcid=0x409&culture=en-us&country=US`.
- Canonical Ubuntu 22.04 generic cloud image through `https://cloud-images.ubuntu.com/releases/jammy/release-20251031/ubuntu-22.04-server-cloudimg-amd64.img`. This dated image is pinned to stock kernel `5.15.0-161-generic`, supported by physical-server Mobility Service 9.66; kernel meta-packages are held for lab reproducibility.
- Windows qemu-img 2.3.0 package through `https://cloudbase.it/downloads/qemu-img-win-x64-2_3_0.zip`; the worker uses it to convert the generic qcow2 image to dynamic VHDX.

Override the HTTPS locations with `-WindowsServerIsoUri`, `-UbuntuCloudImageUri`, and `-QemuImgArchiveUri`. Their corresponding SHA256 parameters pin trusted content; the Ubuntu and qemu-img defaults are pinned. The old `UbuntuVhdArchive` parameter names remain aliases. Public URLs and redirect targets can drift, so verify the publisher, media or tool version, license, and hash when an endpoint changes. Windows Server Evaluation is time-limited evaluation software governed by Microsoft's evaluation license and is not a production license.

An already-ready host is skipped. Use `-Force` only when intentionally rebuilding after reviewing host state; nested artifacts can be recreated. The remote provisioning task and caller both use an eight-hour limit by default; adjust the caller with `-ProvisioningTimeoutHours` when needed.

## 4. Source Servers

**AUTOMATED**

| Machine | Default shape | Disks | Sample workload |
| --- | --- | --- | --- |
| `source-win01` | Nested generation 2 VM | VHDX files on the host guest disk | IIS and the Windows migration marker |
| `source-linux01` | Nested generation 2 VM | VHDX files on the host guest disk | Nginx and `/data/lab-data/migration-marker.txt` |

The Windows guest enables WinRM, WMI, File and Printer Sharing, and the local-account token policy required for Windows push installation. Its firewall scopes appliance access to the routed path. To enforce WinRM HTTPS 5986, install a valid Server Authentication certificate whose common name matches the host. Microsoft states that the certificate must not be expired, revoked, or self-signed.

The Linux guest enables password SSH and SFTP for `labadmin` and `root`. Both use the one-time nested guest password shown during step 2. The Windows guest `labadmin` account uses that same nested guest password. The password is not written to configuration, status, result output, or repository files. Using a shared lab password is an isolated-lab convenience, not a production credential pattern.

The guests have two NICs. Their default route uses `NestedNat` and host WinNAT for internet access; their `10.10.3.0/24` adapters provide the appliance-facing route without a default gateway. IMDS is blackholed and blocked. Do not install Azure VM Agent in either guest and do not attempt Azure Run Command against them.

### Optional performance activity

Run activity inside the source operating systems. Do not inject metrics into Azure Migrate.

Examples include:

- Repeatedly request the local IIS or Nginx page.
- Copy a test file to and from the data disk.
- Run a time-bounded CPU or memory test approved for the operating system.
- Record the start and stop time of every workload so it can be compared with collected metrics.

## 5. Azure Migrate Project

**AUTOMATED, WITH VALIDATION GATE**

By default, Bicep creates `Microsoft.Migrate/migrateProjects@2020-05-01`
in `westus2` with a system-assigned managed identity and the three server solutions used by Microsoft's project
quickstart:

- `Servers-Assessment-ServerAssessment`
- `Servers-Discovery-ServerDiscovery`
- `Servers-Migration-ServerMigration`

Verify the project independently:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify-migrate-project.ps1
```

The verifier resolves the project ID from deployment outputs, reads the project
and child solutions through ARM, validates their tool/purpose/goal/status
contracts, and prints a direct portal link. After deployment:

1. Open Azure Migrate in the target subscription.
2. Confirm that the project appears under **All projects**.
3. Confirm the project geography is United States and metadata is stored in a supported region.
4. Confirm Discovery and assessment plus Migration and modernization are available.

**AUTOMATION BOUNDARY**

The project key, migration setup resources, and registration actions are runtime artifacts and are not stored in Bicep or source control. The supported physical discovery package can be installed remotely after infrastructure deployment, but project registration remains interactive.

## 6. Discovery Appliance

**AUTOMATED INFRASTRUCTURE**

The VM meets the documented physical discovery appliance minimum: Windows Server 2022, 8 vCPUs, 32 GB RAM, and more than 80 GB of disk space.

**AUTOMATED SOFTWARE INSTALLATION**

From the repository root, run:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-discovery-appliance.ps1
```

The script resolves the source resource group and discovery VM from the
`azure-migrate-lab` deployment outputs. It uses Azure VM Run Command rather
than public WinRM, downloads the official physical appliance package, verifies
its pinned SHA256 and Microsoft Authenticode signatures, and invokes:

```powershell
.\AzureMigrateInstaller.ps1 `
    -Scenario Physical `
    -Cloud Public `
    -PrivateEndpoint:$false
```

It then verifies the appliance registry state, IIS, and the local TCP 44368
listener. From the administrator workstation it also tests that the public
endpoint is reachable through the CIDR-restricted NSG rule.

The expected package hash is pinned in the script so a changed package cannot
run silently. If Microsoft releases an update, verify its hash from an official
source and supply it with `-ExpectedSha256`. A healthy installation is skipped;
use `-Force` only after reviewing the logs under `C:\AzureMigrateSetup` on the
discovery VM.

Healthy existing appliances still receive pinned Microsoft Configuration
Manager and Auto Update component updates. Each MSI requires its expected
SHA256 and a valid Microsoft Authenticode signature. A local marker makes the
update idempotent. Use `-SkipComponentUpdates` only for diagnosis. An HTTP 401
from `graph.windows.net` confirms endpoint reachability; refresh Configuration
Manager and rerun prerequisites after updates or a required reboot.

**MANUAL REGISTRATION STEP**

1. In the project, select **Discover** for servers.
2. Select the scenario for **Physical or other (AWS, GCP, Xen, etc.)**.
3. Generate the project key.
4. Open the appliance configuration manager at `https://<appliance-address>:44368`.
5. Complete prerequisite, time synchronization, update, and outbound connectivity checks.
6. Paste the project key and complete device-code Azure authentication.

Do not install replication-appliance components on this VM.

## 7. Physical and Other-Server Discovery

**MANUAL AZURE MIGRATE STEP**

Add source credentials to the discovery appliance configuration manager:

| Source | Lab credential | Minimum discovery permission |
| --- | --- | --- |
| Windows | Local `labadmin`; nested guest password entered interactively | Administrator is simplest; Microsoft also documents a least-privileged account using Remote Management Users, Performance Monitor Users, Performance Log Users, and required WMI namespace access |
| Linux | Local `labadmin`; nested guest password entered interactively | Standard non-sudo access supports software inventory; additional sudo permissions are required for some dependency features |

Credentials remain encrypted on the appliance and are not sent to Microsoft. Never commit the nested guest password.

Add these private addresses:

- `10.10.3.10` for `source-win01`.
- `10.10.3.20` for `source-linux01`.

Add them as **Physical or other servers**, start discovery, and wait for both machines to appear in the project. The appliance reaches `10.10.3.0/24` through the UDR and Hyper-V host. For physical discovery, configuration metadata is collected approximately every three hours and performance data approximately every five minutes.

## 8. Software Inventory

**MANUAL AZURE MIGRATE STEP**

1. Confirm valid source credentials remain associated with both machines.
2. Wait for the software inventory cycle, which is approximately once every 24 hours.
3. Open each discovered machine and inspect installed applications, roles, and features.
4. Confirm Windows reports IIS-related roles and Linux reports Nginx packages.

Windows inventory uses PowerShell remoting and WMI over 5985 or 5986. Linux inventory uses SSH 22 and standard package/query commands. SQL discovery is not enabled by this lab because no SQL Server instance is installed.

## 9. Performance Data Collection

**MANUAL AZURE MIGRATE STEP**

1. Disable automatic shutdown or move the schedule outside the observation window.
2. Keep the Hyper-V host, both nested source guests, and the discovery appliance running.
3. Run documented source-side workload activity.
4. Collect at least 24 hours for an initial experiment; use a longer history for stronger confidence.
5. Record missing intervals, shutdowns, workload windows, and configuration changes.

Do not start a sizing comparison until the portal shows enough performance samples for both machines.

## 10. Azure VM Assessment

**MANUAL AZURE MIGRATE STEP**

For the first migration experiment, assess only `source-win01`. Windows Mobility Service push installation is the shortest path for validating the assessment-to-replication handoff.

1. Open **Explore inventory > All inventory** and confirm `source-win01` appears under the physical discovery appliance.
2. Open **Decide and plan > Assessments**.
3. Select **Assess > Azure VM**.
4. Set **Discovery source** to **Servers discovered from Azure Migrate appliance**.
5. Select **Edit** for assessment properties and configure:

    | Property | Baseline value |
    | --- | --- |
    | Target location | Configured `TargetLocation`: **West US 2** (`westus2`) by default |
    | Sizing criteria | **Performance-based** |
    | Performance history | **1 day** |
    | Percentile utilization | **95th percentile** |
    | Comfort factor | **1.0** |
    | Storage type | **Automatic** |
    | VM series | Leave broad enough for genuine right-sizing |

6. Name the assessment `amiglab-windows-rightsize`.
7. Create group `amiglab-windows`, select the physical discovery appliance, and add `source-win01`.
8. Review the settings and select **Create assessment**.
9. Wait for calculation to complete, then open the assessment and record:
    - Azure readiness and any readiness issues.
    - Recommended Azure VM size and disk types.
    - Monthly compute and storage estimate.
    - Performance coverage rating.

The assessment target must match configured `TargetLocation` (`westus2` in this lab), not source region `eastus2`, because sizing, availability, and pricing recommendations are calculated for the intended migration target.

A one-day performance assessment needs approximately one complete day of collected CPU, memory, disk, and network samples. Low coverage can produce unreliable sizing. Keep the discovery appliance and source VM running, generate representative activity, wait for collection, and recalculate before treating the recommendation as right-sized.

Portal labels and available assessment options can evolve. Record the displayed option rather than mapping it to an older name.

## 11. Assessment Sizing

Assessment follows this logical path:

`Discovery > Performance collection > Assessment settings > Right-sizing > Recommended VM SKU and disks`

Repeat the assessment with controlled changes:

| Variant | Change | Expected observation |
| --- | --- | --- |
| Baseline | 95th percentile, comfort 1.0 | Reference recommendation |
| Higher confidence buffer | Increase comfort factor | Recommendation can increase |
| Peak-sensitive | Increase percentile | Recommendation can increase when peaks exist |
| Constrained family | Limit target VM families | Recommendation changes or readiness issues appear |
| Longer history | Extend performance history | Confidence and recommendation can change |

The recommendation becomes the initial migration configuration only when execution starts with **From an assessment** and that assessment is selected. Record the recommendation before execution and compare it with the size displayed in the migration wizard; do not silently change it during the baseline experiment.

## 12. Simplified Replication Appliance

**AUTOMATED INFRASTRUCTURE**

The dedicated replication VM uses `Standard_D16as_v7`: Windows Server 2022, 8 physical cores/16 vCPUs, 64 GB RAM, a 128-GB OS disk, and a 640-GB `E:` cache disk. The larger SKU is required because `Standard_D8as_v7` exposes only four physical cores even though it has eight logical processors. The base VM has no IIS or Hyper-V role configured; the Microsoft installer adds its required web components.

**AUTOMATED SOFTWARE INSTALLATION**

From the repository root, run:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
    -File .\scripts\install-replication-appliance.ps1 `
    -ConfigFile .\scripts\deploy-lab.local.json
```

The script resolves the replication VM from the `azure-migrate-lab`
deployment outputs and uses Azure VM Run Command. Before downloading anything,
it checks the host OS/locale, CPU/RAM, `E:` cache volume, static private IP,
prohibited roles, FIPS and group policies, pending reboot state, Edge, and free
space. It downloads the approximately 4-GB Microsoft package with `curl.exe`,
verifies the pinned SHA256 and Microsoft PowerShell signatures, and runs the
signed `DRInstaller.ps1` without accepting any appliance key or source
credential.

A healthy existing installation is reported as `AlreadyInstalled`. A partial
installation requires an explicit `-Force` repair after log review. If a reboot
is required, the script asks for `RESTART` approval and resumes health checks
after the VM Agent returns. Logs and the cached package are kept under
`C:\AzureMigrateReplicationSetup` on the replication VM.

**MANUAL AZURE MIGRATE REGISTRATION**

1. In the Azure Migrate project, open **Execute > Migrations > Start execution**.
2. Select **Servers or virtual machines (VMs)** and **Azure VM**.
3. Select **From all inventory**, then select the registered **Physical** discovery appliance.
4. In the red **No replication appliance is registered to this project** message, select **Click here to set up**.
5. Verify **Target region** matches `TargetLocation` (`West US 2` by default). Stop if another region is displayed.
6. Select **Generate key**, wait for the key, and copy it to secure temporary storage.
7. Return to `setup-lab.ps1` and enter `MIGRATION KEY GENERATED`.
8. After the replication appliance software is installed, RDP to it through its CIDR-restricted public IP.
9. Open Microsoft Azure Appliance Configuration Manager locally.
10. Complete the prerequisite and component checks, then select **Continue**.
11. Under **Select Replication appliance connectivity**, select **FQDN**. Keep the detected appliance name `amig-repl` and the default replication traffic port `9443`, then select **Save** and **Continue**.
12. Do not select **NAT IP**. The source servers reach the replication appliance over the private routed path through Hyper-V host `10.10.2.10`; the appliance public IP is restricted to RDP and does not expose replication ports.
13. Enter a friendly appliance name, paste the generated simplified replication appliance key, and select **Login**.
14. Complete device-code Microsoft Entra authentication within the code expiration window.
15. Verify the displayed target subscription, resource group, and Recovery Services vault, then select **Continue**.
16. Under **Provide Physical server details**, add the following replication credentials. Discovery-appliance credentials are not copied to the replication appliance.

    | Friendly name | Type | Username | Password |
    | --- | --- | --- | --- |
    | `labwindows` | Windows Server | `labadmin` | Nested guest password from step 2 |
    | `lablinuxroot` | Linux password-based | `root` | Nested guest password from step 2 |

17. Add the source servers and associate each replication credential:

    | VM | Private IP | Credential |
    | --- | --- | --- |
    | `source-win01` | `10.10.3.10` | `labwindows` |
    | `source-linux01` | `10.10.3.20` | `lablinuxroot` |

18. Wait for both server validations to pass, then select **Continue**. Do not select **I will add Physical server details later** when completing the full replication lab.
19. After **Completed appliance configuration successfully** appears, return to Azure Migrate and refresh the migration experience. Do not expect the replication appliance on **Manage > Appliances** or the project-level **Manage > Infrastructure servers** blade; those views do not list this Site Recovery provider.
20. For the authoritative registration view, open the generated Recovery Services vault and inspect **Site Recovery infrastructure** for the connected replication provider. The provider uses the friendly machine name entered during registration, not Azure VM resource name `vm-<prefix>-repl-<suffix>`.

The FQDN or NAT IP choice is permanent for the appliance. In this lab, Azure-provided VNet DNS resolves `amig-repl` to its private address `10.10.1.20`. Source Mobility Service traffic reaches that appliance on TCP 443 for control and TCP 9443 for replication data from `10.10.3.0/24`, routed through host `10.10.2.10`.

The discovery appliance inventory remains the source for assessment and sizing. The replication appliance requires separate server entries because it owns Mobility Service installation and replication; Azure Migrate does not transfer stored guest credentials between appliances.

When `setup-lab.ps1` resumes this checkpoint, it verifies project MSI and a
Recovery Services vault in the configured migration target region. It later
reruns the replication appliance health check and queries the vault for a
connected `InMageRcm` provider. Azure-side verification reports the provider
name, connection state, fabric health, and last heartbeat. It retries briefly
while newly registered provider state propagates to Azure. A successful check
requires an `InMageRcm` provider with connection state `Connected`; local
registry flags are not treated as authoritative registration evidence.

Do not use the classic replication appliance. New agent-based replications must use the simplified experience.

## 13. Mobility Service

Mobility Service is installed inside each source machine. It captures changed data and sends it to the process server on the replication appliance.

### Windows push installation

**AUTOMATED PREREQUISITES, MANUAL AZURE MIGRATE STEP**

The replication appliance reaches routed guest subnet `10.10.3.0/24` through Hyper-V host `10.10.2.10`. The network path permits TCP 135, 445, 5985, 5986, and dynamic RPC range 49152-65535. WMI/DCOM first connects to endpoint mapper TCP 135 and then negotiates a high RPC port, so allowing 135 alone is insufficient. Windows Firewall rules for WMI, File and Printer Sharing, and Public-profile WinRM are enabled for the appliance path. `LocalAccountTokenFilterPolicy=1` permits remote administration with the local `labadmin` account.

In the replication appliance configuration manager, add the Windows local administrator credential. During **Enable replication**, select that credential so the appliance can perform the supported push installation.

### Linux push installation

**AUTOMATED PREREQUISITES, MANUAL AZURE MIGRATE STEP**

Linux push requires the built-in root account, SSH, SFTP, password authentication, Secure Boot disabled, a hostname-to-routed-IP entry in `/etc/hosts`, and a kernel explicitly supported by the installed Mobility Service version. Nested guest provisioning disables Secure Boot, configures root/password SSH, and adds the `10.10.3.20 source-linux01` mapping. In Appliance Configuration Manager, use the `lablinuxroot` credential for `source-linux01`; during **Enable replication**, select that credential for Mobility Service push installation.

Do not assume that every Ubuntu kernel is compatible. Record `uname -r` and compare it with the support matrix for the Mobility Service version installed by the current replication appliance. Recheck the matrix whenever the appliance package or guest kernel changes.

Using a shared Windows administrator/Linux root password is limited to this isolated lab. Production environments should use distinct, rotated credentials and a secret-management workflow.

## 14. Enable Replication

**MANUAL AZURE MIGRATE STEP**

1. Open **Execute > Migrations** and select **Start execution**.
2. Under **Specify intent**, select **Servers or virtual machines (VMs)** and target **Azure VM**.
3. Under **How will you select workloads**, choose **From an assessment**.
4. In **Discovery method**, select the physical Azure Migrate discovery appliance.
5. Select assessment `amiglab-windows-rightsize`, then select `source-win01`.
6. Select the connected simplified replication appliance and Windows credential `labwindows`.
7. Configure the target:

    | Property | Value |
    | --- | --- |
    | Subscription | Target subscription from `deploy-lab.local.json` |
    | Region | Configured `TargetLocation`: **West US 2** in this lab |
    | Resource group | Generated `rg-<prefix>-target-<suffix>` resource group |
    | Virtual network | Generated target VNet |
    | Subnet | `snet-final` |

8. Record the automatically displayed VM size before changing anything and compare it with the assessment recommendation.
9. For the baseline experiment, do not manually change the recommended VM size.
10. Review target VM security type, availability option, OS disk, replicated data disks, disk types, NIC, and tags.
11. Select **Review and start execution**, then start replication.

If enable replication fails before Mobility Service installation completes:

1. Open the failed **Enable replication** job and inspect the failed **Installing Mobility Service and enabling replication** task. The outer machine error can hide the actionable inner error.
2. Correct the prerequisite; do not recreate the discovery assessment.
3. If **Retry** or **Restart** is available on the failed job, use it after validation.
4. If a partial protected item remains or the machine page requests cleanup, select **Disable protection**, wait for cleanup to complete, and then start execution again with **From an assessment** and the same assessment.
5. Confirm the Mobility Service is installed and initial replication starts before proceeding to test migration.

Use **From a replication appliance (Physical or Others)** only for a separate direct-inventory comparison. That path does not prove assessment handoff and may choose a closest available target size. Do not mix its result with the assessment-linked baseline.

## 15. Replication Monitoring

**MANUAL AZURE MIGRATE STEP**

Monitor **Execute > Migrations** using workload or application view.

| Stage | What to verify |
| --- | --- |
| Preparation | Start replication job succeeded and initial replication is progressing |
| Testing | Initial replication completed and delta replication is active |
| Completion | Test migration is completed or skipped and final migration is available |

Record job IDs, timestamps, appliance health, Mobility Service version, bytes replicated, and any warning or error. Inside the nested source guests, verify the agent is running and can reach replication appliance TCP 443 and 9443 through the routed path.

The replication appliance is represented in Azure by a Recovery Services provider. Absence from project **Appliances** or project-level **Infrastructure servers** does not mean registration failed. Validate provider connection state and heartbeat in the generated Recovery Services vault.

## 16. Test Migration

**MANUAL AZURE MIGRATE STEP**

1. Wait until initial replication completes and delta replication is active.
2. Select the server under **Execute > Migrations**.
3. Under **Testing**, select **Start test migration**.
4. Select the target VNet and `snet-test`.
5. Start and monitor the test migration job.
6. Confirm the source continues operating and replication continues.
7. Validate the target VM:
   - Boot diagnostics and operating-system health.
   - Expected OS and data disks.
   - Correct NIC and `snet-test` placement.
   - IIS or Nginx starts.
   - Migration marker exists on the data disk.
   - VM size matches the selected replication configuration.
8. Record any guest OS, kernel, disk, boot, or Mobility Service compatibility error exactly.
9. Select **Clean up test migration** when validation is complete.

The migrated target is an Azure VM, so Azure Run Command can be used there when appropriate. The target subnet has no inbound administration rule; alternatively use an existing approved private management path or a temporary tightly restricted management configuration that is removed after testing. Never use Azure Run Command as a validation method for the nested source guests because they have no Azure VM Agent.

## 17. Final Migration

**MANUAL AZURE MIGRATE STEP**

Perform final migration separately from test migration:

1. Confirm the latest replication recovery point and resolve all health warnings.
2. Confirm the selected final VM size, disk types, final VNet, and `snet-final`.
3. Select **Migrate** under **Completion**.
4. For a planned migration, select the option to shut down the source and perform an on-demand synchronization with no data loss.
5. Monitor the migration job until the target VM is created.
6. Validate boot, disks, NIC, application, data, connectivity, and selected VM size.
7. Cut over application traffic only after acceptance testing.
8. Select **Complete migration** to stop replication and clean up replication state.

Do not delete the nested source guests or their Hyper-V host until the experiment results and target validation are complete.

## 18. Assessment SKU Versus Migration SKU Experiment

Use the [sizing experiment worksheet](sizing-experiment.md).

For each source, capture:

- Source vCPU, RAM, disks, and observed utilization.
- Assessment settings, confidence, recommended VM size, and recommended disks.
- Whether replication started from the assessment or direct appliance inventory.
- Initially displayed migration VM size.
- Manually selected migration size, if changed.
- Final created VM size, if migration reaches that point.

Investigate differences against recorded evidence: source configuration, assessment settings, missing data, confidence, region, family availability, quota, security type, disk constraints, and workflow selection. Do not assign a cause without evidence.

## 19. Troubleshooting

| Symptom | Checks |
| --- | --- |
| Project does not appear | Confirm target subscription, `Microsoft.Migrate` registration, Azure Migrate Owner role, supported target location (`westus2` by default), and Bicep deployment state; fall back to documented portal creation |
| Discovery appliance prerequisite fails | Confirm Windows Server 2022, 8 vCPUs, 32 GB RAM, disk space, English locale, time sync, supported TLS, and required outbound URLs |
| Windows discovery fails | Test private TCP 5985/5986, WinRM service, WMI, credential rights, UAC filtering, and certificate validity when enforcing HTTPS |
| Linux discovery fails | Test private TCP 22 to `10.10.3.20`, SSH service, password authentication, required shell commands, routed return path, and appliance credential mapping |
| Software inventory is empty | Wait at least one 24-hour cycle; verify credentials, PowerShell remoting/WMI, SSH, package tools, and machine discovery health |
| Assessment confidence is low | Increase collection duration; check shutdown gaps, missing counters, source reachability, and appliance health |
| Replication appliance setup fails | Confirm 8 physical CPU cores, 16 GB RAM, Windows Server 2022 English locale, 80-GB OS minimum, 620-GB data minimum, no prohibited roles, group policies, time sync, and required URLs |
| Replication appliance is absent from project Appliances/Infrastructure servers | This is expected for the Site Recovery provider. Open the generated Recovery Services vault > Site Recovery infrastructure and verify the `InMageRcm` provider is `Connected` with a recent heartbeat |
| Windows error `322001` followed by `539` | Verify admin credential and `LocalAccountTokenFilterPolicy=1`; confirm process-server access to TCP 135, 445, and 5985; allow dynamic RPC TCP 49152-65535 from replication appliance `10.10.1.20/32`; enable/scoped WMI, File Sharing, and Public WinRM firewall rules |
| Linux errors `327141`, `327217`, and `539` (outer error can be `310056`) | Compare `uname -r` with the Mobility Service support matrix for the installed appliance version; verify root password SSH, SFTP, the `10.10.3.20 source-linux01` mapping, routed return path, and TCP 22 |
| Linux error `327215` | Disable Secure Boot on the nested Linux VM, restart it, and retry enable replication. Secure Boot is unsupported for physical-server Mobility Service replication. |
| Windows push installation fails without `322001` | Verify admin credential, LocalAccountTokenFilterPolicy, File and Printer Sharing, WMI/DCOM, TCP 135/445/5985 and dynamic RPC, antivirus exclusions, and free space |
| Linux push installation fails without `327217` | Verify the `lablinuxroot` credential, effective `PermitRootLogin yes` and `PasswordAuthentication yes`, SSH/SFTP on TCP 22, hostname mapping, free space, OpenSSH/OpenSSL packages, and supported OS/kernel |
| Nested guests are unreachable | On the host, verify both VMs are running, both internal switches exist, routed-interface forwarding is enabled, each guest has two NICs, the UDR points `10.10.3.0/24` to `10.10.2.10`, and guest firewalls permit the appliance paths |
| Mobility Service cannot replicate | Test source-to-appliance TCP 443 and 9443, appliance health, configuration file, agent version, antivirus exclusions, and required Key Vault/service URLs |
| Migration SKU differs | Compare assessment linkage, confidence, settings, target family filters, region availability, target quota, security type, disk constraints, and closest-match behavior |
| Test or final migration fails | Inspect the exact job task and validate current physical-server OS, kernel, disk, firmware, network, and Mobility Service support before treating the result as an appliance defect |

Use Azure Network Watcher connection troubleshooting and VM boot diagnostics where appropriate. Preserve job IDs and appliance logs before cleanup.

## 20. Cleanup

**MANUAL AZURE MIGRATE STEP**

1. Clean up every test migration.
2. Complete or stop active migrations and replication.
3. Remove source machines from the replication appliance inventory when appropriate.
4. On the replication appliance, run:

   ```powershell
   pwsh -NoProfile -ExecutionPolicy Bypass `
       -File .\UnregisterApplianceFromAzure.ps1
   ```

   The script refuses to continue while protected replication items remain. It
   removes only the mappings, container, provider, and eligible fabric that
   match the local appliance registry and `Appliance.json`.
5. Remove any remaining discovery-appliance registration and project-generated
   migration resources by following current portal guidance.
6. Confirm no retained replica disks, snapshots, cache storage, Recovery Services vault items, or target VMs are needed.

Do not delete the lab resource groups while replication or a test migration is active. Clean up test migrations and stop or complete replication first.

**AZURE RESOURCE CLEANUP**

Preview the exact cleanup inventory:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
    -File .\scripts\remove-lab.ps1 `
    -WhatIf
```

After migration state is clean, delete the two deployment-output resource
groups. Include linked migration resources outside the target resource group
only when they should also be removed:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
    -File .\scripts\remove-lab.ps1 `
    -IncludeLinkedMigrationResources `
    -RemoveResourceLocks `
    -ResetLocalState
```

The script uses exact deployment output IDs, shows the inventory first, rejects
`NetworkWatcherRG`, and requires typing `DELETE LAB`. It never discovers groups
by a broad name prefix. It retains resource locks by default; use
`-RemoveResourceLocks` to remove only lock IDs validated beneath the exact lab
resource-group scopes. It removes exact root and nested subscription deployment
history after deleting resources, including when the resource groups are already
absent. Use `-KeepDeploymentHistory` to preserve history. Deleting a deployment
record alone never deletes resources. `-ResetLocalState` also removes the local
setup state, cached deployment answers, and generated ARM JSON after Azure cleanup.

Deleting the source resource group deletes the Hyper-V host and its attached 512-GB guest disk. Both nested guest VHDXs are stored on that disk and are deleted with it.

Run live validation before cleanup when you need a final evidence record:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-lab.ps1
```

The validator confirms exactly three source-side Azure VMs and their expected disks, both discovered assessment machines through the assessment-project machine API, a connected `InMageRcm` provider, and local appliance health. It invokes Azure Run Command only on the Azure VMs. On the Hyper-V host it verifies nested provisioning status, both running guests, `NestedRouted` and `NestedNat`, routed-interface forwarding, two NICs per guest, TCP 5985 to Windows, TCP 22 to Linux, and both sample web pages. It never invokes Azure Run Command against a nested guest.

## Verified Microsoft References

- [Azure Migrate appliance requirements and URLs](https://learn.microsoft.com/azure/migrate/migrate-appliance)
- [Physical discovery and assessment support matrix](https://learn.microsoft.com/azure/migrate/migrate-support-matrix-physical)
- [Discover physical servers](https://learn.microsoft.com/azure/migrate/tutorial-discover-physical)
- [Assessment calculation](https://learn.microsoft.com/azure/migrate/concepts-assessment-calculation)
- [Simplified agent-based experience](https://learn.microsoft.com/azure/migrate/simplified-experience-for-azure-migrate)
- [Physical-server migration tutorial](https://learn.microsoft.com/azure/migrate/tutorial-migrate-physical-virtual-machines)
- [Agent-based migration architecture and ports](https://learn.microsoft.com/azure/migrate/agent-based-migration-architecture)
- [Modernized replication appliance support matrix and URLs](https://learn.microsoft.com/azure/site-recovery/replication-appliance-support-matrix)
- [Mobility Service overview and modernized manual installation](https://learn.microsoft.com/azure/site-recovery/vmware-physical-mobility-service-overview)
- [Mobility Service push prerequisites](https://learn.microsoft.com/azure/site-recovery/vmware-azure-install-mobility-service)
- [Physical migration support matrix](https://learn.microsoft.com/azure/migrate/migrate-support-matrix-physical-migration)
- [Azure Migrate supported geographies](https://learn.microsoft.com/azure/migrate/supported-geographies)
- [Azure Migrate project quickstart template](https://github.com/Azure/azure-quickstart-templates/tree/master/quickstarts/microsoft.migrate/migrate-project-create)