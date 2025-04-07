#import "BLEAdvertiser.h"
@import CoreBluetooth;

@interface BLEAdvertiser ()
- (void)startAdvertising;
@end


@implementation BLEAdvertiser {
    CBCentralManager *centralManager;
    CBPeripheralManager *peripheralManager;
    int companyId; // Instance variable to store companyId
    // Store broadcast parameters
    NSString *pendingUid;
    NSArray *pendingPayload;
    NSDictionary *pendingOptions;
    RCTPromiseResolveBlock pendingResolve;
    RCTPromiseRejectBlock pendingReject;
}

- (dispatch_queue_t)methodQueue
{
    return dispatch_get_main_queue();
}

RCT_EXPORT_MODULE(BLEAdvertiser)

// Updated to include "onNativeLog" in supported events
- (NSArray<NSString *> *)supportedEvents {
    return @[@"onDeviceFound", @"onBTStatusChange", @"onNativeLog"];
}

// Helper method to log and send events
- (void)logAndSend:(NSString *)format, ... {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    RCTLogInfo(@"Native Log: %@", message); // Use RCTLogInfo for React Native debugging
    [self sendEventWithName:@"onNativeLog" body:@{@"message": message}];
}

RCT_EXPORT_METHOD(setCompanyId: (nonnull NSNumber *)companyIdNum){
    [self logAndSend:@"setCompanyId function called %@", companyIdNum];
    companyId = [companyIdNum intValue]; // Store the company ID (e.g., 0xFFFF)

    // Initialize managers if they don't exist yet
    if (!centralManager) {
        self->centralManager = [[CBCentralManager alloc] initWithDelegate:self queue:nil options:@{CBCentralManagerOptionShowPowerAlertKey: @(YES)}];
    }
    if (!peripheralManager) {
        self->peripheralManager = [[CBPeripheralManager alloc] initWithDelegate:self queue:nil options:nil];
    }
}

RCT_EXPORT_METHOD(broadcast: (NSString *)uid payload:(NSArray *)payloadArray options:(NSDictionary *)options
    resolve: (RCTPromiseResolveBlock)resolve
    rejecter:(RCTPromiseRejectBlock)reject){
    [self logAndSend:@"Broadcast function called %@ with payload %@", uid, payloadArray];

    if (!peripheralManager) {
        [self logAndSend:@"Peripheral manager not initialized before broadcast call."];
        reject(@"PeripheralManagerError", @"Peripheral manager not initialized", nil);
        return;
    }

    // Check if already broadcasting or pending
    if (pendingUid || pendingResolve) {
         [self logAndSend:@"Broadcast already in progress or pending."];
         reject(@"BroadcastInProgress", @"Another broadcast operation is already pending.", nil);
         return;
    }

    // Store parameters
    pendingUid = [uid copy];
    pendingPayload = [payloadArray copy];
    pendingOptions = [options copy];
    pendingResolve = [resolve copy];
    pendingReject = [reject copy];

    // Check state and start immediately if ready
    if (peripheralManager.state == CBManagerStatePoweredOn) {
        [self startAdvertising]; // Call the correctly defined method
    } else {
        [self logAndSend:@"Waiting for peripheral manager to be powered on... Current state: %ld", (long)peripheralManager.state];
        // The peripheralManagerDidUpdateState callback will call startAdvertising if it powers on
    }
}

// CORRECTED Method Definition (starts with '-')
- (void)startAdvertising {
    if (!pendingUid || !pendingPayload || !pendingResolve || !pendingReject) {
        [self logAndSend:@"Attempted to start advertising, but no pending parameters found."];
        // If this happens unexpectedly, it might indicate a logic error elsewhere.
        return;
    }

    // Convert payload array to NSData
    NSMutableData *payloadData = [NSMutableData data];
    for (NSNumber *byteNum in pendingPayload) {
        uint8_t byte = [byteNum unsignedCharValue];
        [payloadData appendBytes:&byte length:1];
    }

    // Create manufacturer data: companyId (2 bytes, little-endian) + payload
    uint16_t companyIdLE = OSSwapHostToLittleInt16(companyId); // Ensure little-endian for Bluetooth spec
    NSMutableData *manufacturerData = [NSMutableData dataWithBytes:&companyIdLE length:2];
    [manufacturerData appendData:payloadData];

    // --- Advertise ONLY Manufacturer Data to force it into the main packet ---
    NSDictionary *advertisingData = @{
        CBAdvertisementDataManufacturerDataKey : manufacturerData
        // CBAdvertisementDataServiceUUIDsKey : @[[CBUUID UUIDWithString:pendingUid]] // <-- Keep commented
    };
    // ---

    [self logAndSend:@"Attempting to start advertising with Manufacturer Data ONLY: %@", manufacturerData];
    [peripheralManager startAdvertising:advertisingData];

    // Store copies of the resolve/reject blocks to use inside the dispatch_after block
    RCTPromiseResolveBlock resolveBlock = [pendingResolve copy];
    RCTPromiseRejectBlock rejectBlock = [pendingReject copy];

    // Clear the original pending promises immediately after starting the advertising attempt
    pendingUid = nil;
    pendingPayload = nil;
    pendingOptions = nil;
    pendingResolve = nil;
    pendingReject = nil;


    // Check if advertising actually started after a short delay (0.5 seconds)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        // Use the captured resolve/reject blocks
        if (self->peripheralManager.isAdvertising) {
            [self logAndSend:@"Peripheral manager IS advertising."];
            if (resolveBlock) {
                 resolveBlock(@"Broadcasting (Manufacturer Data Only)"); // Fulfill the promise
            }
        } else {
            [self logAndSend:@"Peripheral manager IS NOT advertising (checked after 0.5s)."];
             if (rejectBlock) {
                 rejectBlock(@"AdvertisingStartFailed", @"Peripheral manager did not confirm advertising state after command.", nil); // Reject the promise
             }
        }
    });

} // <-- Closes the startAdvertising method


RCT_EXPORT_METHOD(stopBroadcast:(RCTPromiseResolveBlock)resolve
    rejecter:(RCTPromiseRejectBlock)reject){
    [self logAndSend:@"stopBroadcast function called"];
    if (peripheralManager) {
        if (peripheralManager.isAdvertising) {
             [peripheralManager stopAdvertising];
             [self logAndSend:@"Stopped advertising."];
        } else {
             [self logAndSend:@"Was not advertising, but called stop anyway."];
        }
        // Also clear any pending start operation that might not have completed
        if(pendingResolve || pendingReject) {
            [self logAndSend:@"Cleared pending broadcast promises during stop."];
            if (pendingReject) { // Reject any pending promise if we are stopping.
                 pendingReject(@"BroadcastStopped", @"Broadcast was stopped before completion.", nil);
            }
             pendingUid = nil; pendingPayload = nil; pendingOptions = nil; pendingResolve = nil; pendingReject = nil;
        }
        resolve(@"Stopping Broadcast Initiated"); // Resolve immediately
    } else {
        [self logAndSend:@"Peripheral manager not initialized during stopBroadcast call."];
        reject(@"PeripheralManagerError", @"Peripheral manager not initialized", nil);
    }
}

RCT_EXPORT_METHOD(scan: (NSArray *)payload options:(NSDictionary *)options
    resolve: (RCTPromiseResolveBlock)resolve
    rejecter:(RCTPromiseRejectBlock)reject){
    [self logAndSend:@"scan function called (Note: payload argument currently ignored on iOS scan)"];

    if (!centralManager) {
        [self logAndSend:@"Central manager not initialized before scan call."];
        reject(@"Device does not support Bluetooth", @"Adapter is Null", nil);
        return;
    }

    if (centralManager.state != CBManagerStatePoweredOn) {
         [self logAndSend:@"Scan attempted but Bluetooth is not powered on. State: %ld", (long)centralManager.state];
         NSString *stateStr;
         switch(centralManager.state) {
             case CBManagerStatePoweredOff:   stateStr = @"Powered off"; break;
             case CBManagerStateResetting:    stateStr = @"Resetting"; break;
             case CBManagerStateUnauthorized: stateStr = @"Unauthorized"; break;
             case CBManagerStateUnknown:      stateStr = @"Unknown"; break;
             case CBManagerStateUnsupported:  stateStr = @"Unsupported"; break;
             default: stateStr = @"Error"; break;
         }
         reject(@"BluetoothNotReady", [NSString stringWithFormat:@"Bluetooth not ON: %@", stateStr], nil);
         return;
    }

    [self logAndSend:@"Starting scan for all peripherals..."];
    [centralManager scanForPeripheralsWithServices:nil options:@{CBCentralManagerScanOptionAllowDuplicatesKey:[NSNumber numberWithBool:YES]}];
    resolve(@"Scanning Started");
}

RCT_EXPORT_METHOD(scanByService: (NSString *)uid options:(NSDictionary *)options
    resolve: (RCTPromiseResolveBlock)resolve
    rejecter:(RCTPromiseRejectBlock)reject){
    [self logAndSend:@"scanByService function called with UID %@", uid];

    if (!centralManager) {
        [self logAndSend:@"Central manager not initialized before scanByService call."];
        reject(@"Device does not support Bluetooth", @"Adapter is Null", nil);
        return;
    }

     if (centralManager.state != CBManagerStatePoweredOn) {
         [self logAndSend:@"scanByService attempted but Bluetooth is not powered on. State: %ld", (long)centralManager.state];
         NSString *stateStr;
         switch(centralManager.state) {
             case CBManagerStatePoweredOff:   stateStr = @"Powered off"; break;
             case CBManagerStateResetting:    stateStr = @"Resetting"; break;
             case CBManagerStateUnauthorized: stateStr = @"Unauthorized"; break;
             case CBManagerStateUnknown:      stateStr = @"Unknown"; break;
             case CBManagerStateUnsupported:  stateStr = @"Unsupported"; break;
             default: stateStr = @"Error"; break;
         }
         reject(@"BluetoothNotReady", [NSString stringWithFormat:@"Bluetooth not ON: %@", stateStr], nil);
         return;
    }

    CBUUID *serviceUUID = [CBUUID UUIDWithString:uid];
    if (!serviceUUID) {
        [self logAndSend:@"Invalid Service UUID format: %@", uid];
        reject(@"InvalidUUID", @"Invalid Service UUID format", nil);
        return;
    }

    [self logAndSend:@"Starting scan for service UUID: %@", uid];
    [centralManager scanForPeripheralsWithServices:@[serviceUUID] options:@{CBCentralManagerScanOptionAllowDuplicatesKey:[NSNumber numberWithBool:YES]}];
    resolve(@"Scanning by service Started");
}

RCT_EXPORT_METHOD(stopScan:(RCTPromiseResolveBlock)resolve
    rejecter:(RCTPromiseRejectBlock)reject){
    [self logAndSend:@"stopScan function called"];
    if (centralManager) {
        if (centralManager.isScanning) {
             [centralManager stopScan];
             [self logAndSend:@"Stopped scanning."];
        } else {
             [self logAndSend:@"Was not scanning, but called stopScan anyway."];
        }
        resolve(@"Stopping Scan Initiated");
    } else {
        [self logAndSend:@"Central manager not initialized during stopScan call."];
        reject(@"CentralManagerError", @"Central manager not initialized", nil);
    }
}

RCT_EXPORT_METHOD(enableAdapter){
    [self logAndSend:@"enableAdapter function called (No-op on iOS)"];
}

RCT_EXPORT_METHOD(disableAdapter){
    [self logAndSend:@"disableAdapter function called (No-op on iOS)"];
}

RCT_EXPORT_METHOD(getAdapterState:(RCTPromiseResolveBlock)resolve
    rejecter:(RCTPromiseRejectBlock)reject){
    [self logAndSend:@"getAdapterState function called"];

    if (!centralManager) {
        [self logAndSend:@"Central manager not initialized, cannot get state."];
        reject(@"CentralManagerError", @"Central manager not initialized", nil);
        return;
    }

    NSString *stateStr;
    switch (centralManager.state) {
        case CBManagerStatePoweredOn:       stateStr = @"STATE_ON"; break;
        case CBManagerStatePoweredOff:      stateStr = @"STATE_OFF"; break;
        case CBManagerStateResetting:       stateStr = @"STATE_TURNING_ON"; break;
        case CBManagerStateUnauthorized:    stateStr = @"STATE_OFF"; break;
        case CBManagerStateUnknown:         stateStr = @"STATE_OFF"; break;
        case CBManagerStateUnsupported:     stateStr = @"STATE_OFF"; break;
        default:                            stateStr = @"STATE_OFF"; break;
    }
    [self logAndSend:@"Adapter state determined as: %@", stateStr];
    resolve(stateStr);
}

RCT_EXPORT_METHOD(isActive:
     (RCTPromiseResolveBlock)resolve
    rejecter:(RCTPromiseRejectBlock)reject){
    [self logAndSend:@"isActive function called"];

    if (!centralManager) {
        [self logAndSend:@"Central manager not initialized, cannot determine active state."];
        reject(@"CentralManagerError", @"Central manager not initialized", nil);
        return;
    }

    BOOL isActive = ([centralManager state] == CBManagerStatePoweredOn);
    [self logAndSend:@"Adapter active status: %@", isActive ? @"YES" : @"NO"];
    resolve(@(isActive));
}


#pragma mark - CBCentralManagerDelegate Methods

-(void)centralManager:(CBCentralManager *)central didDiscoverPeripheral:(CBPeripheral *)peripheral advertisementData:(NSDictionary<NSString *,id> *)advertisementData RSSI:(NSNumber *)RSSI {
    // Optional: Log raw discovery data for debugging
    // [self logAndSend:@"Discovered Peripheral: Name: %@, ID: %@, RSSI: %@", [peripheral name], [[peripheral identifier] UUIDString], RSSI];
    // [self logAndSend:@"Advertisement Data: %@", advertisementData];

    NSMutableDictionary *params =  [[NSMutableDictionary alloc] init];
    NSMutableArray *serviceUUIDs = [[NSMutableArray alloc] init];

    // Extract Service UUIDs
    NSArray *uuidArray = advertisementData[CBAdvertisementDataServiceUUIDsKey];
    if ([uuidArray isKindOfClass:[NSArray class]]) {
        for (CBUUID *uuid in uuidArray) {
            [serviceUUIDs addObject:[uuid UUIDString]];
        }
    }

    // Extract Manufacturer Data
    NSData *manufData = advertisementData[CBAdvertisementDataManufacturerDataKey];
    if ([manufData isKindOfClass:[NSData class]] && manufData.length >= 2) {
        uint16_t discoveredCompanyId = 0;
        [manufData getBytes:&discoveredCompanyId length:2];
        discoveredCompanyId = OSSwapLittleToHostInt16(discoveredCompanyId);

        params[@"companyId"] = @(discoveredCompanyId);

        if (manufData.length > 2) {
             NSData *payloadBytes = [manufData subdataWithRange:NSMakeRange(2, manufData.length - 2)];
             NSMutableArray *payloadArray = [[NSMutableArray alloc] init];
             const uint8_t *bytes = [payloadBytes bytes];
             for (NSUInteger i = 0; i < [payloadBytes length]; i++) {
                 [payloadArray addObject:@(bytes[i])];
             }
             params[@"manufData"] = payloadArray;
        } else {
             params[@"manufData"] = @[];
        }
    } else {
         params[@"manufData"] = @[];
    }

    NSNumber *validRSSI = (RSSI && RSSI.intValue != 127) ? RSSI : nil;

    params[@"serviceUuids"] = serviceUUIDs;
    params[@"rssi"] = validRSSI ?: [NSNull null];
    params[@"deviceName"] = [peripheral name] ?: [NSNull null];
    params[@"deviceAddress"] = [[peripheral identifier] UUIDString];

    NSNumber *txPower = advertisementData[CBAdvertisementDataTxPowerLevelKey];
    params[@"txPower"] = txPower ?: [NSNull null];


    [self sendEventWithName:@"onDeviceFound" body:params];
}

-(void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral {
     [self logAndSend:@"Peripheral connected: %@", [[peripheral identifier] UUIDString]];
}

-(void)centralManager:(CBCentralManager *)central didFailToConnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
     [self logAndSend:@"Failed to connect to peripheral: %@, Error: %@", [[peripheral identifier] UUIDString], error.localizedDescription];
}

-(void)centralManager:(CBCentralManager *)central didDisconnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    [self logAndSend:@"Peripheral disconnected: %@, Error: %@", [[peripheral identifier] UUIDString], error ? error.localizedDescription : @"(No error)"];
}

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    [self logAndSend:@"Central manager state updated: %ld", (long)central.state];
    BOOL enabled = NO;
    switch (central.state) {
        case CBManagerStatePoweredOn:
            enabled = YES;
            [self logAndSend:@"Central Manager State: Powered ON"];
            break;
        case CBManagerStatePoweredOff:
             [self logAndSend:@"Central Manager State: Powered OFF"];
             if (central.isScanning) {
                 [central stopScan];
                 [self logAndSend:@"Stopped scan due to Bluetooth power off."];
             }
            break;
        case CBManagerStateResetting:
            [self logAndSend:@"Central Manager State: Resetting"];
            break;
        case CBManagerStateUnauthorized:
            [self logAndSend:@"Central Manager State: Unauthorized"];
            break;
        case CBManagerStateUnknown:
             [self logAndSend:@"Central Manager State: Unknown"];
            break;
        case CBManagerStateUnsupported:
             [self logAndSend:@"Central Manager State: Unsupported"];
            break;
        default:
            break;
    }
    [self sendEventWithName:@"onBTStatusChange" body:@{@"enabled": @(enabled)}];
}


#pragma mark - CBPeripheralManagerDelegate Methods

- (void)peripheralManagerDidUpdateState:(CBPeripheralManager *)peripheral
{
    [self logAndSend:@"Peripheral manager state updated: %ld", (long)peripheral.state];
    switch (peripheral.state) {
        case CBManagerStatePoweredOn:
            [self logAndSend:@"Peripheral Manager State: Powered ON"];
            // If there's a pending broadcast, start it now
            if (pendingUid && pendingResolve) {
                 [self logAndSend:@"Peripheral manager powered on, attempting to start pending broadcast."];
                 [self startAdvertising]; // Call the correctly defined method
            }
            break;

        case CBManagerStatePoweredOff:
        case CBManagerStateResetting:
        case CBManagerStateUnauthorized:
        case CBManagerStateUnsupported:
        case CBManagerStateUnknown:
             [self logAndSend:@"Peripheral Manager State: Not Powered On (%ld)", (long)peripheral.state];
             if (pendingReject) {
                 NSString *reason;
                  switch (peripheral.state) {
                     case CBManagerStatePoweredOff: reason = @"Bluetooth is powered off"; break;
                     case CBManagerStateResetting: reason = @"Bluetooth is resetting"; break;
                     case CBManagerStateUnauthorized: reason = @"Bluetooth permission denied"; break;
                     case CBManagerStateUnsupported: reason = @"Bluetooth LE not supported"; break;
                     default: reason = @"Bluetooth state unknown or unavailable"; break;
                 }
                 [self logAndSend:@"Rejecting pending broadcast due to peripheral state change: %@", reason];
                 pendingReject(@"BluetoothUnavailable", reason, nil);
                 pendingUid = nil; pendingPayload = nil; pendingOptions = nil; pendingResolve = nil; pendingReject = nil;
             }
            break;

        default:
            break;
    }
}

- (void)peripheralManagerDidStartAdvertising:(CBPeripheralManager *)peripheral error:(NSError *)error {
    if (error) {
        [self logAndSend:@"Failed to start advertising: %@", error.localizedDescription];
        // The promise is handled by dispatch_after in startAdvertising, just log here.
    } else {
        [self logAndSend:@"Successfully started advertising (confirmed by delegate callback)."];
        // The promise is handled by dispatch_after in startAdvertising.
    }
}


@end