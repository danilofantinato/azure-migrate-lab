# Lab SSH Keys

The current nested Hyper-V architecture does not create or use SSH keys. Linux discovery and replication use password credentials generated for the nested guests during setup step 2.

The existing `azure-migrate-lab` and `azure-migrate-lab.pub` files are ignored legacy local artifacts from the former direct-Azure-source design. They are not read by the current scripts. Keep them private; this documentation update does not delete them.