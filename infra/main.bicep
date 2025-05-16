targetScope = 'resourceGroup'

param location string
param userObjectId string

var uniqueId = uniqueString(az.resourceGroup().id)

module managedMonitoring 'managedMonitoring.bicep' = {
  name: 'managedMonitoring'
  params: {
    location: location
    monitorName: 'ccw-mon-${uniqueId}'
    grafanaName: 'ccw-graf-${uniqueId}'
    principalUserId: userObjectId
  }
}

output ingestionEndpoint string = managedMonitoring.outputs.metricsIngestionEndpoint
output dcrResourceId string = managedMonitoring.outputs.dcrResourceId
output grafanaName string = managedMonitoring.outputs.grafanaName
