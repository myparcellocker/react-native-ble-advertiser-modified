#import "BLEAdvertiser.h"
@import CoreBluetooth;

@implementation BLEAdvertiser {
    CBCentralManager *centralManager;
    CBPeripheralManager *peripheralManager;
    int companyId;
    NSString *pendingUid;
    NSArray *pendingPayload;
    NSDictionary *pendingOptions;
    RCTPromiseResolveBlock pendingResolve;
    RCTPromiseRejectBlock pendingReject;
    CBMutableService *customService;
}

- (dispatch_queue_t)methodQueue {
    return dispatch_get_main_queue();
}

RCT_EXPORT_MODULE(BLEAdvertiser)

- (NSArray<NSString *> *)supportedEvents {
    return @[@"onDeviceFound", @"onBTStatusChange", @"onNativeLog"];
}

- (void)logAndSend:(NSString *)format, ... {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    RCTLogInfo(@"%@", message);
    [self sendEventWithName:@"onNativeLog" body:@{@"message": message}];
}

RCT_EXPORT_METHOD(setCompanyId:(nonnull NSNumber *)companyIdNum) {
    [self logAndSend:@"setCompanyId function called %@", companyIdNum];
    companyId = [companyIdNum intValue];
    centralManager = [[CBCentralManager alloc] initWithDelegate:self queue:nil options:@{CBCentralManagerOptionShowPowerAlertKey: @(YES)}];
    peripheralManager = [[CBPeripheralManager alloc] initWithDelegate:self queue:nil];
}

RCT_EXPORT_METHOD(broadcast:(NSString *)uid payload:(NSArray *)payloadArray options:(NSDictionary *)options
                  resolve:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    [self logAndSend:@"Broadcast function called %@ with payload %@", uid, payloadArray];

    if (!peripheralManager) {
        reject(@"PeripheralManagerError", @"Peripheral manager not initialized", nil);
        return;
    }

    pendingUid = [uid copy];
    pendingPayload = [payloadArray copy];
    pendingOptions = [options copy];
    pendingResolve = [resolve copy];
    pendingReject = [reject copy];

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

    // Remove existing service if any
    if (customService) {
        [peripheralManager removeService:customService];
        customService = nil;
    }

    // Create service with our UUID
    CBUUID *serviceUUID = [CBUUID UUIDWithString:pendingUid];
    customService = [[CBMutableService alloc] initWithType:serviceUUID primary:YES];

    // Convert payload to NSData
    NSMutableData *payloadData = [NSMutableData data];
    for (NSNumber *byteNum in pendingPayload) {
        uint8_t byte = [byteNum unsignedCharValue];
        [payloadData appendBytes:&byte length:1];
    }

    // Create characteristic with our payload data
    CBMutableCharacteristic *characteristic = [[CBMutableCharacteristic alloc]
                                              initWithType:[CBUUID UUIDWithString:@"1234"]
                                              properties:CBCharacteristicPropertyRead
                                              value:payloadData
                                              permissions:CBAttributePermissionsReadable];

    customService.characteristics = @[characteristic];

    // Add the service to peripheral manager
    [peripheralManager addService:customService];

    // Convert payload bytes to UTF-8 string
    NSMutableData *payloadData = [NSMutableData data];
    for (NSNumber *byteNum in pendingPayload) {
        uint8_t byte = [byteNum unsignedCharValue];
        [payloadData appendBytes:&byte length:1];
    }
    NSString *deviceName = [[NSString alloc] initWithData:payloadData encoding:NSUTF8StringEncoding];
    // Start advertising with service UUID and device name
    [peripheralManager startAdvertising:@{
        CBAdvertisementDataServiceUUIDsKey: @[serviceUUID],
        CBAdvertisementDataLocalNameKey: deviceName
    }];

    [self logAndSend:@"Bluetooth advertising started as %@", deviceName];
    pendingResolve(@"Advertising started");
    [self clearPending];
}

- (void)clearPending {
    pendingUid = nil;
    pendingPayload = nil;
    pendingOptions = nil;
    pendingResolve = nil;
    pendingReject = nil;
}

RCT_EXPORT_METHOD(stopBroadcast:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    [self logAndSend:@"stopBroadcast function called"];
    if (peripheralManager) {
        [peripheralManager stopAdvertising];
        if (customService) {
            [peripheralManager removeService:customService];
            customService = nil;
        }
        resolve(@"Stopping Broadcast");
    } else {
        reject(@"PeripheralManagerError", @"Peripheral manager not initialized", nil);
    }
}

// Scanning methods remain unchanged from your original implementation
RCT_EXPORT_METHOD(scan:(NSArray *)payload options:(NSDictionary *)options
                  resolve:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
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
 
    [centralManager scanForPeripheralsWithServices:nil options:@{CBCentralManagerScanOptionAllowDuplicatesKey:@YES}];
    resolve(@"Scanning");
}

RCT_EXPORT_METHOD(scanByService:(NSString *)uid options:(NSDictionary *)options 
                  resolve:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
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
 
    [centralManager scanForPeripheralsWithServices:@[[CBUUID UUIDWithString:uid]] options:@{CBCentralManagerScanOptionAllowDuplicatesKey:@YES}];
    resolve(@"Scanning by service");
}

RCT_EXPORT_METHOD(stopScan:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    [self logAndSend:@"stopScan function called"];
    if (centralManager) {
        [centralManager stopScan];
        resolve(@"Stopping Scan");
    } else {
        reject(@"CentralManagerError", @"Central manager not initialized", nil);
    }
}

RCT_EXPORT_METHOD(enableAdapter) {
    [self logAndSend:@"enableAdapter function called"];
    // iOS doesn't allow programmatic enabling of Bluetooth
}

RCT_EXPORT_METHOD(disableAdapter) {
    [self logAndSend:@"disableAdapter function called"];
    // iOS doesn't allow programmatic disabling of Bluetooth
}

RCT_EXPORT_METHOD(getAdapterState:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
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

RCT_EXPORT_METHOD(isActive:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    [self logAndSend:@"isActive function called"];
  
    if (!centralManager) {
        reject(@"CentralManagerError", @"Central manager not initialized", nil);
        return;
    }

    resolve(([centralManager state] == CBManagerStatePoweredOn) ? @YES : @NO);
}

#pragma mark - CBCentralManagerDelegate
- (void)centralManager:(CBCentralManager *)central didDiscoverPeripheral:(CBPeripheral *)peripheral 
     advertisementData:(NSDictionary<NSString *,id> *)advertisementData 
                  RSSI:(NSNumber *)RSSI {
    
    NSMutableDictionary *params = [[NSMutableDictionary alloc] init];
    NSMutableArray *paramsUUID = [[NSMutableArray alloc] init];

    // Extract service UUIDs
    NSArray *serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey];
    if ([serviceUUIDs isKindOfClass:[NSArray class]]) {
        for (CBUUID *uuid in serviceUUIDs) {
            [paramsUUID addObject:[uuid UUIDString]];
        }
    }

    // Add basic device info
    params[@"serviceUuids"] = paramsUUID;
    params[@"rssi"] = RSSI;
    params[@"deviceName"] = advertisementData[CBAdvertisementDataLocalNameKey] ?: [peripheral name];
    params[@"deviceAddress"] = [[peripheral identifier] UUIDString];
    
    // Extract TX power if available
    NSNumber *txPower = advertisementData[CBAdvertisementDataTxPowerLevelKey];
    if (txPower) {
        params[@"txPower"] = txPower;
    }

    [self sendEventWithName:@"onDeviceFound" body:params];
}

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    [self logAndSend:@"Central manager state updated: %ld", (long)central.state];
    
    NSMutableDictionary *params = [[NSMutableDictionary alloc] init];
    switch (central.state) {
        case CBManagerStatePoweredOn:
            params[@"enabled"] = @YES;
            break;
        case CBManagerStatePoweredOff:
        case CBManagerStateResetting:
        case CBManagerStateUnauthorized:
        case CBManagerStateUnknown:
        case CBManagerStateUnsupported:
            params[@"enabled"] = @NO;
            break;
    }
    [self sendEventWithName:@"onBTStatusChange" body:params];
}

#pragma mark - CBPeripheralManagerDelegate
- (void)peripheralManagerDidUpdateState:(CBPeripheralManager *)peripheral {
    [self logAndSend:@"Peripheral manager state updated: %ld", (long)peripheral.state];
    
    switch (peripheral.state) {
        case CBManagerStatePoweredOn:
            if (pendingUid) {
                [self startAdvertising];
            }
            break;
        case CBManagerStatePoweredOff:
            if (pendingReject) {
                pendingReject(@"BluetoothNotPoweredOn", @"Bluetooth is not powered on", nil);
                [self clearPending];
            }
            break;
        case CBManagerStateUnauthorized:
            if (pendingReject) {
                pendingReject(@"BluetoothUnauthorized", @"Bluetooth permission denied", nil);
                [self clearPending];
            }
            break;
        case CBManagerStateUnsupported:
            if (pendingReject) {
                pendingReject(@"BluetoothUnsupported", @"Bluetooth LE not supported", nil);
                [self clearPending];
            }
            break;
        default:
            break;
    }
}

- (void)peripheralManagerDidStartAdvertising:(CBPeripheralManager *)peripheral error:(NSError *)error {
    if (error) {
        [self logAndSend:@"Advertising failed: %@", error.localizedDescription];
        if (pendingReject) {
            pendingReject(@"AdvertisingError", error.localizedDescription, error);
            [self clearPending];
        }
    } else {
        [self logAndSend:@"Advertising started successfully"];
    }
}

@end