// Copyright (C) 2018 Toitware ApS.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

// Note: This is host, we can ignore malloc errors

#include "../top.h"

#include "ble.h"
#include "../objects.h"
#include "../objects_inline.h"
#include "../event_sources/ble_host.h"

#undef BOOL

#import <CoreBluetooth/CoreBluetooth.h>

@class BLEResourceHolder;

namespace toit {

class BLEResourceGroup : public ResourceGroup {
 public:
  TAG(BLEResourceGroup);

  explicit BLEResourceGroup(Process* process)
      : ResourceGroup(process, HostBLEEventSource::instance()) {
  }

 protected:
  uint32_t on_event(Resource* resource, word data, uint32_t state) override {
    USE(resource);
    state |= data;
    return state;
  }
};

class BLECharacteristicResource;
class BLEServiceResource;
class BLEPeripheralManagerResource;

template <typename T>
class ServiceContainer : public BLEResource {
 public:
  ServiceContainer(BLEResourceGroup* group, Kind kind)
      : BLEResource(group, kind)
      , _service_resource_index([[NSMutableDictionary new] retain]) {}

  ~ServiceContainer() override {
    [_service_resource_index release];
  }

  virtual T* type() = 0;
  BLEServiceResource* get_or_create_service_resource(CBService* service, bool can_create=false);
 private:
  NSMutableDictionary<CBUUID*, BLEResourceHolder*>* _service_resource_index;
};

class BLERemoteDeviceResource : public ServiceContainer<BLERemoteDeviceResource> {
 public:
  TAG(BLERemoteDeviceResource);

  BLERemoteDeviceResource(BLEResourceGroup* group, CBCentralManager* central_manager, CBPeripheral* peripheral)
      : ServiceContainer(group, REMOTE_DEVICE)
      , _central_manager(central_manager)
      , _peripheral([peripheral retain]) {}

  ~BLERemoteDeviceResource() override {
    [_peripheral release];
  }

  BLERemoteDeviceResource* type() override {
    return this;
  }

  CBPeripheral* peripheral() const { return _peripheral; }
  CBCentralManager* central_manager() const { return _central_manager; }
 private:
  CBCentralManager* _central_manager;
  CBPeripheral* _peripheral;
};

// Supports two use cases:
//    - as a service on a remote device (_device is not null)
//    - as a local exposed service (_peripheral_manager is not null)
//      and service can be safely cast to CBMutableService
class BLEServiceResource: public BLEResource {
 public:
  TAG(BLEServiceResource);

  BLEServiceResource(BLEResourceGroup* group, BLERemoteDeviceResource *device, CBService* service)
    : BLEResource(group, SERVICE)
    , _service([service retain])
    , _device(device)
    , _peripheral_manager(null)
    , _characteristics_resource_index([[NSMutableDictionary new] retain])
    , _deployed(false) {}

  BLEServiceResource(BLEResourceGroup* group, BLEPeripheralManagerResource* peripheral_manager, CBService* service)
      : BLEResource(group, SERVICE)
      , _service([service retain])
      , _device(null)
      , _peripheral_manager(peripheral_manager)
      , _characteristics_resource_index([[NSMutableDictionary new] retain])
      , _deployed(false) {}

  ~BLEServiceResource() override {
    [_service release];
    [_characteristics_resource_index release];
  }
  
  CBService* service() { return _service; }
  BLERemoteDeviceResource* device() { return _device; }
  BLEPeripheralManagerResource* peripheral_manager() { return _peripheral_manager; }
  BLECharacteristicResource* get_or_create_characteristics_resource(CBCharacteristic* characteristic, bool can_create=false);
  bool deployed() const { return _deployed; }
  void set_deployed(bool deployed) { _deployed = deployed; }
 private:
  CBService* _service;
  BLERemoteDeviceResource* _device;
  BLEPeripheralManagerResource* _peripheral_manager;
  NSMutableDictionary<CBUUID*, BLEResourceHolder*>* _characteristics_resource_index;
  bool _deployed;
};


class CharacteristicData;
typedef DoubleLinkedList<CharacteristicData> CharacteristicDataList;
class CharacteristicData: public CharacteristicDataList::Element {
 public:
  explicit CharacteristicData(NSData *data): _data([data retain]) {}
  ~CharacteristicData() { [_data release]; }
  NSData* data() { return _data; }
 private:
  NSData* _data;
};

class BLECharacteristicResource : public BLEResource {
 public:
  TAG(BLECharacteristicResource);

  BLECharacteristicResource(BLEResourceGroup* group, BLEServiceResource *service, CBCharacteristic* characteristic)
      : BLEResource(group, CHARACTERISTIC)
      , _characteristic([characteristic retain])
      , _characteristic_data_list()
      , _service(service)
      , _mtu(-1) {}

  ~BLECharacteristicResource() override {
    [_characteristic release];
  }

  CBCharacteristic* characteristic() { return _characteristic; }

  void set_error(NSError* error) {
    if (_error != nil) [_error release];
    if (error != nil) error = [error retain];
    _error = error;
  }

  NSError* error() {
    return _error;
  }

  void append_data(NSData* data) {
    _characteristic_data_list.append(_new CharacteristicData(data));
  }

  CharacteristicData *remove_first() {
    return _characteristic_data_list.remove_first();
  }

  void put_back(CharacteristicData* data) {
    _characteristic_data_list.prepend(data);
  }

  BLEServiceResource* service() { return _service; }

  int mtu() const { return _mtu; }
  void set_mtu(int mtu) { _mtu = mtu; }
 private:
  CBCharacteristic* _characteristic;
  NSError* _error = nil;
  CharacteristicDataList _characteristic_data_list;
  BLEServiceResource* _service;
  int _mtu;
};


class DiscoveredPeripheral;
typedef DoubleLinkedList<DiscoveredPeripheral> DiscoveredPeripheralList;
class DiscoveredPeripheral : public DiscoveredPeripheralList::Element {
 public:
  DiscoveredPeripheral(CBPeripheral* peripheral, NSNumber* rssi, NSArray* services, NSNumber* connectable,
                                NSData* manufacturerData)
      : _peripheral([peripheral retain]), _rssi([rssi retain]), _services([services retain]),
        _connectable([connectable retain]), _manufacturer_data([manufacturerData retain]) {
  }

  ~DiscoveredPeripheral() {
    [_peripheral release];
    [_rssi release];
    [_services release];
    [_connectable release];
    [_manufacturer_data release];
  }

  CBPeripheral* peripheral() { return _peripheral; }

  NSNumber* rssi() { return _rssi; };

  NSArray* services() const { return _services; }

  NSNumber* connectable() const { return _connectable; }

  NSData* manufacturer_data() const { return _manufacturer_data; }

 private:
  CBPeripheral* _peripheral;
  NSNumber* _rssi;
  NSArray* _services;
  NSNumber* _connectable;
  NSData* _manufacturer_data;
};

class BLECentralManagerResource : public  BLEResource {
 public:
  TAG(BLECentralManagerResource);
  
  explicit BLECentralManagerResource(BLEResourceGroup *group) 
      : BLEResource(group, CENTRAL_MANAGER)
      , _scan_mutex(OS::allocate_mutex(1, "scan"))
      , _stop_scan_condition(OS::allocate_condition_variable(scan_mutex()))
      , _scan_active(false)
      , _central_manager(nil)
      , _newly_discovered_peripherals()
      , _peripherals([[NSMutableDictionary new] retain]) {
  }

  ~BLECentralManagerResource() override {
    if (_central_manager != nil) [_central_manager release];
    [_peripherals release];
    OS::dispose(_stop_scan_condition);
    OS::dispose(_scan_mutex);
  }
  
  Mutex* scan_mutex() { return _scan_mutex; }

  ConditionVariable* stop_scan_condition() { return _stop_scan_condition; }

  bool scan_active() const { return _scan_active; }

  void set_scan_active(bool scan_active) { _scan_active = scan_active; }

  CBCentralManager* central_manager() { return _central_manager; }
  void set_central_manager(CBCentralManager *central_manager) { _central_manager = [central_manager retain]; }
  void add_discovered_peripheral(DiscoveredPeripheral* discoveredPeripheral) {
    if ([_peripherals objectForKey:[discoveredPeripheral->peripheral() identifier]] == nil) {
      _peripherals[[discoveredPeripheral->peripheral() identifier]] = discoveredPeripheral->peripheral();
      _newly_discovered_peripherals.append(discoveredPeripheral);
      HostBLEEventSource::instance()->on_event(this, kBLEDiscovery);
    } else {
      delete discoveredPeripheral;
    }
  }

  DiscoveredPeripheral* next_discovered_peripheral() {
    if (_newly_discovered_peripherals.is_empty()) return null;
    return _newly_discovered_peripherals.remove_first();
  }

  CBPeripheral* get_peripheral(NSUUID* address) {
    return _peripherals[address];
  }
  
 private:
  Mutex* _scan_mutex;
  ConditionVariable* _stop_scan_condition;
  bool _scan_active;
  CBCentralManager* _central_manager;
  DiscoveredPeripheralList _newly_discovered_peripherals;
  NSMutableDictionary<NSUUID*, CBPeripheral*>* _peripherals;
};

class BLEPeripheralManagerResource : public ServiceContainer<BLEPeripheralManagerResource> {
 public:
  TAG(BLEPeripheralManagerResource);
  
  explicit BLEPeripheralManagerResource(BLEResourceGroup *group) 
      : ServiceContainer(group, PERIPHERAL_MANAGER)
      , _peripheral_manager(nil)
      , _service_resource_index([[NSMutableDictionary new] retain]) {}

  ~BLEPeripheralManagerResource() override {
    if (_peripheral_manager != nil) {
      [_peripheral_manager release];
    }
    [_service_resource_index release];
  }
  
  CBPeripheralManager* peripheral_manager() const { return _peripheral_manager; }
  void set_peripheral_manager(CBPeripheralManager* peripheral_manager) { 
    _peripheral_manager = [peripheral_manager retain]; 
  }

  BLEPeripheralManagerResource* type() override {
    return this;
  }

 private:
  CBPeripheralManager* _peripheral_manager;
  NSMutableDictionary<CBUUID*, BLEResourceHolder*>* _service_resource_index;

};

BLECharacteristicResource* lookup_remote_characteristic_resource(CBPeripheral* peripheral, CBCharacteristic* characteristic);
BLECharacteristicResource* lookup_local_characteristic_resource(CBPeripheralManager* peripheral_manager, CBCharacteristic* characteristic);
}

@interface TOITPeripheralDelegate : NSObject <CBPeripheralDelegate>
@property toit::BLERemoteDeviceResource* device;

- (id)initWithDevice:(toit::BLERemoteDeviceResource*)gatt;
@end

@implementation TOITPeripheralDelegate
- (id)initWithDevice:(toit::BLERemoteDeviceResource*)gatt {
  self.device = gatt;
  return self;
}

- (void)peripheral:(CBPeripheral*)peripheral didDiscoverServices:(NSError*)error {
  if (peripheral.delegate != nil) {
    toit::BLERemoteDeviceResource* device = ((TOITPeripheralDelegate*) peripheral.delegate).device;
    toit::HostBLEEventSource::instance()->on_event(device, toit::kBLEServicesDiscovered);
  }
}

- (void)                  peripheral:(CBPeripheral*)peripheral
didDiscoverCharacteristicsForService:(CBService*)service
                               error:(NSError*)error {
  if (peripheral.delegate != nil) {
    toit::BLERemoteDeviceResource* device = ((TOITPeripheralDelegate*) peripheral.delegate).device;
    toit::BLEServiceResource* service_resource = device->get_or_create_service_resource(service);
    if (service_resource == null) return;
    toit::HostBLEEventSource::instance()->on_event(service_resource, toit::kBLECharacteristicsDiscovered);
  }
}

- (void)             peripheral:(CBPeripheral*)peripheral
didUpdateValueForCharacteristic:(CBCharacteristic*)characteristic
                          error:(NSError*)error {
  toit::BLECharacteristicResource* characteristic_resource
      = toit::lookup_remote_characteristic_resource(peripheral, characteristic);
  if (characteristic_resource == null) return;

  if (error != nil) {
    characteristic_resource->set_error(error);
    toit::HostBLEEventSource::instance()->on_event(characteristic_resource,
                                                   toit::kBLEValueDataReadFailed);
  } else {
    characteristic_resource->append_data(characteristic.value);
    toit::HostBLEEventSource::instance()->on_event(characteristic_resource,
                                                   toit::kBLEValueDataReady);
  }
}

- (void)            peripheral:(CBPeripheral*)peripheral
didWriteValueForCharacteristic:(CBCharacteristic*)characteristic
                         error:(NSError*)error {
  toit::BLECharacteristicResource* characteristic_resource
      = toit::lookup_remote_characteristic_resource(peripheral, characteristic);
  if (characteristic_resource == null) return;

  if (error != nil) {
    characteristic_resource->set_error(error);
    toit::HostBLEEventSource::instance()->on_event(characteristic_resource,
                                                   toit::kBLEValueWriteFailed);
  } else {
    toit::HostBLEEventSource::instance()->on_event(characteristic_resource,
                                                   toit::kBLEValueWriteSucceeded);
  }
}

- (void)peripheralIsReadyToSendWriteWithoutResponse:(CBPeripheral*)peripheral {
  if (peripheral.delegate != nil) {
    toit::BLERemoteDeviceResource* device = ((TOITPeripheralDelegate*) peripheral.delegate).device;
    toit::HostBLEEventSource::instance()->on_event(device, toit::kBLEReadyToSendWithoutResponse);
  }
}

- (void)                         peripheral:(CBPeripheral*)peripheral
didUpdateNotificationStateForCharacteristic:(CBCharacteristic*)characteristic
                                      error:(NSError*)error {
  toit::BLECharacteristicResource* characteristic_resource
      = toit::lookup_remote_characteristic_resource(peripheral, characteristic);
  if (characteristic_resource == null) return;

  if (error != null) {
    characteristic_resource->set_error(error);
    toit::HostBLEEventSource::instance()->on_event(characteristic_resource,
                                                   toit::kBLESubscriptionOperationFailed);
  } else {
    toit::HostBLEEventSource::instance()->on_event(characteristic_resource,
                                                   toit::kBLESubscriptionOperationSucceeded);
  }
}

@end

@interface TOITCentralManagerDelegate : NSObject <CBCentralManagerDelegate>
@property toit::BLECentralManagerResource* central_manager;

- (id)initWithCentralManagerResource:(toit::BLECentralManagerResource*)central_manager;
@end

@implementation TOITCentralManagerDelegate
- (id)initWithCentralManagerResource:(toit::BLECentralManagerResource*)central_manager {
  self.central_manager = central_manager;
  return self;
}

- (void)centralManagerDidUpdateState:(CBCentralManager*)central {
  switch (central.state) {
    case CBManagerStateUnknown:
    case CBManagerStateResetting:
    case CBManagerStateUnsupported:
    case CBManagerStateUnauthorized:
    case CBManagerStatePoweredOff:
      break;
    case CBManagerStatePoweredOn:
      printf("cm started\n");
      toit::HostBLEEventSource::instance()->on_event(self.central_manager, toit::kBLEStarted);
      break;
  }
}

- (void)centralManager:(CBCentralManager*)central
 didDiscoverPeripheral:(CBPeripheral*)peripheral
     advertisementData:(NSDictionary<NSString*, id>*)advertisementData
                  RSSI:(NSNumber*)rssi {
  auto discovered_peripheral = new toit::DiscoveredPeripheral(
      peripheral,
      rssi,
      advertisementData[CBAdvertisementDataServiceUUIDsKey],
      advertisementData[CBAdvertisementDataIsConnectable],
      advertisementData[CBAdvertisementDataManufacturerDataKey]);
  self.central_manager->add_discovered_peripheral(discovered_peripheral);
}

- (void)centralManager:(CBCentralManager*)central didConnectPeripheral:(CBPeripheral*)peripheral {
  if (peripheral.delegate != nil) {
    toit::HostBLEEventSource::instance()->on_event(((TOITPeripheralDelegate*) peripheral.delegate).device,
                                                   toit::kBLEConnected);
  }
}

- (void)centralManager:(CBCentralManager*)central didFailToConnectPeripheral:(CBPeripheral*)peripheral error:(NSError*)error {
  if (peripheral.delegate != nil) {
    toit::HostBLEEventSource::instance()->on_event(((TOITPeripheralDelegate*) peripheral.delegate).device,
                                                   toit::kBLEConnectFailed);
    [peripheral.delegate release];
    peripheral.delegate = nil;
  }
}

- (void)centralManager:(CBCentralManager*)central didDisconnectPeripheral:(CBPeripheral*)peripheral error:(NSError*)error {
  if (peripheral.delegate != nil) {
    toit::HostBLEEventSource::instance()->on_event(((TOITPeripheralDelegate*) peripheral.delegate).device,
                                                   toit::kBLEDisconnected);
    [peripheral.delegate release];
    peripheral.delegate = nil;
  }
}
@end

@interface TOITPeripheralManagerDelegate : NSObject <CBPeripheralManagerDelegate>
@property toit::BLEPeripheralManagerResource* peripheral_manager;
- (id)initWithPeripheralManagerResource:(toit::BLEPeripheralManagerResource*)peripheral_manager;
@end

@implementation TOITPeripheralManagerDelegate
- (id)initWithPeripheralManagerResource:(toit::BLEPeripheralManagerResource*)peripheral_manager {
  self.peripheral_manager = peripheral_manager;
  return self;
}

- (void)peripheralManagerDidUpdateState:(CBPeripheralManager*)peripheral {
  switch (peripheral.state) {
    case CBManagerStateUnknown:
    case CBManagerStateResetting:
    case CBManagerStateUnsupported:
    case CBManagerStateUnauthorized:
    case CBManagerStatePoweredOff:
      break;
    case CBManagerStatePoweredOn:
      toit::HostBLEEventSource::instance()->on_event(self.peripheral_manager, toit::kBLEStarted);
      break;
  }
}

- (void)peripheralManagerDidStartAdvertising:(CBPeripheralManager*)peripheral error:(NSError*)error {
  NSLog(@"Started adv");
  if (error) {
    NSLog(@"%@",error);
    toit::HostBLEEventSource::instance()->on_event(self.peripheral_manager, toit::kBLEAdvertiseStartFailed);
  } else {
    toit::HostBLEEventSource::instance()->on_event(self.peripheral_manager, toit::kBLEAdvertiseStartSucceeded);
  }
}

- (void)peripheralManager:(CBPeripheralManager*)peripheral didAddService:(CBService*)service error:(NSError*)error {
  toit::BLEServiceResource* service_resource = self.peripheral_manager->get_or_create_service_resource(service);
  if (error) {
    NSLog(@"%@",error);
    toit::HostBLEEventSource::instance()->on_event(service_resource, toit::kBLEServiceAddFailed);
  } else {
    toit::HostBLEEventSource::instance()->on_event(service_resource, toit::kBLEServiceAddSucceeded);
  }
}

- (void)peripheralManager:(CBPeripheralManager*)peripheral
  didReceiveWriteRequests:(NSArray<CBATTRequest*>*)requests {
  for (int i = 0; i < [requests count]; i++) {
    CBATTRequest* request = requests[i];
    toit::BLECharacteristicResource* characteristic_resource = 
        toit::lookup_local_characteristic_resource(peripheral, request.characteristic);
    
    characteristic_resource->append_data(request.value);
    toit::HostBLEEventSource::instance()->on_event(characteristic_resource, toit::kBLEDataReceived);
  }
}

- (void)     peripheralManager:(CBPeripheralManager*)peripheral
                       central:(CBCentral*)central
  didSubscribeToCharacteristic:(CBCharacteristic*)characteristic {
  toit::BLECharacteristicResource* characteristic_resource =
      toit::lookup_local_characteristic_resource(peripheral, characteristic);
  characteristic_resource->set_mtu(static_cast<int>(central.maximumUpdateValueLength));
}

@end

@interface BLEResourceHolder: NSObject
@property toit::BLEResource* resource;
- (id)initWithResource:(toit::BLEResource*)resource;
@end
@implementation BLEResourceHolder
- (id)initWithResource:(toit::BLEResource*)resource {
  self.resource = resource;
  return self;
}
@end

namespace toit {

BLECharacteristicResource* lookup_remote_characteristic_resource(CBPeripheral* peripheral, CBCharacteristic* characteristic) {
  if (peripheral.delegate == nil) return null;

  toit::BLERemoteDeviceResource* device = ((TOITPeripheralDelegate*) peripheral.delegate).device;
  toit::BLEServiceResource* service = device->get_or_create_service_resource(characteristic.service);
  if (service == null) return null;

  toit::BLECharacteristicResource* characteristic_resource
      = service->get_or_create_characteristics_resource(characteristic);
  return characteristic_resource;
}

BLECharacteristicResource* lookup_local_characteristic_resource(CBPeripheralManager* peripheral_manager, CBCharacteristic* characteristic) {
  if (peripheral_manager.delegate == nil) return null;

  toit::BLEPeripheralManagerResource* peripheral_manager_resource = ((TOITPeripheralManagerDelegate*) peripheral_manager.delegate).peripheral_manager;
  toit::BLEServiceResource* service = peripheral_manager_resource->get_or_create_service_resource(characteristic.service);
  if (service == null) return null;

  toit::BLECharacteristicResource* characteristic_resource
      = service->get_or_create_characteristics_resource(characteristic);
  return characteristic_resource;
}

template <typename T>
BLEServiceResource* ServiceContainer<T>::get_or_create_service_resource(CBService* service, bool can_create) {
  BLEResourceHolder* holder = _service_resource_index[[service UUID]];
  if (holder != nil) return reinterpret_cast<BLEServiceResource*>(holder.resource);
  if (!can_create) return null;

  auto resource = _new BLEServiceResource(group(), type(), service);
  resource_group()->register_resource(resource);
  _service_resource_index[[service UUID]] = [[[BLEResourceHolder alloc] initWithResource:resource] retain];
  return resource;
}

BLECharacteristicResource* BLEServiceResource::get_or_create_characteristics_resource(
    CBCharacteristic* characteristic,
    bool can_create) {
  BLEResourceHolder* holder = _characteristics_resource_index[[characteristic UUID]];
  if (holder != nil) return reinterpret_cast<BLECharacteristicResource*>(holder.resource);
  if (!can_create) return null;

  auto resource = _new BLECharacteristicResource(group(), this, characteristic);
  resource_group()->register_resource(resource);
  _characteristics_resource_index[[characteristic UUID]] = [[[BLEResourceHolder alloc] initWithResource:resource] retain];
  return resource;
}


NSString* ns_string_from_blob(Blob &blob) {
  return [[NSString alloc]
      initWithBytes:blob.address()
             length:blob.length()
           encoding:NSUTF8StringEncoding];
}

CBUUID* cb_uuid_from_blob(Blob &blob) {
  return [CBUUID UUIDWithString:ns_string_from_blob(blob)];
}

NSArray<CBUUID*>* ns_uuid_array_from_array_of_strings(Process* process, Array* array, Error** err) {
  NSMutableArray<CBUUID*>* service_uuids = nil;
  *err = null;
  if (array->length()) {
    service_uuids = [[NSMutableArray alloc] initWithCapacity:array->length()];
    for (int i = 0; i < array->length(); i++) {
      Blob blob;
      Object* obj = array->at(i);
      if (!obj->byte_content(process->program(), &blob, STRINGS_OR_BYTE_ARRAYS)) {
        *err = Error::from(process->program()->wrong_object_type());
        return nil;
      }
      service_uuids[i] = cb_uuid_from_blob(blob);
    }
    return service_uuids;
  }
  return nil;
}

class AsyncThread : public Thread {
 public:
  explicit AsyncThread(std::function<void()> func) : Thread("async"), _func(std::move(func)) {
    spawn();
  }

 protected:
  void entry() override {
    _func();
    delete this;
  }

 private:
  const std::function<void()> _func;
};

static void run_async(const std::function<void()> &func) {
  _new AsyncThread(func);
}

MODULE_IMPLEMENTATION(ble, MODULE_BLE)

PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  auto group = _new BLEResourceGroup(process);
  proxy->set_external_address(group);

  return proxy;
}


PRIMITIVE(create_central_manager) {
  ARGS(BLEResourceGroup, group);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  BLECentralManagerResource* central_manager_resource = _new BLECentralManagerResource(group);
  group->register_resource(central_manager_resource);

  auto _centralManagerQueue =
      dispatch_queue_create("toit.centralManagerQueue", DISPATCH_QUEUE_SERIAL);
  TOITCentralManagerDelegate* delegate = 
      [[TOITCentralManagerDelegate alloc] 
          initWithCentralManagerResource:central_manager_resource];
  CBCentralManager* central_manager =
      [[CBCentralManager alloc]
          initWithDelegate:delegate
                     queue:_centralManagerQueue
                   options:nil];

  central_manager_resource->set_central_manager(central_manager);
  proxy->set_external_address(central_manager_resource);
  return proxy;
}

PRIMITIVE(create_peripheral_manager) {
  ARGS(BLEResourceGroup, group);
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;
  
  BLEPeripheralManagerResource *peripheral_manager_resource = _new BLEPeripheralManagerResource(group);
  group->register_resource(peripheral_manager_resource);

  auto peripheral_manager_queue =
      dispatch_queue_create("toit.peripheralManagerQueue", DISPATCH_QUEUE_SERIAL);
  TOITPeripheralManagerDelegate* delegate = 
      [[TOITPeripheralManagerDelegate alloc] 
           initWithPeripheralManagerResource:peripheral_manager_resource];
  CBPeripheralManager* peripheral_manager =
      [[CBPeripheralManager alloc]
          initWithDelegate:delegate
                     queue:peripheral_manager_queue
                   options:nil];

  peripheral_manager_resource->set_peripheral_manager(peripheral_manager);
  proxy->set_external_address(peripheral_manager_resource);
  return proxy;
}

PRIMITIVE(close) {
  ARGS(BLEResourceGroup, group);
  group->tear_down();
  group_proxy->clear_external_address();
  return process->program()->null_object();
}

PRIMITIVE(scan_start) {
  ARGS(BLECentralManagerResource, central_manager, int64, duration_us);

  Locker locker(central_manager->scan_mutex());
  bool active = [central_manager->central_manager() isScanning];

  if (active || central_manager->scan_active()) ALREADY_IN_USE;
  central_manager->set_scan_active(true);
  [central_manager->central_manager() scanForPeripheralsWithServices:nil options:nil];

  run_async([=]() -> void {
    LightLocker locker(central_manager->scan_mutex());
    OS::wait_us(central_manager->stop_scan_condition(), duration_us);
    [central_manager->central_manager() stopScan];
    central_manager->set_scan_active(false);
    HostBLEEventSource::instance()->on_event(central_manager, kBLECompleted);
  });

  return process->program()->null_object();
}

PRIMITIVE(scan_next) {
  ARGS(BLECentralManagerResource, central_manager);

  DiscoveredPeripheral* peripheral = central_manager->next_discovered_peripheral();
  if (!peripheral) return process->program()->null_object();

  Array* array = process->object_heap()->allocate_array(6, process->program()->null_object());
  if (!array) ALLOCATION_FAILED;

  const char* address = [[[peripheral->peripheral() identifier] UUIDString] UTF8String];
  Error* err = null;
  String* address_str = process->allocate_string(address, &err);
  if (address_str == null) {
    delete peripheral;
    return err;
  }
  array->at_put(0, address_str);

  array->at_put(1, Smi::from([peripheral->rssi() shortValue]));

  NSString* identifier = [peripheral->peripheral() name];
  if (identifier != nil) {
    String* identifier_str = process->allocate_string([identifier UTF8String], &err);
    if (identifier_str == null) {
      free(peripheral);
      return err;
    }
    array->at_put(2, identifier_str);
  }

  NSArray* discovered_services = peripheral->services();
  if (discovered_services != nil) {
    Array* service_classes = process->object_heap()->allocate_array(
        static_cast<int>([discovered_services count]),
        process->program()->null_object());

    for (int i = 0; i < [discovered_services count]; i++) {
      String* uuid = process->allocate_string([[discovered_services[i] UUIDString] UTF8String], &err);
      if (uuid == null) {
        free(peripheral);
        return err;
      }
      service_classes->at_put(i, uuid);
    }
    array->at_put(3, service_classes);
  }

  NSData* manufacturer_data = peripheral->manufacturer_data();
  if (manufacturer_data != nil) {
    ByteArray* custom_data = process->object_heap()->allocate_internal_byte_array(
        static_cast<int>([manufacturer_data length]));
    ByteArray::Bytes custom_data_bytes(custom_data);
    if (!custom_data) ALLOCATION_FAILED;
    memcpy(custom_data_bytes.address(), manufacturer_data.bytes, [manufacturer_data length]);

    array->at_put(4, custom_data);
  }

  NSNumber* is_connectable = peripheral->connectable();
  array->at_put(5, (is_connectable != nil && is_connectable.boolValue == YES)
                   ? process->program()->true_object()
                   : process->program()->false_object());

  delete peripheral;

  return array;
}

PRIMITIVE(scan_stop) {
  ARGS(BLECentralManagerResource, central_manager);
  Locker locker(central_manager->scan_mutex());

  if (central_manager->scan_active()) {
    OS::signal(central_manager->stop_scan_condition());
  }

  return process->program()->null_object();
}

PRIMITIVE(connect) {
  ARGS(BLECentralManagerResource, central_manager, Blob, address);

  NSUUID* uuid = [[NSUUID alloc] initWithUUIDString:ns_string_from_blob(address)];

  CBPeripheral* peripheral = central_manager->get_peripheral(uuid);
  if (peripheral == nil) INVALID_ARGUMENT;

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (!proxy) ALLOCATION_FAILED;

  auto device =
      _new BLERemoteDeviceResource(
          central_manager->group(),
          central_manager->central_manager(),
          peripheral);

  central_manager->group()->register_resource(device);
  proxy->set_external_address(device);

  peripheral.delegate = [[[TOITPeripheralDelegate alloc] initWithDevice:device] retain];
  [central_manager->central_manager() connectPeripheral:peripheral options:nil];

  return proxy;
}

PRIMITIVE(disconnect) {
  ARGS(BLERemoteDeviceResource, device);

  [device->central_manager() cancelPeripheralConnection:device->peripheral()];

  return process->program()->null_object();
}

PRIMITIVE(release_resource) {
  ARGS(Resource, resource);

  resource->resource_group()->unregister_resource(resource);

  return process->program()->null_object();
}

PRIMITIVE(discover_services) {
  ARGS(BLERemoteDeviceResource, device, Array, raw_service_uuids);

  Error* err;
  NSArray<CBUUID*>* service_uuids = ns_uuid_array_from_array_of_strings(process, raw_service_uuids, &err);
  if (err) return err;
  [device->peripheral() discoverServices:service_uuids];

  return process->program()->null_object();
}

PRIMITIVE(discover_services_result) {
  ARGS(BLERemoteDeviceResource, device);

  NSArray<CBService*>* services = [device->peripheral() services];

  Array* array = process->object_heap()->allocate_array(
      static_cast<int>([services count]),
      process->program()->null_object());
  if (array == null) ALLOCATION_FAILED;

  for (int i = 0; i < [services count]; i++) {
    Error* err = null;
    String* uuid_str = process->allocate_string([[services[i].UUID UUIDString] UTF8String], &err);
    if (uuid_str == null) return err;
    
    Array* service_info = process->object_heap()->allocate_array(2, process->program()->null_object());
    if (service_info == null) ALLOCATION_FAILED;

    ByteArray* proxy = process->object_heap()->allocate_proxy();
    if (proxy == null) ALLOCATION_FAILED;

    service_info->at_put(0, uuid_str);
    service_info->at_put(1, proxy);
    array->at_put(i, service_info);
  }

  // Second loop to do heap allocations, this way there is no need to do clean up on ALLOCATION_FAILED
  for (int i = 0; i < [services count]; i++) {
    BLEServiceResource* service_resource = device->get_or_create_service_resource(services[i], true);
    auto proxy = reinterpret_cast<ByteArray*>(reinterpret_cast<Array*>(array->at(i))->at(1));
    proxy->set_external_address(service_resource);
  }

  return array;
}

PRIMITIVE(discover_characteristics) {
  ARGS(BLEServiceResource, service, Array, raw_characteristics_uuids);

  if (!service->device()) INVALID_ARGUMENT;

  Error* err;
  NSArray<CBUUID*>* characteristics_uuids = ns_uuid_array_from_array_of_strings(process, raw_characteristics_uuids,
                                                                                &err);
  if (err) return err;

  [service->device()->peripheral() discoverCharacteristics:characteristics_uuids forService:service->service()];

  return process->program()->null_object();
}

PRIMITIVE(discover_characteristics_result) {
  ARGS(BLEServiceResource, service);

  NSArray<CBCharacteristic*>* characteristics = [service->service() characteristics];

  Array* array = process->object_heap()->allocate_array(
      static_cast<int>([characteristics count]),
      process->program()->null_object());
  if (!array) ALLOCATION_FAILED;

  for (int i = 0; i < [characteristics count]; i++) {
    Error* err = null;
    String* uuid_str = process->allocate_string([[characteristics[i].UUID UUIDString] UTF8String], &err);
    if (uuid_str == null) return err;

    uint16_t flags = characteristics[i].properties;

    Array* characteristic_data = process->object_heap()->allocate_array(
        3, process->program()->null_object());
    if (!characteristic_data) ALLOCATION_FAILED;

    array->at_put(i, characteristic_data);

    ByteArray* proxy = process->object_heap()->allocate_proxy();
    if (proxy == null) ALLOCATION_FAILED;

    characteristic_data->at_put(0, uuid_str);
    characteristic_data->at_put(1, Smi::from(flags));
    characteristic_data->at_put(2, proxy);
  }

  for (int i = 0; i < [characteristics count]; i++) {
    BLECharacteristicResource* characteristic_resource
        = service->get_or_create_characteristics_resource(characteristics[i], true);
    auto proxy = reinterpret_cast<ByteArray*>(reinterpret_cast<Array*>(array->at(i))->at(2));
    proxy->set_external_address(characteristic_resource);
  }

  return array;
}

PRIMITIVE(discover_descriptors) {
  UNIMPLEMENTED_PRIMITIVE;
}

PRIMITIVE(discover_descriptors_result) {
  UNIMPLEMENTED_PRIMITIVE;
}

PRIMITIVE(request_characteristic_read) {
  ARGS(BLECharacteristicResource, characteristic);

  [characteristic->characteristic().service.peripheral readValueForCharacteristic:characteristic->characteristic()];

  return process->program()->null_object();
}

PRIMITIVE(get_characteristic_value) {
  ARGS(BLECharacteristicResource, characteristic);

  CharacteristicData* data = characteristic->remove_first();
  if (!data) return process->program()->null_object();

  ByteArray* byte_array = process->object_heap()->allocate_internal_byte_array(
      static_cast<int>([data->data() length]));

  if (!byte_array) {
    characteristic->put_back(data);
    ALLOCATION_FAILED;
  }

  ByteArray::Bytes bytes(byte_array);
  memcpy(bytes.address(), data->data().bytes, [data->data() length]);
  delete data;

  return byte_array;
}

PRIMITIVE(get_characteristic_error) {
  ARGS(BLECharacteristicResource, characteristic);
  if (characteristic->error() == nil) OTHER_ERROR;
  Error* err = null;
  String* message = process->allocate_string(
      [characteristic->error().localizedDescription UTF8String], &err);
  if (err) return err;

  characteristic->set_error(nil);

  return message;
}

PRIMITIVE(write_characteristic_value) {
  ARGS(BLECharacteristicResource, characteristic, Object, value, bool, with_response);

  Blob bytes;
  if (!value->byte_content(process->program(), &bytes, STRINGS_OR_BYTE_ARRAYS)) WRONG_TYPE;

  if (!with_response) {
    if (!characteristic->characteristic().service.peripheral.canSendWriteWithoutResponse)
      return Smi::from(2);
  }

  NSData* data = [[NSData alloc] initWithBytes: bytes.address() length: bytes.length()];
  [characteristic->characteristic().service.peripheral
          writeValue:data
   forCharacteristic:characteristic->characteristic()
                type:(with_response
                   ? CBCharacteristicWriteWithResponse
                   : CBCharacteristicWriteWithoutResponse)];

  return Smi::from(with_response ? 1 : 0);
}

PRIMITIVE(set_characteristic_notify) {
  ARGS(BLECharacteristicResource, characteristic, bool, enable);

  [characteristic->characteristic().service.peripheral
      setNotifyValue:enable
   forCharacteristic:characteristic->characteristic()];

  return process->program()->null_object();
}

PRIMITIVE(advertise_start) {
  ARGS(BLEPeripheralManagerResource, peripheral_manager, Blob, name, Array, service_classes,
       Blob, manufacturing_data, int, interval_us, int, conn_mode);
  USE(interval_us);
  USE(conn_mode);

  NSMutableDictionary* data = [NSMutableDictionary new];

  if (manufacturing_data.length()>0) INVALID_ARGUMENT;

  if (name.length() > 0) {
    data[CBAdvertisementDataLocalNameKey] = ns_string_from_blob(name);
  }


  if (service_classes->length() > 0) {
    Error* err;
    data[CBAdvertisementDataServiceUUIDsKey] = ns_uuid_array_from_array_of_strings(process, service_classes, &err);
    if (err) return err;
  }

  [peripheral_manager->peripheral_manager() startAdvertising:data];

  return process->program()->null_object();
}

PRIMITIVE(advertise_stop) {
  ARGS(BLEPeripheralManagerResource, peripheral_manager);

  [peripheral_manager->peripheral_manager() stopAdvertising];

  return process->program()->null_object();
}

PRIMITIVE(add_service) {
  ARGS(BLEPeripheralManagerResource, peripheral_manager, Blob, uuid);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  CBUUID* cb_uuid = cb_uuid_from_blob(uuid);

  CBMutableService* service = [[CBMutableService alloc] initWithType:cb_uuid primary:TRUE];

  BLEServiceResource* service_resource =
    peripheral_manager->get_or_create_service_resource(service, true);

  proxy->set_external_address(service_resource);
  return proxy;
}

PRIMITIVE(add_service_characteristic) {
  ARGS(BLEServiceResource, service_resource, Blob, raw_uuid, int, properties, int, permissions, Object, value);

  if (!service_resource->peripheral_manager()) INVALID_ARGUMENT;

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  if (service_resource->deployed()) INVALID_ARGUMENT;

  CBUUID* uuid = cb_uuid_from_blob(raw_uuid);

  NSData* data = nil;
  Blob bytes;
  if (!value->byte_content(process->program(), &bytes, STRINGS_OR_BYTE_ARRAYS)) WRONG_TYPE;
  if (bytes.length()) {
    data = [[NSData alloc] initWithBytes:bytes.address() length:bytes.length()];
  }

  CBMutableCharacteristic* characteristic =
      [[CBMutableCharacteristic alloc]
          initWithType:uuid
            properties:static_cast<CBCharacteristicProperties>(properties)
                 value:data
           permissions:static_cast<CBAttributePermissions>(permissions)];

  auto service = (CBMutableService*)service_resource->service();
  service.characteristics = [service.characteristics arrayByAddingObject:characteristic];

  BLECharacteristicResource* characteristic_resource
      = service_resource->get_or_create_characteristics_resource(characteristic, true);
  proxy->set_external_address(characteristic_resource);
  return proxy;
}

PRIMITIVE(deploy_service) {
  ARGS(BLEServiceResource, service_resource);

  if (!service_resource->peripheral_manager()) INVALID_ARGUMENT;
  if (service_resource->deployed()) INVALID_ARGUMENT;

  auto service = (CBMutableService*)service_resource->service();
  [service_resource->peripheral_manager()->peripheral_manager() addService:service];

  return process->program()->null_object();
}

PRIMITIVE(set_characteristics_value) {
  ARGS(BLECharacteristicResource, characteristic_resource, Object, value);
  Blob bytes;
  if (!value->byte_content(process->program(), &bytes, STRINGS_OR_BYTE_ARRAYS)) WRONG_TYPE;

  auto characteristic = (CBMutableCharacteristic*) characteristic_resource->characteristic();
  characteristic.value = [[NSData alloc] initWithBytes:bytes.address() length:bytes.length()];

  return process->program()->null_object();
}

PRIMITIVE(notify_characteristics_value) {
  ARGS(BLECharacteristicResource, characteristic_resource, Object, value);
  BLEPeripheralManagerResource *peripheral_manager = characteristic_resource->service()->peripheral_manager();
  if (!peripheral_manager) WRONG_TYPE;

  Blob bytes;
  if (!value->byte_content(process->program(), &bytes, STRINGS_OR_BYTE_ARRAYS)) WRONG_TYPE;

  auto characteristic = (CBMutableCharacteristic*) characteristic_resource->characteristic();
  [peripheral_manager->peripheral_manager()
              updateValue:[[NSData alloc] initWithBytes:bytes.address() length:bytes.length()]
        forCharacteristic:characteristic
     onSubscribedCentrals:nil];
  return process->program()->null_object();
}

PRIMITIVE(get_att_mtu) {
  ARGS(BLECharacteristicResource, characteristic_resource);

  BLEPeripheralManagerResource *peripheral_manager = characteristic_resource->service()->peripheral_manager();
  if (peripheral_manager) {
    return Smi::from(characteristic_resource->mtu());
  } else {
    NSUInteger mtu = [characteristic_resource->service()->device()->peripheral()
                      maximumWriteValueLengthForType:CBCharacteristicWriteWithResponse];

    return Smi::from(static_cast<int>(mtu));
  }
}

PRIMITIVE(set_preferred_mtu) {
  // Ignore
  return process->program()->null_object();
}

}
