//
/**
 *    Copyright (c) 2023 Project CHIP Authors
 *
 *    Licensed under the Apache License, Version 2.0 (the "License");
 *    you may not use this file except in compliance with the License.
 *    You may obtain a copy of the License at
 *
 *        http://www.apache.org/licenses/LICENSE-2.0
 *
 *    Unless required by applicable law or agreed to in writing, software
 *    distributed under the License is distributed on an "AS IS" BASIS,
 *    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *    See the License for the specific language governing permissions and
 *    limitations under the License.
 */

#import "MTRDevice_XPC.h"

// Need to move these to PCHs...
#import <Matter/MTRDefines.h>
#import <Matter/MTRDeviceControllerParameters.h>

#import "MTRDeviceController_Internal.h"

#import "MTRAsyncWorkQueue.h"
#import "MTRAttestationTrustStoreBridge.h"
#import "MTRBaseDevice_Internal.h"
#import "MTRCommissionableBrowser.h"
#import "MTRCommissionableBrowserResult_Internal.h"
#import "MTRCommissioningParameters.h"
#import "MTRConversion.h"
#import "MTRDefines_Internal.h"
#import "MTRDeviceAttestationDelegateBridge.h"
#import "MTRDeviceConnectionBridge.h"
#import "MTRDeviceController.h"
#import "MTRDeviceControllerDelegateBridge.h"
#import "MTRDeviceControllerFactory_Internal.h"
#import "MTRDeviceControllerLocalTestStorage.h"
#import "MTRDeviceControllerStartupParams.h"
#import "MTRDeviceControllerStartupParams_Internal.h"
#import "MTRDeviceController_Concrete.h"
#import "MTRDeviceController_XPC.h"
#import "MTRDeviceDataValidation.h"
#import "MTRDevice_Concrete.h"
#import "MTRDevice_Internal.h"
#import "MTRDevice_XPC_Internal.h"
#import "MTRError_Internal.h"
#import "MTRKeypair.h"
#import "MTRLogging_Internal.h"
#import "MTRMetricKeys.h"
#import "MTRMetricsCollector.h"
#import "MTRP256KeypairBridge.h"
#import "MTRPersistentStorageDelegateBridge.h"
#import "MTRServerEndpoint_Internal.h"
#import "MTRSetupPayload.h"
#import "MTRTimeUtils.h"
#import "MTRUnfairLock.h"
#import "NSDataSpanConversion.h"
#import "NSStringSpanConversion.h"

#include <atomic>
#include <dns_sd.h>
#include <string>

#import <os/lock.h>

#define MTR_DEVICE_SIMPLE_REMOTE_XPC_GETTER(NAME, TYPE, DEFAULT_VALUE, GETTER_NAME)                                                                            \
    MTR_SIMPLE_REMOTE_XPC_GETTER([(MTRDeviceController_XPC *) [self deviceController] xpcConnection], NAME, TYPE, DEFAULT_VALUE, GETTER_NAME, deviceController \
                                 : [[self deviceController] uniqueIdentifier] nodeID                                                                           \
                                 : [self nodeID])

#define MTR_DEVICE_COMPLEX_REMOTE_XPC_GETTER(SIGNATURE, TYPE, DEFAULT_VALUE, ADDITIONAL_ARGUMENTS)                                                                            \
    MTR_COMPLEX_REMOTE_XPC_GETTER([(MTRDeviceController_XPC *) [self deviceController] xpcConnection], SIGNATURE, TYPE, DEFAULT_VALUE, ADDITIONAL_ARGUMENTS, deviceController \
                                  : [[self deviceController] uniqueIdentifier] nodeID                                                                                         \
                                  : [self nodeID])

#define MTR_DEVICE_SIMPLE_REMOTE_XPC_COMMAND(METHOD_SIGNATURE, ADDITIONAL_ARGUMENTS)                                                                            \
    MTR_SIMPLE_REMOTE_XPC_COMMAND([(MTRDeviceController_XPC *) [self deviceController] xpcConnection], METHOD_SIGNATURE, ADDITIONAL_ARGUMENTS, deviceController \
                                  : [[self deviceController] uniqueIdentifier] nodeID                                                                           \
                                  : [self nodeID])

@implementation MTRDevice_XPC

@synthesize _internalState;

- (instancetype)initWithNodeID:(NSNumber *)nodeID controller:(MTRDeviceController_XPC *)controller
{
    if (self = [super initForSubclassesWithNodeID:nodeID controller:controller]) {
        // Nothing else to do, all set.
    }

    return self;
}

- (void)dealloc
{
    [self _setInternalState:nil];
}

- (NSString *)description
{
    NSString * wifi;
    NSString * thread;
    NSNumber * networkFeatures = [self._internalState objectForKey:kMTRDeviceInternalPropertyNetworkFeatures];

    if (networkFeatures == nil) {
        wifi = @"NO";
        thread = @"NO";
    } else {
        wifi = MTR_YES_NO(networkFeatures.unsignedLongLongValue & MTRNetworkCommissioningFeatureWiFiNetworkInterface);
        thread = MTR_YES_NO(networkFeatures.unsignedLongLongValue & MTRNetworkCommissioningFeatureThreadNetworkInterface);
    }

    // TODO: Add these to the description
    // MTR_OPTIONAL_ATTRIBUTE(kMTRDeviceInternalPropertyDeviceState, _internalDeviceStateForDescription, properties);
    // MTR_OPTIONAL_ATTRIBUTE(kMTRDeviceInternalPropertyLastSubscriptionAttemptWait, _lastSubscriptionAttemptWaitForDescription, properties);
    // MTR_OPTIONAL_ATTRIBUTE(kMTRDeviceInternalPropertyMostRecentReportTime, _mostRecentReportTimeForDescription, properties);
    // MTR_OPTIONAL_ATTRIBUTE(kMTRDeviceInternalPropertyLastSubscriptionFailureTime, _lastSubscriptionFailureTimeForDescription, properties);

    return [NSString
        stringWithFormat:@"<%@: %p, node: %016llX-%016llX (%llu), VID: %@, PID: %@, WiFi: %@, Thread: %@, controller: %@>",
        NSStringFromClass(self.class), self,
        _deviceController.compressedFabricID.unsignedLongLongValue,
        _nodeID.unsignedLongLongValue,
        _nodeID.unsignedLongLongValue,
        [self._internalState objectForKey:kMTRDeviceInternalPropertyKeyVendorID],
        [self._internalState objectForKey:kMTRDeviceInternalPropertyKeyProductID],
        wifi,
        thread,
        _deviceController.uniqueIdentifier];
}

- (nullable NSNumber *)vendorID
{
    return [[self._internalState objectForKey:kMTRDeviceInternalPropertyKeyVendorID] copy];
}

- (nullable NSNumber *)productID
{
    return [[self._internalState objectForKey:kMTRDeviceInternalPropertyKeyProductID] copy];
}

#pragma mark - Client Callbacks (MTRDeviceDelegate)

// required methods for MTRDeviceDelegates
- (oneway void)device:(NSNumber *)nodeID stateChanged:(MTRDeviceState)state
{
    if (!MTR_SAFE_CAST(nodeID, NSNumber)) {
        MTR_LOG_ERROR("%@ invalid device:stateChanged: nodeID: %@", self, nodeID);
        return;
    }

    MTR_LOG("%s", __PRETTY_FUNCTION__);
    [self _lockAndCallDelegatesWithBlock:^(id<MTRDeviceDelegate> delegate) {
        [delegate device:self stateChanged:state];
    }];
}

- (oneway void)device:(NSNumber *)nodeID receivedAttributeReport:(NSArray<MTRDeviceResponseValueDictionary> *)attributeReport
{
    if (!MTR_SAFE_CAST(nodeID, NSNumber)) {
        MTR_LOG_ERROR("%@ invalid device:receivedAttributeReport: nodeID: %@", self, nodeID);
        return;
    }

    if (!MTRAttributeReportIsWellFormed(attributeReport)) {
        MTR_LOG_ERROR("%@ invalid device:receivedAttributeReport: attributeReport: %@", self, attributeReport);
        return;
    }

    MTR_LOG("%s", __PRETTY_FUNCTION__);
    [self _lockAndCallDelegatesWithBlock:^(id<MTRDeviceDelegate> delegate) {
        [delegate device:self receivedAttributeReport:attributeReport];
    }];
}

- (oneway void)device:(NSNumber *)nodeID receivedEventReport:(NSArray<MTRDeviceResponseValueDictionary> *)eventReport
{
    if (!MTR_SAFE_CAST(nodeID, NSNumber)) {
        MTR_LOG_ERROR("%@ invalid device:receivedEventReport: nodeID: %@", self, nodeID);
        return;
    }

    if (!MTREventReportIsWellFormed(eventReport)) {
        MTR_LOG_ERROR("%@ invalid device:receivedEventReport: eventReport: %@", self, eventReport);
        return;
    }

    MTR_LOG("%s", __PRETTY_FUNCTION__);
    [self _lockAndCallDelegatesWithBlock:^(id<MTRDeviceDelegate> delegate) {
        [delegate device:self receivedEventReport:eventReport];
    }];
}

// optional methods for MTRDeviceDelegates - check for implementation before calling
- (oneway void)deviceBecameActive:(NSNumber *)nodeID
{
    if (!MTR_SAFE_CAST(nodeID, NSNumber)) {
        MTR_LOG_ERROR("%@ invalid deviceBecameActive: nodeID: %@", self, nodeID);
        return;
    }

    MTR_LOG("%s", __PRETTY_FUNCTION__);
    [self _lockAndCallDelegatesWithBlock:^(id<MTRDeviceDelegate> delegate) {
        if ([delegate respondsToSelector:@selector(deviceBecameActive:)]) {
            [delegate deviceBecameActive:self];
        }
    }];
}

- (oneway void)deviceCachePrimed:(NSNumber *)nodeID
{
    if (!MTR_SAFE_CAST(nodeID, NSNumber)) {
        MTR_LOG_ERROR("%@ invalid deviceCachePrimed: nodeID: %@", self, nodeID);
        return;
    }

    [self _lockAndCallDelegatesWithBlock:^(id<MTRDeviceDelegate> delegate) {
        if ([delegate respondsToSelector:@selector(deviceCachePrimed:)]) {
            [delegate deviceCachePrimed:self];
        }
    }];
}

- (oneway void)deviceConfigurationChanged:(NSNumber *)nodeID
{
    if (!MTR_SAFE_CAST(nodeID, NSNumber)) {
        MTR_LOG_ERROR("%@ invalid deviceConfigurationChanged: nodeID: %@", self, nodeID);
        return;
    }

    [self _lockAndCallDelegatesWithBlock:^(id<MTRDeviceDelegate> delegate) {
        if ([delegate respondsToSelector:@selector(deviceConfigurationChanged:)]) {
            [delegate deviceConfigurationChanged:self];
        }
    }];
}

static const auto * requiredInternalStateKeys = @[ kMTRDeviceInternalPropertyDeviceState, kMTRDeviceInternalPropertyLastSubscriptionAttemptWait ];
static const auto * optionalInternalStateKeys = @[ kMTRDeviceInternalPropertyKeyVendorID, kMTRDeviceInternalPropertyKeyProductID, kMTRDeviceInternalPropertyNetworkFeatures, kMTRDeviceInternalPropertyMostRecentReportTime, kMTRDeviceInternalPropertyLastSubscriptionFailureTime ];

- (BOOL)_internalState:(NSDictionary *)dictionary hasValidValuesForKeys:(const NSArray<NSString *> *)keys valueRequired:(BOOL)required
{
    // All the keys are NSNumber-valued.
    for (NSString * key in keys) {
        id value = dictionary[key];
        if (!value) {
            if (required) {
                MTR_LOG_ERROR("%@ device:internalStateUpdated: handed state with no value for \"%@\": %@", self, key, value);
                return NO;
            }

            continue;
        }
        if (!MTR_SAFE_CAST(value, NSNumber)) {
            MTR_LOG_ERROR("%@ device:internalStateUpdated: handed state with invalid value for \"%@\": %@", self, key, value);
            return NO;
        }
    }

    return YES;
}

- (oneway void)device:(NSNumber *)nodeID internalStateUpdated:(NSDictionary *)dictionary
{
    if (!MTR_SAFE_CAST(nodeID, NSNumber)) {
        MTR_LOG_ERROR("%@ invalid device:internalStateUpdated: nodeID: %@", self, nodeID);
        return;
    }

    if (!MTR_SAFE_CAST(dictionary, NSDictionary)) {
        MTR_LOG_ERROR("%@ invalid device:internalStateUpdated dictionary: %@", self, dictionary);
        return;
    }

    VerifyOrReturn([self _internalState:dictionary hasValidValuesForKeys:requiredInternalStateKeys valueRequired:YES]);
    VerifyOrReturn([self _internalState:dictionary hasValidValuesForKeys:optionalInternalStateKeys valueRequired:NO]);

    [self _setInternalState:dictionary];
    MTR_LOG("%@ internal state updated", self);
}

#pragma mark - Remote Commands

// TODO: Figure out how to validate the return values for the various
// MTR_DEVICE_*_XPC macros below.

MTR_DEVICE_SIMPLE_REMOTE_XPC_GETTER(state, MTRDeviceState, MTRDeviceStateUnknown, getStateWithReply)
MTR_DEVICE_SIMPLE_REMOTE_XPC_GETTER(deviceCachePrimed, BOOL, NO, getDeviceCachePrimedWithReply)
MTR_DEVICE_SIMPLE_REMOTE_XPC_GETTER(estimatedStartTime, NSDate * _Nullable, nil, getEstimatedStartTimeWithReply)
MTR_DEVICE_SIMPLE_REMOTE_XPC_GETTER(estimatedSubscriptionLatency, NSNumber * _Nullable, nil, getEstimatedSubscriptionLatencyWithReply)

typedef NSDictionary<NSString *, id> * _Nullable ReadAttributeResponseType;
MTR_DEVICE_COMPLEX_REMOTE_XPC_GETTER(readAttributeWithEndpointID
                                     : (NSNumber *) endpointID clusterID
                                     : (NSNumber *) clusterID attributeID
                                     : (NSNumber *) attributeID params
                                     : (MTRReadParams * _Nullable) params,
                                     ReadAttributeResponseType,
                                     nil,
                                     readAttributeWithEndpointID
                                     : endpointID clusterID
                                     : clusterID attributeID
                                     : attributeID params
                                     : params withReply)

MTR_DEVICE_SIMPLE_REMOTE_XPC_COMMAND(writeAttributeWithEndpointID
                                     : (NSNumber *) endpointID clusterID
                                     : (NSNumber *) clusterID attributeID
                                     : (NSNumber *) attributeID value
                                     : (id) value expectedValueInterval
                                     : (NSNumber *) expectedValueInterval timedWriteTimeout
                                     : (NSNumber * _Nullable) timeout, writeAttributeWithEndpointID
                                     : endpointID clusterID
                                     : clusterID attributeID
                                     : attributeID value
                                     : value expectedValueInterval
                                     : expectedValueInterval timedWriteTimeout
                                     : timeout)

typedef NSArray<NSDictionary<NSString *, id> *> * ReadAttributePathsResponseType;
MTR_DEVICE_COMPLEX_REMOTE_XPC_GETTER(readAttributePaths
                                     : (NSArray<MTRAttributeRequestPath *> *) attributePaths,
                                     ReadAttributePathsResponseType,
                                     [NSArray array], // Default return value
                                     readAttributePaths
                                     : attributePaths withReply)

- (void)_invokeCommandWithEndpointID:(NSNumber *)endpointID
                           clusterID:(NSNumber *)clusterID
                           commandID:(NSNumber *)commandID
                       commandFields:(MTRDeviceDataValueDictionary)commandFields
                      expectedValues:(NSArray<NSDictionary<NSString *, id> *> * _Nullable)expectedValues
               expectedValueInterval:(NSNumber * _Nullable)expectedValueInterval
                  timedInvokeTimeout:(NSNumber * _Nullable)timeout
         serverSideProcessingTimeout:(NSNumber * _Nullable)serverSideProcessingTimeout
                               queue:(dispatch_queue_t)queue
                          completion:(MTRDeviceResponseHandler)completion
{
    NSXPCConnection * xpcConnection = [(MTRDeviceController_XPC *) [self deviceController] xpcConnection];

    @try {
        [[xpcConnection remoteObjectProxyWithErrorHandler:^(NSError * _Nonnull error) {
            MTR_LOG_ERROR("Invoke error: %@", error);
            completion(nil, [NSError errorWithDomain:MTRErrorDomain code:MTRErrorCodeGeneralError userInfo:nil]);
        }] deviceController:[[self deviceController] uniqueIdentifier]
                                 nodeID:[self nodeID]
            invokeCommandWithEndpointID:endpointID
                              clusterID:clusterID
                              commandID:commandID
                          commandFields:commandFields
                         expectedValues:expectedValues
                  expectedValueInterval:expectedValueInterval
                     timedInvokeTimeout:timeout
            serverSideProcessingTimeout:serverSideProcessingTimeout
                             completion:^(NSArray<NSDictionary<NSString *, id> *> * _Nullable values, NSError * _Nullable error) {
                                 if (values == nil && error == nil) {
                                     MTR_LOG_ERROR("%@ got invoke response for (%@, %@, %@) without values or error", self, endpointID, clusterID, commandID);
                                     completion(nil, [MTRError errorForCHIPErrorCode:CHIP_ERROR_INVALID_ARGUMENT]);
                                     return;
                                 }

                                 if (error != nil && !MTR_SAFE_CAST(error, NSError)) {
                                     MTR_LOG_ERROR("%@ got invoke response for (%@, %@, %@) that has invalid error object: %@", self, endpointID, clusterID, commandID, error);
                                     completion(nil, [MTRError errorForCHIPErrorCode:CHIP_ERROR_INVALID_ARGUMENT]);
                                     return;
                                 }

                                 if (values != nil && !MTRInvokeResponseIsWellFormed(values)) {
                                     MTR_LOG_ERROR("%@ got invoke response for (%@, %@, %@) that has invalid data: %@", self, clusterID, commandID, values, values);
                                     completion(nil, [MTRError errorForCHIPErrorCode:CHIP_ERROR_INVALID_ARGUMENT]);
                                     return;
                                 }

                                 if (values != nil && error != nil) {
                                     MTR_LOG_ERROR("%@ got invoke response for (%@, %@, %@) with both values and error: %@, %@", self, endpointID, clusterID, commandID, values, error);
                                     // Just propagate through the error.
                                     completion(nil, error);
                                     return;
                                 }

                                 completion(values, error);
                             }];
    } @catch (NSException * exception) {
        MTR_LOG_ERROR("Exception sending XPC message: %@", exception);
        completion(nil, [NSError errorWithDomain:MTRErrorDomain code:MTRErrorCodeGeneralError userInfo:nil]);
    }
}

- (void)downloadLogOfType:(MTRDiagnosticLogType)type
                  timeout:(NSTimeInterval)timeout
                    queue:(dispatch_queue_t)queue
               completion:(void (^)(NSURL * _Nullable url, NSError * _Nullable error))completion
{
    NSXPCConnection * xpcConnection = [(MTRDeviceController_XPC *) [self deviceController] xpcConnection];

    @try {
        [[xpcConnection remoteObjectProxyWithErrorHandler:^(NSError * _Nonnull error) {
            MTR_LOG_ERROR("Error: %@", error);
            dispatch_async(queue, ^{
                completion(nil, [NSError errorWithDomain:MTRErrorDomain code:MTRErrorCodeGeneralError userInfo:nil]);
            });
        }] deviceController:[[self deviceController] uniqueIdentifier]
                       nodeID:[self nodeID]
            downloadLogOfType:type
                      timeout:timeout
                   completion:^(NSURL * _Nullable url, NSError * _Nullable error) {
                       dispatch_async(queue, ^{
                           completion(url, error);
                           if (url) {
                               [[NSFileManager defaultManager] removeItemAtPath:url.path error:nil];
                           }
                       });
                   }];
    } @catch (NSException * exception) {
        MTR_LOG_ERROR("Exception sending XPC messsage: %@", exception);
        dispatch_async(queue, ^{
            completion(nil, [NSError errorWithDomain:MTRErrorDomain code:MTRErrorCodeGeneralError userInfo:nil]);
        });
    }
}

// Not Supported via XPC
//- (oneway void)deviceController:(NSUUID *)controller nodeID:(NSNumber *)nodeID openCommissioningWindowWithSetupPasscode:(NSNumber *)setupPasscode discriminator:(NSNumber *)discriminator duration:(NSNumber *)duration completion:(MTRDeviceOpenCommissioningWindowHandler)completion;
//- (oneway void)deviceController:(NSUUID *)controller nodeID:(NSNumber *)nodeID openCommissioningWindowWithDiscriminator:(NSNumber *)discriminator duration:(NSNumber *)duration completion:(MTRDeviceOpenCommissioningWindowHandler)completion;

// Not Supported via XPC
// - (oneway void)downloadLogOfType:(MTRDiagnosticLogType)type nodeID:(NSNumber *)nodeID timeout:(NSTimeInterval)timeout completion:(void (^)(NSURL * _Nullable url, NSError * _Nullable error))completion;

@end
