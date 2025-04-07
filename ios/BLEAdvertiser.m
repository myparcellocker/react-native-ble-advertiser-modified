#import "BLEAdvertiser.h"
@import CoreBluetooth;

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
    RCTLogInfo(@"%@", message);
    [self sendEventWithName:@"onNativeLog" body:@{@"message": message}];
}

RCT_EXPORT_METHOD(setCompanyId: (nonnull NSNumber *)companyIdNum){
    [self logAndSend:@"setCompanyId function called %@", companyIdNum];
    companyId = [companyIdNum intValue]; // Store the company ID (e.g., 0xFFFF)
    self->centralManager = [[CBCentralManager alloc] initWithDelegate:self queue:nil options:@{CBCentralManagerOptionShowPowerAlertKey: @(YES)}];
    self->peripheralManager = [[CBPeripheralManager alloc] initWithDelegate:self queue:nil options:nil];
}

RCT_EXPORT_METHOD(broadcast: (NSString *)uid payload:(NSArray *)payloadArray options:(NSDictionary *)options
    resolve: (RCTPromiseResolveBlock)resolve
    rejecter:(RCTPromiseRejectBlock)reject){
    [self logAndSend:@"Broadcast function called %@ with payload %@", uid, payloadArray];

    if (!peripheralManager) {
        reject(@"PeripheralManagerError", @"Peripheral manager not initialized", nil);
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
        [self startAdvertising];
    } else {
        [self logAndSend:@"Waiting for peripheral manager to be powered on..."];
    }
}

- (void)startAdvertising {
    if (!pendingUid || !pendingPayload || !pendingResolve || !pendingReject) {
        [self logAndSend:@"No pending broadcast to start"];
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

    // Advertise ONLY Manufacturer Data to force it into the main packet
    NSDictionary *advertisingData = @{
        CBAdvertisementDataManufacturerDataKey : manufacturerData
        // CBAdvertisementDataServiceUUIDsKey : @[[CBUUID UUIDWithString:pendingUid]] // <-- Temporarily comment this out
    };

   [self logAndSend:@"Starting advertising with Manufacturer Data ONLY: %@", manufacturerData];
    [peripheralManager startAdvertising:advertisingData];

    // Check if advertising actually started after a short delay (optional sanity check)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self->peripheralManager.isAdvertising) {
            [self logAndSend:@"Peripheral manager IS advertising."];
            if (pendingResolve) {
                 pendingResolve(@"Broadcasting (Manufacturer Data Only)");
            }
        } else {
            [self logAndSend:@"Peripheral manager IS NOT advertising."];
             if (pendingReject) {
                 pendingReject(@"AdvertisingStartFailed", @"Peripheral manager did not start advertising after command.", nil);
             }
        }

    // Clear pending parameters after success
    pendingUid = nil;
    pendingPayload = nil;
    pendingOptions = nil;
    pendingResolve = nil;
    pendingReject = nil;
}

RCT_EXPORT_METHOD(stopBroadcast:(RCTPromiseResolveBlock)resolve
    rejecter:(RCTPromiseRejectBlock)reject){
    [self logAndSend:@"stopBroadcast function called"];
    if (peripheralManager) {
        [peripheralManager stopAdvertising];
        resolve(@"Stopping Broadcast");
    } else {
        reject(@"PeripheralManagerError", @"Peripheral manager not initialized", nil);
    }
}

RCT_EXPORT_METHOD(scan: (NSArray *)payload options:(NSDictionary *)options 
    resolve: (RCTPromiseResolveBlock)resolve
    rejecter:(RCTPromiseRejectBlock)reject){
    [self logAndSend:@"scan function called"];

    if (!centralManager) { 
        reject(@"Device does not support Bluetooth", @"Adapter is Null", nil); 
        return; 
    }
    
    switch (centralManager.state) {
        case CBManagerStatePoweredOn:    break;
        case CBManagerStatePoweredOff:   reject(@"Bluetooth not ON", @"Powered off", nil);   return;
        case CBManagerStateResetting:    reject(@"Bluetooth not ON", @"Resetting", nil);     return;
        case CBManagerStateUnauthorized: reject(@"Bluetooth not ON", @"Unauthorized", nil);  return;
        case CBManagerStateUnknown:      reject(@"Bluetooth not ON", @"Unknown", nil);       return;
        case CBManagerStateUnsupported:  reject(@"STATE_OFF", @"Unsupported", nil);          return;
    }
 
    [centralManager scanForPeripheralsWithServices:nil options:@{CBCentralManagerScanOptionAllowDuplicatesKey:[NSNumber numberWithBool:YES]}];
    resolve(@"Scanning");
}

RCT_EXPORT_METHOD(scanByService: (NSString *)uid options:(NSDictionary *)options 
    resolve: (RCTPromiseResolveBlock)resolve
    rejecter:(RCTPromiseRejectBlock)reject){
    [self logAndSend:@"scanByService function called with UID %@", uid];

    if (!centralManager) { 
        reject(@"Device does not support Bluetooth", @"Adapter is Null", nil); 
        return; 
    }
    
    switch (centralManager.state) {
        case CBManagerStatePoweredOn:    break;
        case CBManagerStatePoweredOff:   reject(@"Bluetooth not ON", @"Powered off", nil);   return;
        case CBManagerStateResetting:    reject(@"Bluetooth not ON", @"Resetting", nil);     return;
        case CBManagerStateUnauthorized: reject(@"Bluetooth not ON", @"Unauthorized", nil);  return;
        case CBManagerStateUnknown:      reject(@"Bluetooth not ON", @"Unknown", nil);       return;
        case CBManagerStateUnsupported:  reject(@"STATE_OFF", @"Unsupported", nil);          return;
    }
 
    [centralManager scanForPeripheralsWithServices:@[[CBUUID UUIDWithString:uid]] options:@{CBCentralManagerScanOptionAllowDuplicatesKey:[NSNumber numberWithBool:YES]}];
    resolve(@"Scanning by service");
}

RCT_EXPORT_METHOD(stopScan:(RCTPromiseResolveBlock)resolve
    rejecter:(RCTPromiseRejectBlock)reject){
    [self logAndSend:@"stopScan function called"];
    if (centralManager) {
        [centralManager stopScan];
        resolve(@"Stopping Scan");
    } else {
        reject(@"CentralManagerError", @"Central manager not initialized", nil);
    }
}

RCT_EXPORT_METHOD(enableAdapter){
    [self logAndSend:@"enableAdapter function called"];
    // iOS does not allow programmatic enabling of Bluetooth; user must do it manually
}

RCT_EXPORT_METHOD(disableAdapter){
    [self logAndSend:@"disableAdapter function called"];
    // iOS does not allow programmatic disabling of Bluetooth; user must do it manually
}

RCT_EXPORT_METHOD(getAdapterState:(RCTPromiseResolveBlock)resolve
    rejecter:(RCTPromiseRejectBlock)reject){
    [self logAndSend:@"getAdapterState function called"];
    
    if (!centralManager) {
        reject(@"CentralManagerError", @"Central manager not initialized", nil);
        return;
    }

    switch (centralManager.state) {
        case CBManagerStatePoweredOn:       resolve(@"STATE_ON"); return;
        case CBManagerStatePoweredOff:      resolve(@"STATE_OFF"); return;
        case CBManagerStateResetting:       resolve(@"STATE_TURNING_ON"); return;
        case CBManagerStateUnauthorized:    resolve(@"STATE_OFF"); return;
        case CBManagerStateUnknown:         resolve(@"STATE_OFF"); return;
        case CBManagerStateUnsupported:     resolve(@"STATE_OFF"); return;
    }
}

RCT_EXPORT_METHOD(isActive: 
     (RCTPromiseResolveBlock)resolve
    rejecter:(RCTPromiseRejectBlock)reject){
    [self logAndSend:@"isActive function called"];
  
    if (!centralManager) {
        reject(@"CentralManagerError", @"Central manager not initialized", nil);
        return;
    }

    resolve(([centralManager state] == CBManagerStatePoweredOn) ? @YES : @NO);
}

-(void)centralManager:(CBCentralManager *)central didDiscoverPeripheral:(CBPeripheral *)peripheral advertisementData:(NSDictionary<NSString *,id> *)advertisementData RSSI:(NSNumber *)RSSI {
    [self logAndSend:@"Found Name: %@", [peripheral name]];
    [self logAndSend:@"Found Services: %@", [peripheral services]];
    [self logAndSend:@"Found Id : %@", [peripheral identifier]];
    [self logAndSend:@"Found UUID String : %@", [[peripheral identifier] UUIDString]];

    NSArray *keys = [advertisementData allKeys];
    for (int i = 0; i < [keys count]; ++i) {
        id key = [keys objectAtIndex: i];
        NSString *keyName = (NSString *) key;
        NSObject *value = [advertisementData objectForKey: key];
        if ([value isKindOfClass: [NSArray class]]) {
            printf("   key: %s\n", [keyName cStringUsingEncoding: NSUTF8StringEncoding]);
            NSArray *values = (NSArray *) value;
            for (int j = 0; j < [values count]; ++j) {
                NSObject *aValue = [values objectAtIndex: j];
                printf("       %s\n", [[aValue description] cStringUsingEncoding: NSUTF8StringEncoding]);
                printf("       is NSData: %d\n", [aValue isKindOfClass: [NSData class]]);
            }
        } else {
            const char *valueString = [[value description] cStringUsingEncoding: NSUTF8StringEncoding];
            printf("   key: %s, value: %s\n", [keyName cStringUsingEncoding: NSUTF8StringEncoding], valueString);
        }
    }

    NSMutableDictionary *params =  [[NSMutableDictionary alloc] initWithCapacity:1];      
    NSMutableArray *paramsUUID = [[NSMutableArray alloc] init];

    NSObject *kCBAdvDataServiceUUIDs = [advertisementData objectForKey: @"kCBAdvDataServiceUUIDs"];
    if ([kCBAdvDataServiceUUIDs isKindOfClass:[NSArray class]]) {
        NSArray *uuids = (NSArray *) kCBAdvDataServiceUUIDs;
        for (int j = 0; j < [uuids count]; ++j) {
            NSObject *aValue = [uuids objectAtIndex: j];
            [paramsUUID addObject:[aValue description]];
        }
    }

    RSSI = RSSI && RSSI.intValue < 127 ? RSSI : nil;

    params[@"serviceUuids"] = paramsUUID;
    params[@"rssi"] = RSSI;
    params[@"deviceName"] = [peripheral name];
    params[@"deviceAddress"] = [peripheral identifier];
    params[@"txPower"] = [advertisementData objectForKey: @"kCBAdvDataTxPowerLevel"];
    
    [self sendEventWithName:@"onDeviceFound" body:params];
}

-(void)centralManager:(CBCentralManager *)central didDisconnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    [self logAndSend:@"Peripheral disconnected: %@", [peripheral identifier]];
}

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    [self logAndSend:@"Central manager state updated: %ld", (long)central.state];
    NSMutableDictionary *params =  [[NSMutableDictionary alloc] initWithCapacity:1];      
    switch (central.state) {
        case CBManagerStatePoweredOff:
            params[@"enabled"] = @NO;
            NSLog(@"CoreBluetooth BLE hardware is powered off");
            break;
        case CBManagerStatePoweredOn:
            params[@"enabled"] = @YES;
            NSLog(@"CoreBluetooth BLE hardware is powered on and ready");
            break;
        case CBManagerStateResetting:
            params[@"enabled"] = @NO;
            NSLog(@"CoreBluetooth BLE hardware is resetting");
            break;
        case CBManagerStateUnauthorized:
            params[@"enabled"] = @NO;
            NSLog(@"CoreBluetooth BLE state is unauthorized");
            break;
        case CBManagerStateUnknown:
            params[@"enabled"] = @NO;
            NSLog(@"CoreBluetooth BLE state is unknown");
            break;
        case CBManagerStateUnsupported:
            params[@"enabled"] = @NO;
            NSLog(@"CoreBluetooth BLE hardware is unsupported on this platform");
            break;
        default:
            break;
    }
    [self sendEventWithName:@"onBTStatusChange" body:params];
}

#pragma mark - CBPeripheralManagerDelegate
- (void)peripheralManagerDidUpdateState:(CBPeripheralManager *)peripheral
{
    [self logAndSend:@"Peripheral manager state updated: %ld", (long)peripheral.state];
    switch (peripheral.state) {
        case CBManagerStatePoweredOn:
            NSLog(@"CBPeripheralManagerStatePoweredOn");
            [self startAdvertising]; // Start if pending
            break;
        case CBManagerStatePoweredOff:
            NSLog(@"CBPeripheralManagerStatePoweredOff");
            if (pendingReject) {
                pendingReject(@"BluetoothNotPoweredOn", @"Bluetooth is not powered on", nil);
                pendingUid = nil;
                pendingPayload = nil;
                pendingOptions = nil;
                pendingResolve = nil;
                pendingReject = nil;
            }
            break;
        case CBManagerStateResetting:
            NSLog(@"CBPeripheralManagerStateResetting");
            break;
        case CBManagerStateUnauthorized:
            NSLog(@"CBPeripheralManagerStateUnauthorized");
            if (pendingReject) {
                pendingReject(@"BluetoothUnauthorized", @"Bluetooth permission denied", nil);
                pendingUid = nil;
                pendingPayload = nil;
                pendingOptions = nil;
                pendingResolve = nil;
                pendingReject = nil;
            }
            break;
        case CBManagerStateUnsupported:
            NSLog(@"CBPeripheralManagerStateUnsupported");
            if (pendingReject) {
                pendingReject(@"BluetoothUnsupported", @"Bluetooth LE not supported", nil);
                pendingUid = nil;
                pendingPayload = nil;
                pendingOptions = nil;
                pendingResolve = nil;
                pendingReject = nil;
            }
            break;
        case CBManagerStateUnknown:
            NSLog(@"CBPeripheralManagerStateUnknown");
            break;
        default:
            break;
    }
}

@end