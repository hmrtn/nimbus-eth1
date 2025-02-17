# Nimbus - Portal Network
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  stew/shims/net,
  eth/keys,
  eth/p2p/discoveryv5/[enr, node, routing_table],
  eth/p2p/discoveryv5/protocol as discv5_protocol

proc localAddress*(port: int): Address =
  Address(ip: ValidIpAddress.init("127.0.0.1"), port: Port(port))

proc initDiscoveryNode*(rng: ref BrHmacDrbgContext,
    privKey: PrivateKey,
    address: Address,
    bootstrapRecords: openarray[Record] = [],
    localEnrFields: openarray[(string, seq[byte])] = [],
    previousRecord = none[enr.Record]()): discv5_protocol.Protocol =
  # set bucketIpLimit to allow bucket split
  let tableIpLimits = TableIpLimits(tableIpLimit: 1000,  bucketIpLimit: 24)

  result = newProtocol(privKey,
    some(address.ip),
    some(address.port), some(address.port),
    bindPort = address.port,
    bootstrapRecords = bootstrapRecords,
    localEnrFields = localEnrFields,
    previousRecord = previousRecord,
    tableIpLimits = tableIpLimits,
    rng = rng)

  result.open()

proc random*(T: type UInt256, rng: var BrHmacDrbgContext): T =
  var key: UInt256
  brHmacDrbgGenerate(addr rng, addr key, csize_t(sizeof(key)))

  key
