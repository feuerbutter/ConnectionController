#import <NetworkExtension/NWEndpoint.h>

// Give Swift an unambiguous name for the legacy ObjC endpoint. New SDKs
// re-export Network.NWEndpoint from NetworkExtension, making its name collide.
@compatibility_alias CMLegacyEndpoint NWEndpoint;
