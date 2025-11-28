# CycleCloud Monitoring with Azure Monitor for VMs and Prometheus

Start by deploying the monitoring infrastructure using the provided deployment script:
```bash
./infra/deploy.sh <monitoring_resource_group> 
```

## Configure CycleCloud Monitoring
To enable monitoring on your CycleCloud cluster, follow these steps:

- Add the tag `CycleCloudMonitoring` with value `enabled` for nodes and nodearrays in the CycleCloud cluster configuration.
- add `cyclecloud.monitoring.enabled = true` in the CycleCloud cluster configuration software section 
- run create_dcr.sh to create the Data Collection Rule (DCR) in Azure Monitor

```bash
  ./create_dcr.sh <ccw_resource_group> ccwLockerManagedIdentity
```
- run create_policies.sh to create the VM and VMSS policies to install the Azure Monitor Agent with the DCR
```bash
  ./create_policies.sh
```
- use update_dcr.sh to update the DCR if needed

## Troubleshooting
  - Check if the Agent is installed on the VM or VMSS
  - Check the resources of the DCR to see which one are assigned
  - Check if the UMI assigned to the VM or VMSS has the `Monitoring Metrics Publisher` role on the DCR
  - Check if the UMI client ID assigned to the VM or VMSS is in the assignment parameters of the DCR
  - Check if DCR is downloaded on the VM or VMSS : `ls /var/run/azuremetricsext/dcrs/`
    - `systemctl restart metrics-extension.service` will pull the new DCR if updated
  - `systemctl status metrics-extension.service`
  - `systemctl status azureotelcollector.service`
  - Check `journalctl -n 100 -u azureotelcollector.service`
  - `journalctl -n 500 -u metrics-extension | grep "Published metrics data"`
  - `cat /var/run/azureotelcollector/*.json`
  - For the Node Exporter : `curl -s http://localhost:9100/metrics` - available on all nodes
  - For the DCGM Exporter : `curl -s http://localhost:9400/metrics` - only available on VM type with NVidia GPU

## CycleCloud Cluster Pre-requisites
Need to apply add_publisher to the UMI used by VMs => run the add_publisher.sh script
Need to set the Upgrade Policy to Automatic in the Virtual Machines settings of the cluster => how to automate this ?
Need to add NodeTags CycleCloudMonitoring="enabled" in the CCW template

