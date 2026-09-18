# Assessment SKU Versus Migration SKU Experiment

## Purpose

Determine why an Azure Migrate assessment recommendation might differ from the VM size initially displayed by the replication or migration workflow. Record observations first and assign a cause only after testing the documented variables.

## Required Runs

Run the comparison at least twice for `source-win01`:

1. **Assessment-linked run:** Start execution by selecting the workload **From an assessment**.
2. **Direct-inventory run:** Start execution **From a replication appliance (Physical or Others)** when available.

Microsoft documents that an assessment-linked workflow shows the assessment-recommended size. Without an assessment, Azure Migrate selects a closest match in the target subscription. Record the portal behavior you actually observe.

## Assessment Baseline

| Setting | Recorded value |
| --- | --- |
| Assessment name |  |
| Creation timestamp and time zone |  |
| Target region | `westus3` |
| Environment type |  |
| Sizing criterion | Performance-based |
| Performance history |  |
| Percentile utilization |  |
| Comfort factor |  |
| Target VM families |  |
| Storage selection |  |
| Pricing offer or licensing setting |  |
| Assessment confidence |  |
| Missing-data warning |  |

## Per-Server Comparison

Create one row per source and per experiment run.

| Field | `source-win01` assessment-linked | `source-win01` direct-inventory | `source-linux01` assessment-linked | `source-linux01` direct-inventory |
| --- | --- | --- | --- | --- |
| Source machine name | `source-win01` | `source-win01` | `source-linux01` | `source-linux01` |
| Source vCPU |  |  |  |  |
| Source RAM |  |  |  |  |
| Source OS disk |  |  |  |  |
| Source data disks |  |  |  |  |
| CPU utilization and percentile |  |  |  |  |
| Memory utilization and percentile |  |  |  |  |
| Disk IOPS and throughput |  |  |  |  |
| Network activity |  |  |  |  |
| Data collection start/end |  |  |  |  |
| Assessment confidence |  |  |  |  |
| Assessment recommended SKU |  |  |  |  |
| Assessment recommended disks |  |  |  |  |
| Workload selection path | From an assessment | From replication appliance | From an assessment | From replication appliance |
| Initially displayed migration SKU |  |  |  |  |
| Initially displayed disk configuration |  |  |  |  |
| Manually selected migration SKU |  |  |  |  |
| Final migrated SKU |  |  |  |  |
| Target security type |  |  |  |  |
| Target availability option |  |  |  |  |
| Target subscription quota evidence |  |  |  |  |
| Target region SKU availability evidence |  |  |  |  |
| Result or blocking error |  |  |  |  |
| Notes |  |  |  |  |

## Controlled Assessment Variants

Keep source activity and collection window unchanged while varying one setting at a time.

| Variant | Performance history | Percentile | Comfort factor | VM family filter | Recommended SKU | Confidence |
| --- | --- | --- | --- | --- | --- | --- |
| A: baseline |  | 95th | 1.0 |  |  |  |
| B: higher comfort | Same as A | Same as A | 1.5 or next available value | Same as A |  |  |
| C: peak-sensitive | Same as A | 99th or highest available | 1.0 | Same as A |  |  |
| D: constrained family | Same as A | Same as A | Same as A | One selected family |  |  |
| E: longer history | Longer than A | Same as A | Same as A | Same as A |  |  |

## Hypothesis Checklist

Evaluate each hypothesis against captured evidence.

| Hypothesis | Evidence required | Supported, rejected, or inconclusive |
| --- | --- | --- |
| Replication did not use the assessment | Workload selection path and assessment association |  |
| Performance-based right-sizing reduced the source shape | Source shape, utilization percentiles, comfort factor, and recommendation calculation details |  |
| Performance data was missing or incomplete | Confidence rating, collection duration, and missing-data warnings |  |
| Target region did not offer the recommended SKU | Current `westus3` SKU availability result |  |
| Target subscription lacked quota | Regional and family quota result at the experiment timestamp |  |
| VM-family filters excluded the expected SKU | Assessment property export or screenshot |  |
| Security or availability settings constrained sizes | Selected security type, generation, zone, availability set, and eligible-size list |  |
| Disk requirements constrained sizes | Required disk count, size, IOPS, throughput, interface, and selected disk type |  |
| The workflow selected a closest source-configuration match | Direct-inventory path and initially displayed size |  |
| Operator changed the target size | Job history, notes, or screenshots before and after change |  |
| Marketplace-image limitation blocked the result | Migration error and current support-matrix statement |  |

## Evidence Capture

For every run, retain:

- Assessment properties and result export.
- Screenshots of the initial target Compute and Disks pages before edits.
- Azure Migrate job ID and timestamps.
- Current VM SKU availability and quota output.
- Source VM size and disk configuration from Azure Resource Manager.
- Source workload schedule and observed performance window.
- Final VM resource JSON if test or final migration creates a VM.
- Exact error text if the direct-Azure-VM limitation blocks migration.

Do not store passwords, SSH private keys, appliance keys, passphrases, or authentication codes with the evidence.

## Conclusion Template

```text
Observed difference:

Assessment-linked behavior:

Direct-inventory behavior:

Evidence-supported cause:

Rejected hypotheses:

Remaining uncertainty:

Effect of manual target-size selection:

Effect of the unsupported Azure-VM-as-physical source design:
```

## References

- [Physical-server migration target compute settings](https://learn.microsoft.com/azure/migrate/tutorial-migrate-physical-virtual-machines#execute-migrations)
- [Azure VM assessment calculation](https://learn.microsoft.com/azure/migrate/concepts-assessment-calculation)
- [Azure Migrate assessment best practices](https://learn.microsoft.com/azure/migrate/best-practices-assessment)
- [Physical migration support matrix](https://learn.microsoft.com/azure/migrate/migrate-support-matrix-physical-migration)