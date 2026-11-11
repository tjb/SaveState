// Tools in this repo import SaveStateBridgeKit alone and still get the client,
// AppDiscovery, and their errors, along with the SaveStateProtocol types
// SaveStateClientKit re-exports. Projects outside this repo import
// SaveStateClientKit directly, from the root package.
@_exported import SaveStateClientKit
