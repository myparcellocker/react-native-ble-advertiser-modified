#import "BLEAdvertiser.h"
@import CoreBluetooth;

// Declare private methods in a class extension
@interface BLEAdvertiser ()
- (void)startAdvertisingInternal; // Renamed internal helper
- (void)stopAdvertisingInternalAndReject:(NSString *)code message:(NSString *)message error:(NSError *)error; // Helper to stop and cleanup promises
- (void)cleanupPendingBroadcast:(BOOL)shouldReject code:(NSString *)code message:(NSString *)message error:(NSError *)error; // Helper to clear promise vars
@end
// End of class extension

@implementation BLEAdvertiser {
    CBCentralManager *centralManager; // For scanning state/permissions
    CBPeripheralManager *peripheralManager; // For advertising

    int companyId;

    // State for Advertising
    BOOL isTryingToAdvertise; // Flag: Are we currently *supposed* to be advertising?
    NSDictionary *currentAdvertisingData; // Data we are trying to advertise
    RCTPromiseResolveBlock pendingAdResolve; // Promise for the current/pending startAdvertising call
    RCTPromiseRejectBlock pendingAdReject;   // Promise for the current/pending startAdvertising call
}

- (dispatch_queue_t)methodQueue
{
    // Ensure CoreBluetooth calls happen on the main thread
    return dispatch_get_main_queue();
}

RCT_EXPORT_MODULE(BLEAdvertiser)

- (NSArray<NSString *> *)supportedEvents {
    return @[@"onDeviceFound", @"onBTStatusChange", @"onNativeLog"];
}

// Helper method to log and send events
- (void)logAndSend:(NSString *)format, ... {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    RCTLogInfo(@"Native Log: %@", message);
    [self sendEventWithName:@"onNativeLog" body:@{@"message": message}];
}

// Ensure managers are initialized when the module loads (or lazily)
- (instancetype)init {
    self = [super init];
    if (self) {
        // Initialize flags
        isTryingToAdvertise = NO;
        // Initialize managers lazily or here - doing it here for simplicity
         if (!centralManager) {
            centralManager = [[CBCentralManager alloc] initWithDelegate:self queue:dispatch_get_main_queue() options:@{CBCentralManagerOptionShowPowerAlertKey: @(NO)}]; // Use main queue, hide default power alert
         }
         if (!peripheralManager) {
            peripheralManager = [[CBPeripheralManager alloc] initWithDelegate:self queue:dispatch_get_main_queue() options:nil]; // Use main queue
         }
    }
    return self;
}

// Invalidate managers on dealloc
- (void)invalidate {
     [self logAndSend:@"Module invalidating."];
     if (peripheralManager && peripheralManager.isAdvertising) {
         [peripheralManager stopAdvertising];
     }
     // Setting delegates to nil is important to prevent crashes if callbacks occur after dealloc
     if (centralManager) {
         centralManager.delegate = nil;
         centralManager = nil;
     }
      if (peripheralManager) {
         peripheralManager.delegate = nil;
         peripheralManager = nil;
     }
     [self cleanupPendingBroadcast:YES code:@"ModuleInvalidated" message:@"Module resources released." error:nil];
}


RCT_EXPORT_METHOD(setCompanyId: (nonnull NSNumber *)companyIdNum){
    [self logAndSend:@"setCompanyId function called %@", companyIdNum];
    companyId = [companyIdNum intValue];
    // Managers are initialized in init now
}

RCT_EXPORT_METHOD(broadcast: (NSString *)uid // uid is not used for manufacturer data, but kept for API consistency
                  payload:(NSArray *)payloadArray
                  options:(NSDictionary *)options // options are currently ignored on iOS
                  resolve: (RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject){
    [self logAndSend:@"broadcast called with payload: %@", payloadArray];

    // Reject if managers aren't initialized (shouldn't happen with init method)
    if (!peripheralManager) {
        [self logAndSend:@"ERROR: Peripheral manager nil in broadcast"];
        reject(@"PeripheralManagerError", @"Peripheral manager not initialized", nil);
        return;
    }

    // Reject if already trying to advertise or have a pending promise
    if (isTryingToAdvertise || pendingAdResolve || pendingAdReject) {
        [self logAndSend:@"Warning: Broadcast called while another operation is pending or active."];
        reject(@"BroadcastPending", @"Another broadcast operation is already active or pending.", nil);
        return;
    }

    // --- Prepare Data ---
    NSMutableData *payloadData = [NSMutableData data];
    for (NSNumber *byteNum in payloadArray) {
        uint8_t byte = [byteNum unsignedCharValue];
        [payloadData appendBytes:&byte length:1];
    }
    uint16_t companyIdLE = OSSwapHostToLittleInt16(companyId);
    NSMutableData *manufacturerData = [NSMutableData dataWithBytes:&companyIdLE length:2];
    [manufacturerData appendData:payloadData];

    // Store the data we *intend* to advertise
    currentAdvertisingData = @{
        CBAdvertisementDataManufacturerDataKey : manufacturerData
        // Optional: Add local name later if needed and space allows
        // CBAdvertisementDataLocalNameKey : @"MyDeviceName"
    };
    // --- End Prepare Data ---

    // Store the promise callbacks
    pendingAdResolve = [resolve copy];
    pendingAdReject = [reject copy];
    isTryingToAdvertise = YES; // Set the flag *before* checking state

    [self logAndSend:@"Data prepared, checking peripheral state..."];

    // Check state and attempt to start *immediately* if ready
    if (peripheralManager.state == CBManagerStatePoweredOn) {
        [self logAndSend:@"Peripheral is Powered ON. Attempting to start advertising..."];
        [self startAdvertisingInternal];
    } else {
        [self logAndSend:@"Peripheral is NOT Powered ON (State: %ld). Waiting for state update.", (long)peripheralManager.state];
        // Advertising will be started by peripheralManagerDidUpdateState when it powers on
        // The promise remains pending.
    }
}

// Internal helper to actually call startAdvertising
- (void)startAdvertisingInternal {
    if (!isTryingToAdvertise || !currentAdvertisingData) {
        [self logAndSend:@"startAdvertisingInternal called but not trying to advertise or no data. Ignoring."];
        return;
    }

    // Check state again just in case
    if (peripheralManager.state != CBManagerStatePoweredOn) {
        [self logAndSend:@"startAdvertisingInternal: State is not Powered ON (%ld). Aborting.", (long)peripheralManager.state];
        // We might need to reject the promise here if the state changed between the initial check and now
        [self cleanupPendingBroadcast:YES code:@"BluetoothNotReady" message:@"Bluetooth powered off before advertising could start." error:nil];
        isTryingToAdvertise = NO;
        currentAdvertisingData = nil;
        return;
    }

    [self logAndSend:@"Calling [peripheralManager startAdvertising:%@]", currentAdvertisingData];
    // THE ACTUAL CALL TO START ADVERTISING
    [peripheralManager startAdvertising:currentAdvertisingData];
    // --- IMPORTANT: DO NOT resolve the promise here. Wait for the delegate callback. ---
}

RCT_EXPORT_METHOD(stopBroadcast:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject){
    [self logAndSend:@"stopBroadcast called."];
    // We don't need rejecter here, stop is usually fire-and-forget success
    [self stopAdvertisingInternalAndReject:nil message:nil error:nil]; // Stop advertising, don't reject any pending *start* promise
    resolve(@"Stop broadcast requested."); // Resolve immediately that the stop *request* was processed
}

// Internal helper to stop advertising and potentially reject a pending START promise
- (void)stopAdvertisingInternalAndReject:(NSString *)code message:(NSString *)message error:(NSError *)error {
    BOOL wasTryingToAdvertise = isTryingToAdvertise;
    isTryingToAdvertise = NO; // Clear the intention flag *first*
    currentAdvertisingData = nil;

    if (peripheralManager && peripheralManager.isAdvertising) {
        [self logAndSend:@"Stopping active advertising."];
        [peripheralManager stopAdvertising];
    } else {
         [self logAndSend:@"Stop requested, but peripheral manager was not advertising."];
    }

    // If we were trying to start, and are now stopping, reject the pending promise if rejection details provided
    if (wasTryingToAdvertise && code) {
        [self cleanupPendingBroadcast:YES code:code message:message error:error];
    } else {
        // Otherwise, just clear any leftover promise vars without rejecting
        [self cleanupPendingBroadcast:NO code:nil message:nil error:nil];
    }
}

// Helper to clear out promise variables, optionally rejecting
- (void)cleanupPendingBroadcast:(BOOL)shouldReject code:(NSString *)code message:(NSString *)message error:(NSError *)error {
    if (shouldReject && pendingAdReject) {
        [self logAndSend:@"Rejecting pending broadcast promise. Code: %@, Message: %@", code, message];
        pendingAdReject(code, message, error);
    } else if (pendingAdResolve) {
        // This case should ideally not happen if cleanup is called correctly,
        // but ensures resolve isn't left hanging if reject wasn't called.
         [self logAndSend:@"Warning: Cleaning up pending resolve block without explicit resolution."];
    }
    pendingAdResolve = nil;
    pendingAdReject = nil;
}


#pragma mark - CBPeripheralManagerDelegate Methods

- (void)peripheralManagerDidUpdateState:(CBPeripheralManager *)peripheral {
    [self logAndSend:@"Peripheral Manager State Updated: %ld", (long)peripheral.state];

    switch (peripheral.state) {
        case CBManagerStatePoweredOn:
            [self logAndSend:@"State: Powered ON."];
            // If we *intend* to be advertising, try starting now
            if (isTryingToAdvertise) {
                [self logAndSend:@"Powered ON and should be advertising, attempting start..."];
                [self startAdvertisingInternal];
            }
            break;

        // Handle all non-powered-on states
        case CBManagerStatePoweredOff:
        case CBManagerStateResetting:
        case CBManagerStateUnauthorized:
        case CBManagerStateUnsupported:
        case CBManagerStateUnknown:
            [self logAndSend:@"State: Not Powered ON (%ld).", (long)peripheral.state];
            // If we were trying to advertise, it has implicitly stopped or failed to start.
            // Reject any pending START promise.
            if (isTryingToAdvertise) {
                NSString *reason;
                NSString *code;
                 switch (peripheral.state) {
                    case CBManagerStatePoweredOff: reason = @"Bluetooth is powered off"; code = @"BluetoothPoweredOff"; break;
                    case CBManagerStateResetting: reason = @"Bluetooth is resetting"; code = @"BluetoothResetting"; break;
                    case CBManagerStateUnauthorized: reason = @"Bluetooth permission denied"; code = @"BluetoothUnauthorized"; break;
                    case CBManagerStateUnsupported: reason = @"Bluetooth LE not supported"; code = @"BluetoothUnsupported"; break;
                    default: reason = @"Bluetooth state unknown or unavailable"; code = @"BluetoothUnknown"; break;
                }
                 [self logAndSend:@"Rejecting pending broadcast due to peripheral state change: %@", reason];
                 // Call cleanup helper to reject and clear vars
                 [self cleanupPendingBroadcast:YES code:code message:reason error:nil];
                 isTryingToAdvertise = NO; // Clear intention as it failed
                 currentAdvertisingData = nil;
            }
             // Ensure advertising is physically stopped if manager reports it's still on (unlikely but safe)
            if (peripheral.isAdvertising) {
                 [self logAndSend:@"Stopping advertising due to non-ON state."];
                 [peripheral stopAdvertising];
            }
            break;

        default:
             [self logAndSend:@"State: Unknown default case."];
            break;
    }
    // Forward state change to JS for BT status updates (independent of advertising)
     BOOL enabled = (peripheral.state == CBManagerStatePoweredOn);
     [self sendEventWithName:@"onBTStatusChange" body:@{@"enabled": @(enabled)}];
}

// THIS IS THE KEY CALLBACK FOR CONFIRMATION
- (void)peripheralManagerDidStartAdvertising:(CBPeripheralManager *)peripheral error:(NSError *)error {
    // This is called AFTER [peripheralManager startAdvertising:] is invoked.

    if (error) {
        [self logAndSend:@"--> FAILED to start advertising: %@", error.localizedDescription];
        // If we failed, reject the pending promise and clear the intention flag
        [self cleanupPendingBroadcast:YES code:@"AdvertisingStartFailed" message:error.localizedDescription error:error];
        isTryingToAdvertise = NO;
        currentAdvertisingData = nil;

    } else {
        [self logAndSend:@"--> SUCCESS: Advertising started successfully (confirmed by delegate)."];
        // If we succeeded, resolve the pending promise
        if (pendingAdResolve) {
            pendingAdResolve(@"Advertising started successfully.");
        } else {
            // This shouldn't happen if state is managed correctly
            [self logAndSend:@"Warning: Advertising started but no pending resolve block found."];
        }
        // Clear promises now that we've resolved
        [self cleanupPendingBroadcast:NO code:nil message:nil error:nil];
        // Keep isTryingToAdvertise = YES because we are now successfully advertising
    }
}


#pragma mark - CBCentralManagerDelegate Methods (Mostly for BT status/permissions)

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
     // We use peripheralManagerDidUpdateState for advertising logic trigger,
     // but central manager state is useful for overall BT status reporting.
     [self logAndSend:@"Central Manager State Updated: %ld", (long)central.state];
     // We can optionally send a separate onBTStatusChange event based on central state
     // but peripheral state is more directly relevant to advertising capability.
     // Let's keep the onBTStatusChange tied to peripheral state for consistency.
}

// Optional: Add stubs for other CBCentralManagerDelegate methods if needed for scanning later
// - (void)centralManager:(CBCentralManager *)central didDiscoverPeripheral:(CBPeripheral *)peripheral ... {}


// --- Methods related to Scanning (Keep your existing implementations) ---

RCT_EXPORT_METHOD(scan: (NSArray *)payload options:(NSDictionary *)options
    resolve: (RCTPromiseResolveBlock)resolve
    rejecter:(RCTPromiseRejectBlock)reject){
    // Keep existing scan logic...
    [self logAndSend:@"scan function called"];
     if (!centralManager) { [self logAndSend:@"Central manager nil in scan"]; reject(@"CentralManagerError", @"Central manager not initialized", nil); return; }
     if (centralManager.state != CBManagerStatePoweredOn) { reject(@"BluetoothNotReady", @"Bluetooth not powered on for scanning", nil); return; }
     [centralManager scanForPeripheralsWithServices:nil options:@{CBCentralManagerScanOptionAllowDuplicatesKey:@(YES)}];
     resolve(@"Scanning Started");
}

RCT_EXPORT_METHOD(scanByService: (NSString *)uid options:(NSDictionary *)options
    resolve: (RCTPromiseResolveBlock)resolve
    rejecter:(RCTPromiseRejectBlock)reject){
    // Keep existing scanByService logic...
    [self logAndSend:@"scanByService function called with UID %@", uid];
     if (!centralManager) { [self logAndSend:@"Central manager nil in scanByService"]; reject(@"CentralManagerError", @"Central manager not initialized", nil); return; }
     if (centralManager.state != CBManagerStatePoweredOn) { reject(@"BluetoothNotReady", @"Bluetooth not powered on for scanning", nil); return; }
     CBUUID *serviceUUID = [CBUUID UUIDWithString:uid];
     if (!serviceUUID) { reject(@"InvalidUUID", @"Invalid Service UUID format", nil); return; }
     [centralManager scanForPeripheralsWithServices:@[serviceUUID] options:@{CBCentralManagerScanOptionAllowDuplicatesKey:@(YES)}];
     resolve(@"Scanning by service Started");
}

RCT_EXPORT_METHOD(stopScan:(RCTPromiseResolveBlock)resolve
    rejecter:(RCTPromiseRejectBlock)reject){
    // Keep existing stopScan logic...
     [self logAndSend:@"stopScan function called"];
     if (!centralManager) { reject(@"CentralManagerError", @"Central manager not initialized", nil); return; }
     if (centralManager.isScanning) { [centralManager stopScan]; [self logAndSend:@"Stopped scanning."]; }
     resolve(@"Stopping Scan Initiated");
}

-(void)centralManager:(CBCentralManager *)central didDiscoverPeripheral:(CBPeripheral *)peripheral advertisementData:(NSDictionary<NSString *,id> *)advertisementData RSSI:(NSNumber *)RSSI {
     // Keep existing didDiscoverPeripheral logic...
     [self logAndSend:@"Discovered Peripheral: Name: %@, ID: %@, RSSI: %@", [peripheral name], [[peripheral identifier] UUIDString], RSSI];
     // ... (rest of your parsing and sendEvent logic)
    NSMutableDictionary *params =  [[NSMutableDictionary alloc] init];
    NSMutableArray *serviceUUIDs = [[NSMutableArray alloc] init];
    NSArray *uuidArray = advertisementData[CBAdvertisementDataServiceUUIDsKey];
    if ([uuidArray isKindOfClass:[NSArray class]]) {
        for (CBUUID *uuid in uuidArray) { [serviceUUIDs addObject:[uuid UUIDString]]; }
    }
    NSData *manufData = advertisementData[CBAdvertisementDataManufacturerDataKey];
    if ([manufData isKindOfClass:[NSData class]] && manufData.length >= 2) {
        uint16_t discoveredCompanyId = 0; [manufData getBytes:&discoveredCompanyId length:2]; discoveredCompanyId = OSSwapLittleToHostInt16(discoveredCompanyId);
        params[@"companyId"] = @(discoveredCompanyId);
        if (manufData.length > 2) {
             NSData *payloadBytes = [manufData subdataWithRange:NSMakeRange(2, manufData.length - 2)]; NSMutableArray *payloadArray = [[NSMutableArray alloc] init]; const uint8_t *bytes = [payloadBytes bytes]; for (NSUInteger i = 0; i < [payloadBytes length]; i++) { [payloadArray addObject:@(bytes[i])]; } params[@"manufData"] = payloadArray;
        } else { params[@"manufData"] = @[]; }
    } else { params[@"manufData"] = @[]; }
    NSNumber *validRSSI = (RSSI && RSSI.intValue != 127) ? RSSI : nil;
    params[@"serviceUuids"] = serviceUUIDs; params[@"rssi"] = validRSSI ?: [NSNull null]; params[@"deviceName"] = [peripheral name] ?: [NSNull null]; params[@"deviceAddress"] = [[peripheral identifier] UUIDString]; NSNumber *txPower = advertisementData[CBAdvertisementDataTxPowerLevelKey]; params[@"txPower"] = txPower ?: [NSNull null];
    [self sendEventWithName:@"onDeviceFound" body:params];
}

// --- Keep other existing methods (enableAdapter, disableAdapter, getAdapterState, isActive) ---
// Note: getAdapterState and isActive should preferably use peripheralManager state if advertising is the main concern,
// or centralManager state if general BT readiness is the goal. Let's keep them using centralManager for now.

RCT_EXPORT_METHOD(enableAdapter){ [self logAndSend:@"enableAdapter function called (No-op on iOS)"]; }
RCT_EXPORT_METHOD(disableAdapter){ [self logAndSend:@"disableAdapter function called (No-op on iOS)"]; }

RCT_EXPORT_METHOD(getAdapterState:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject){
    // Uses Central Manager state - reflects general BT availability
    [self logAndSend:@"getAdapterState function called"];
    if (!centralManager) { [self logAndSend:@"Central manager nil in getAdapterState"]; reject(@"CentralManagerError", @"Central manager not initialized", nil); return; }
    NSString *stateStr;
    switch (centralManager.state) {
        case CBManagerStatePoweredOn: stateStr = @"STATE_ON"; break;
        // ... (rest of cases as before) ...
        case CBManagerStatePoweredOff:      stateStr = @"STATE_OFF"; break;
        case CBManagerStateResetting:       stateStr = @"STATE_TURNING_ON"; break;
        case CBManagerStateUnauthorized:    stateStr = @"STATE_OFF"; break;
        case CBManagerStateUnknown:         stateStr = @"STATE_OFF"; break;
        case CBManagerStateUnsupported:     stateStr = @"STATE_OFF"; break;
        default:                            stateStr = @"STATE_OFF"; break;
    }
    resolve(stateStr);
}

RCT_EXPORT_METHOD(isActive:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject){
     // Uses Central Manager state
    [self logAndSend:@"isActive function called"];
    if (!centralManager) { [self logAndSend:@"Central manager nil in isActive"]; reject(@"CentralManagerError", @"Central manager not initialized", nil); return; }
    BOOL isActive = ([centralManager state] == CBManagerStatePoweredOn);
    resolve(@(isActive));
}


@end