#import "BLEAdvertiser.h"
@import CoreBluetooth;

// Declare private methods in a class extension
@interface BLEAdvertiser ()
- (void)startAdvertisingInternal;
- (void)stopAdvertisingInternalAndReject:(NSString *)code message:(NSString *)message error:(NSError *)error;
- (void)cleanupPendingBroadcast:(BOOL)shouldReject code:(NSString *)code message:(NSString *)message error:(NSError *)error;
// Timer methods
- (void)startAdvertisingStatusTimer;
- (void)stopAdvertisingStatusTimer;
- (void)checkAdvertisingStatus:(NSTimer *)timer;
@end
// End of class extension

@implementation BLEAdvertiser {
    CBCentralManager *centralManager;
    CBPeripheralManager *peripheralManager;

    int companyId;

    // State for Advertising
    BOOL isTryingToAdvertise;
    NSDictionary *currentAdvertisingData;
    RCTPromiseResolveBlock pendingAdResolve;
    RCTPromiseRejectBlock pendingAdReject;
    NSTimer *advertisingCheckTimer; // Timer for status checks
}

- (dispatch_queue_t)methodQueue
{
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

// Initialization
- (instancetype)init {
    self = [super init];
    if (self) {
        isTryingToAdvertise = NO;
         if (!centralManager) {
            centralManager = [[CBCentralManager alloc] initWithDelegate:self queue:dispatch_get_main_queue() options:@{CBCentralManagerOptionShowPowerAlertKey: @(NO)}];
         }
         if (!peripheralManager) {
            peripheralManager = [[CBPeripheralManager alloc] initWithDelegate:self queue:dispatch_get_main_queue() options:nil];
         }
         [self logAndSend:@"BLEAdvertiser Module Initialized."];
    }
    return self;
}

// Cleanup
- (void)invalidate {
     [self logAndSend:@"Module invalidating."];
     [self stopAdvertisingStatusTimer]; // Stop timer first
     if (peripheralManager && peripheralManager.isAdvertising) {
         [peripheralManager stopAdvertising];
     }
     if (centralManager) { centralManager.delegate = nil; centralManager = nil; }
     if (peripheralManager) { peripheralManager.delegate = nil; peripheralManager = nil; }
     [self cleanupPendingBroadcast:YES code:@"ModuleInvalidated" message:@"Module resources released." error:nil];
}


RCT_EXPORT_METHOD(setCompanyId: (nonnull NSNumber *)companyIdNum){
    [self logAndSend:@"setCompanyId function called %@", companyIdNum];
    companyId = [companyIdNum intValue];
}

RCT_EXPORT_METHOD(broadcast: (NSString *)uid // uid not directly used but part of API
                  payload:(NSArray *)payloadArray
                  options:(NSDictionary *)options // options currently ignored
                  resolve: (RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject){

    // Use payload to construct part of the local name for easy identification
    NSString *payloadString = @"";
    if ([payloadArray count] > 0) {
         NSMutableString *tempString = [NSMutableString string];
         for(NSNumber *num in payloadArray) {
              [tempString appendFormat:@"%c", [num unsignedCharValue]]; // Assuming ASCII here
         }
         payloadString = [tempString copy];
    }
    NSString *localName = [NSString stringWithFormat:@"Kiosk_%@", payloadString];
    [self logAndSend:@"broadcast called. Local Name: '%@', Payload: %@", localName, payloadArray];


    if (!peripheralManager) {
        [self logAndSend:@"ERROR: Peripheral manager nil in broadcast"];
        reject(@"PeripheralManagerError", @"Peripheral manager not initialized", nil);
        return;
    }
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

    // Store the data we *intend* to advertise: Manufacturer Data + Local Name
    currentAdvertisingData = @{
        CBAdvertisementDataManufacturerDataKey : manufacturerData,
        CBAdvertisementDataLocalNameKey : localName // ADDING LOCAL NAME
    };
    // --- End Prepare Data ---

    pendingAdResolve = [resolve copy];
    pendingAdReject = [reject copy];
    isTryingToAdvertise = YES;

    [self logAndSend:@"Data prepared (Manuf+Name), checking peripheral state..."];

    if (peripheralManager.state == CBManagerStatePoweredOn) {
        [self logAndSend:@"Peripheral is Powered ON. Attempting to start advertising..."];
        [self startAdvertisingInternal];
    } else {
        [self logAndSend:@"Peripheral is NOT Powered ON (State: %ld). Waiting for state update.", (long)peripheralManager.state];
    }
}

// Internal helper to call startAdvertising
- (void)startAdvertisingInternal {
    if (!isTryingToAdvertise || !currentAdvertisingData) {
        [self logAndSend:@"startAdvertisingInternal called but not trying to advertise or no data. Ignoring."];
        return;
    }
    if (peripheralManager.state != CBManagerStatePoweredOn) {
        [self logAndSend:@"startAdvertisingInternal: State is not Powered ON (%ld). Aborting.", (long)peripheralManager.state];
        [self cleanupPendingBroadcast:YES code:@"BluetoothNotReady" message:@"Bluetooth powered off before advertising could start." error:nil];
        isTryingToAdvertise = NO; currentAdvertisingData = nil;
        [self stopAdvertisingStatusTimer]; // Ensure timer is stopped if start fails here
        return;
    }

    [self logAndSend:@"Calling [peripheralManager startAdvertising:%@]", currentAdvertisingData];
    [peripheralManager startAdvertising:currentAdvertisingData];
}

RCT_EXPORT_METHOD(stopBroadcast:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject){ // rejecter usually not needed for stop
    [self logAndSend:@"stopBroadcast called."];
    [self stopAdvertisingInternalAndReject:nil message:nil error:nil];
    resolve(@"Stop broadcast requested.");
}

// Internal helper to stop advertising and cleanup state/promises
- (void)stopAdvertisingInternalAndReject:(NSString *)code message:(NSString *)message error:(NSError *)error {
    BOOL wasTryingToAdvertise = isTryingToAdvertise;
    isTryingToAdvertise = NO;
    currentAdvertisingData = nil;
    [self stopAdvertisingStatusTimer]; // Stop the check timer

    if (peripheralManager && peripheralManager.isAdvertising) {
        [self logAndSend:@"Stopping active advertising."];
        [peripheralManager stopAdvertising];
    } else {
         [self logAndSend:@"Stop requested, but peripheral manager was not advertising."];
    }

    if (wasTryingToAdvertise && code) { // Reject pending START promise if stop was due to an error
        [self cleanupPendingBroadcast:YES code:code message:message error:error];
    } else { // Otherwise, just clear any leftover promise without rejecting
        [self cleanupPendingBroadcast:NO code:nil message:nil error:nil];
    }
}

// Helper to clear promise variables, optionally rejecting
- (void)cleanupPendingBroadcast:(BOOL)shouldReject code:(NSString *)code message:(NSString *)message error:(NSError *)error {
    if (shouldReject && pendingAdReject) {
        [self logAndSend:@"Rejecting pending broadcast promise. Code: %@, Message: %@", code, message];
        pendingAdReject(code, message, error);
    } else if (pendingAdResolve) {
        // This path might be hit if cleanup is called after successful start, which is okay.
         // Log only if rejecting didn't happen but resolve still existed (unexpected)
         if (!shouldReject) {
             [self logAndSend:@"Clearing pending resolve block."];
         }
    }
    pendingAdResolve = nil;
    pendingAdReject = nil;
}


#pragma mark - CBPeripheralManagerDelegate Methods

- (void)peripheralManagerDidUpdateState:(CBPeripheralManager *)peripheral {
    [self logAndSend:@"Peripheral Manager State Updated: %ld", (long)peripheral.state];
    BOOL enabled = (peripheral.state == CBManagerStatePoweredOn);

    switch (peripheral.state) {
        case CBManagerStatePoweredOn:
            [self logAndSend:@"State: Powered ON."];
            if (isTryingToAdvertise) {
                [self logAndSend:@"Powered ON and should be advertising, attempting start..."];
                [self startAdvertisingInternal];
            }
            break;

        // Handle all non-powered-on states
        default: // Covers Off, Resetting, Unauthorized, Unsupported, Unknown
            [self logAndSend:@"State: Not Powered ON (%ld).", (long)peripheral.state];
            [self stopAdvertisingStatusTimer]; // Stop timer if running
            if (isTryingToAdvertise) { // If we were trying to advertise, it failed.
                 NSString *reason = @"Bluetooth state changed to non-operational.";
                 NSString *code = @"BluetoothUnavailable";
                 // Refine code/reason based on specific state if needed
                 switch (peripheral.state) {
                    case CBManagerStatePoweredOff: reason = @"Bluetooth powered off"; code = @"BluetoothPoweredOff"; break;
                    case CBManagerStateResetting: reason = @"Bluetooth resetting"; code = @"BluetoothResetting"; break;
                    case CBManagerStateUnauthorized: reason = @"Bluetooth permission denied"; code = @"BluetoothUnauthorized"; break;
                    case CBManagerStateUnsupported: reason = @"Bluetooth LE not supported"; code = @"BluetoothUnsupported"; break;
                    default: reason = @"Bluetooth state unknown"; code = @"BluetoothUnknown"; break;
                 }
                 [self logAndSend:@"Rejecting pending broadcast due to peripheral state change: %@", reason];
                 [self cleanupPendingBroadcast:YES code:code message:reason error:nil];
                 isTryingToAdvertise = NO;
                 currentAdvertisingData = nil;
            }
            // Ensure advertising is physically stopped
            if (peripheral.isAdvertising) {
                 [self logAndSend:@"Stopping advertising due to non-ON state."];
                 [peripheral stopAdvertising];
            }
            break;
    }
    // Send status update event to JS
    [self sendEventWithName:@"onBTStatusChange" body:@{@"enabled": @(enabled)}];
}

// THE KEY CALLBACK FOR CONFIRMATION
- (void)peripheralManagerDidStartAdvertising:(CBPeripheralManager *)peripheral error:(NSError *)error {
    if (error) {
        [self logAndSend:@"--> FAILED to start advertising: %@", error.localizedDescription];
        [self stopAdvertisingStatusTimer]; // Stop timer if start failed
        [self cleanupPendingBroadcast:YES code:@"AdvertisingStartFailed" message:error.localizedDescription error:error];
        isTryingToAdvertise = NO;
        currentAdvertisingData = nil;
    } else {
        [self logAndSend:@"--> SUCCESS: Advertising started successfully (confirmed by delegate)."];
        if (pendingAdResolve) {
            pendingAdResolve(@"Advertising started successfully.");
        } else { [self logAndSend:@"Warning: Advertising started but no pending resolve block found."]; }
        [self cleanupPendingBroadcast:NO code:nil message:nil error:nil]; // Clear promise vars after resolving
        // Keep isTryingToAdvertise = YES
        // START THE STATUS CHECK TIMER
        [self startAdvertisingStatusTimer];
    }
}

#pragma mark - Timer Methods

- (void)startAdvertisingStatusTimer {
    [self stopAdvertisingStatusTimer]; // Ensure no duplicates
    [self logAndSend:@"Starting advertising status check timer (Interval: 3s)."];
    dispatch_async(dispatch_get_main_queue(), ^{ // Ensure timer is scheduled on main thread
        self->advertisingCheckTimer = [NSTimer scheduledTimerWithTimeInterval:3.0 // Check every 3 seconds
                                                                 target:self
                                                               selector:@selector(checkAdvertisingStatus:)
                                                               userInfo:nil
                                                                repeats:YES];
        // Add to common modes to run during UI interaction
        [[NSRunLoop mainRunLoop] addTimer:self->advertisingCheckTimer forMode:NSRunLoopCommonModes];
    });
}

- (void)stopAdvertisingStatusTimer {
    if (advertisingCheckTimer) {
        [self logAndSend:@"Stopping advertising status check timer."];
        [advertisingCheckTimer invalidate];
        advertisingCheckTimer = nil;
    }
}

- (void)checkAdvertisingStatus:(NSTimer *)timer {
    if (!peripheralManager) {
        [self logAndSend:@"Timer Check: Peripheral Manager is nil. Stopping timer."];
        [self stopAdvertisingStatusTimer];
        return;
    }

    BOOL isCurrentlyAdvertising = peripheralManager.isAdvertising;
    [self logAndSend:@"Timer Check: isAdvertising = %@", isCurrentlyAdvertising ? @"YES" : @"NO"];

    // If we expect to be advertising but the manager says we are not, something went wrong.
    if (isTryingToAdvertise && !isCurrentlyAdvertising) {
         [self logAndSend:@"ALERT: Advertising state is NO, but expected YES! Advertising likely stopped unexpectedly."];
         // Consider stopping the timer now as the state is unexpected
         // [self stopAdvertisingStatusTimer];
         // Maybe set isTryingToAdvertise to NO? Depends on desired auto-restart logic.
         // isTryingToAdvertise = NO;
    }
    // If we don't expect to be advertising (stop called) but timer check finds it's still on, log it.
    else if (!isTryingToAdvertise && isCurrentlyAdvertising) {
         [self logAndSend:@"WARNING: Advertising state is YES, but expected NO (stopBroadcast was likely called)."];
         // Maybe try stopping it again? Or just stop the timer.
         [self stopAdvertisingStatusTimer];
    }
     // If state matches expectation (YES/YES or NO/NO), do nothing special.
}


#pragma mark - CBCentralManagerDelegate Methods (Mostly for BT status/permissions)

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
     [self logAndSend:@"Central Manager State Updated: %ld", (long)central.state];
     // Central state changes don't directly trigger advertising logic here,
     // but could be used for more general app BT status UI.
}


#pragma mark - Scanning Methods (Keep existing implementations)

RCT_EXPORT_METHOD(scan: (NSArray *)payload options:(NSDictionary *)options
    resolve: (RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject){
    [self logAndSend:@"scan function called"];
     if (!centralManager) { [self logAndSend:@"Central manager nil in scan"]; reject(@"CentralManagerError", @"Central manager not initialized", nil); return; }
     if (centralManager.state != CBManagerStatePoweredOn) { reject(@"BluetoothNotReady", @"Bluetooth not powered on for scanning", nil); return; }
     [centralManager scanForPeripheralsWithServices:nil options:@{CBCentralManagerScanOptionAllowDuplicatesKey:@(YES)}];
     resolve(@"Scanning Started");
}

RCT_EXPORT_METHOD(scanByService: (NSString *)uid options:(NSDictionary *)options
    resolve: (RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject){
    [self logAndSend:@"scanByService function called with UID %@", uid];
     if (!centralManager) { [self logAndSend:@"Central manager nil in scanByService"]; reject(@"CentralManagerError", @"Central manager not initialized", nil); return; }
     if (centralManager.state != CBManagerStatePoweredOn) { reject(@"BluetoothNotReady", @"Bluetooth not powered on for scanning", nil); return; }
     CBUUID *serviceUUID = [CBUUID UUIDWithString:uid];
     if (!serviceUUID) { reject(@"InvalidUUID", @"Invalid Service UUID format", nil); return; }
     [centralManager scanForPeripheralsWithServices:@[serviceUUID] options:@{CBCentralManagerScanOptionAllowDuplicatesKey:@(YES)}];
     resolve(@"Scanning by service Started");
}

RCT_EXPORT_METHOD(stopScan:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject){
     [self logAndSend:@"stopScan function called"];
     if (!centralManager) { reject(@"CentralManagerError", @"Central manager not initialized", nil); return; }
     if (centralManager.isScanning) { [centralManager stopScan]; [self logAndSend:@"Stopped scanning."]; }
     resolve(@"Stopping Scan Initiated");
}

-(void)centralManager:(CBCentralManager *)central didDiscoverPeripheral:(CBPeripheral *)peripheral advertisementData:(NSDictionary<NSString *,id> *)advertisementData RSSI:(NSNumber *)RSSI {
     // Keep existing discovery parsing logic
     [self logAndSend:@"Discovered Peripheral: Name: %@, ID: %@, RSSI: %@", advertisementData[CBAdvertisementDataLocalNameKey] ?: peripheral.name, [[peripheral identifier] UUIDString], RSSI];
     NSMutableDictionary *params =  [[NSMutableDictionary alloc] init]; NSMutableArray *serviceUUIDs = [[NSMutableArray alloc] init]; NSArray *uuidArray = advertisementData[CBAdvertisementDataServiceUUIDsKey]; if ([uuidArray isKindOfClass:[NSArray class]]) { for (CBUUID *uuid in uuidArray) { [serviceUUIDs addObject:[uuid UUIDString]]; } } NSData *manufData = advertisementData[CBAdvertisementDataManufacturerDataKey]; if ([manufData isKindOfClass:[NSData class]] && manufData.length >= 2) { uint16_t discoveredCompanyId = 0; [manufData getBytes:&discoveredCompanyId length:2]; discoveredCompanyId = OSSwapLittleToHostInt16(discoveredCompanyId); params[@"companyId"] = @(discoveredCompanyId); if (manufData.length > 2) { NSData *payloadBytes = [manufData subdataWithRange:NSMakeRange(2, manufData.length - 2)]; NSMutableArray *payloadArray = [[NSMutableArray alloc] init]; const uint8_t *bytes = [payloadBytes bytes]; for (NSUInteger i = 0; i < [payloadBytes length]; i++) { [payloadArray addObject:@(bytes[i])]; } params[@"manufData"] = payloadArray; } else { params[@"manufData"] = @[]; } } else { params[@"manufData"] = @[]; } NSNumber *validRSSI = (RSSI && RSSI.intValue != 127) ? RSSI : nil; params[@"serviceUuids"] = serviceUUIDs; params[@"rssi"] = validRSSI ?: [NSNull null]; params[@"deviceName"] = advertisementData[CBAdvertisementDataLocalNameKey] ?: peripheral.name ?: [NSNull null]; params[@"deviceAddress"] = [[peripheral identifier] UUIDString]; NSNumber *txPower = advertisementData[CBAdvertisementDataTxPowerLevelKey]; params[@"txPower"] = txPower ?: [NSNull null]; [self sendEventWithName:@"onDeviceFound" body:params];
}

#pragma mark - Other Exported Methods (Keep existing)

RCT_EXPORT_METHOD(enableAdapter){ [self logAndSend:@"enableAdapter function called (No-op on iOS)"]; }
RCT_EXPORT_METHOD(disableAdapter){ [self logAndSend:@"disableAdapter function called (No-op on iOS)"]; }
RCT_EXPORT_METHOD(getAdapterState:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject){
    [self logAndSend:@"getAdapterState function called"]; if (!centralManager) { reject(@"CentralManagerError", @"Central manager not initialized", nil); return; } NSString *stateStr; switch (centralManager.state) { case CBManagerStatePoweredOn: stateStr = @"STATE_ON"; break; case CBManagerStatePoweredOff: stateStr = @"STATE_OFF"; break; case CBManagerStateResetting: stateStr = @"STATE_TURNING_ON"; break; case CBManagerStateUnauthorized: stateStr = @"STATE_OFF"; break; case CBManagerStateUnknown: stateStr = @"STATE_OFF"; break; case CBManagerStateUnsupported: stateStr = @"STATE_OFF"; break; default: stateStr = @"STATE_OFF"; break; } resolve(stateStr);
}
RCT_EXPORT_METHOD(isActive:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject){
    [self logAndSend:@"isActive function called"]; if (!centralManager) { reject(@"CentralManagerError", @"Central manager not initialized", nil); return; } BOOL isActive = ([centralManager state] == CBManagerStatePoweredOn); resolve(@(isActive));
}

@end