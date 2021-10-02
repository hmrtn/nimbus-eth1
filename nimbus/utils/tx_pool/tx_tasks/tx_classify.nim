# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Transaction Pool Tasklet: Classify Transactions
## ===============================================
##


import
  ../../../db/accounts_cache,
  ../../../forks,
  ../../../transaction,
  ../tx_dbhead,
  ../tx_desc,
  ../tx_info,
  ../tx_item,
  chronicles,
  eth/[common, keys]

logScope:
  topics = "tx-pool classify transaction"

# ------------------------------------------------------------------------------
# Private transaction validation helpers
# ------------------------------------------------------------------------------

proc checkTxBasic(xp: var TxPool; item: TxItemRef): bool {.inline.} =
  ## Inspired by `p2p/validate.validateTransaction()`
  ##
  ## Rejected transactions will go to the wastebasket
  ##
  if item.tx.txType == TxEip2930 and xp.dbHead.fork < FkBerlin:
    debug "invalid tx: Eip2930 Tx type detected before Berlin"
    return false

  if item.tx.txType == TxEip1559 and xp.dbHead.fork < FkLondon:
    debug "invalid tx: Eip1559 Tx type detected before London"
    return false

  let nonce = ReadOnlyStateDB(xp.dbHead.accDb).getNonce(item.sender)
  if item.tx.nonce < nonce:
    debug "invalid tx: account nonce mismatch",
      txNonce = item.tx.nonce,
      accountNonce = nonce
    return false

  if item.tx.gasLimit < item.tx.intrinsicGas(xp.dbHead.fork):
    debug "invalid tx: not enough gas to perform calculation",
      available = item.tx.gasLimit,
      require = item.tx.intrinsicGas(xp.dbHead.fork)
    return false

  true

proc checkTxFees(xp: var TxPool; item: TxItemRef): bool {.inline.} =
  ## Inspired by `p2p/validate.validateTransaction()`
  ##
  ## Rejected transactions will go to the queue(1) waiting for a change
  ## of parameters `gasLimit` and `baseFee`
  ##
  if xp.dbHead.trgGasLimit < item.tx.gasLimit:
    debug "invalid tx: gasLimit exceeded",
      maxLimit = xp.dbHead.trgGasLimit,
      gasLimit = item.tx.gasLimit
    return false

  # ensure that the user was willing to at least pay the base fee
  if item.tx.txType == TxLegacy:
    if item.tx.gasPrice < xp.dbHead.baseFee.int64:
      debug "invalid tx: legacy gasPrice is smaller than baseFee",
        gasPrice = item.tx.gasPrice,
        baseFee = xp.dbHead.baseFee
      return false
  else:
    if item.tx.maxFee < xp.dbHead.baseFee.int64:
      debug "invalid tx: maxFee is smaller than baseFee",
        maxFee = item.tx.maxFee,
        baseFee = baseFee
      return false
    # The total must be the larger of the two
    if item.tx.maxFee < item.tx.maxPriorityFee:
      debug "invalid tx: maxFee is smaller than maPriorityFee",
        maxFee = item.tx.maxFee,
        maxPriorityFee = item.tx.maxPriorityFee
      return false

  true

proc checkTxBalance(xp: var TxPool; item: TxItemRef): bool {.inline.} =
  ## Inspired by `p2p/validate.validateTransaction()`
  ##
  ## Function currently unused.
  ##
  let
    balance = ReadOnlyStateDB(xp.dbHead.accDb).getBalance(item.sender)
    gasCost = item.tx.gasLimit.u256 * item.tx.gasPrice.u256
  if balance < gasCost:
    debug "invalid tx: not enough cash for gas",
      available = balance,
      require = gasCost
    return false

  let balanceOffGasCost = balance - gasCost
  if balanceOffGasCost < item.tx.value:
    debug "invalid tx: not enough cash to send",
      available = balance,
      availableMinusGas = balanceOffGasCost,
      require = item.tx.value
    return false

  true

# ------------------------------------------------------------------------------
# Public functionss
# ------------------------------------------------------------------------------

proc classifyTxValid*(xp: var TxPool; item: TxItemRef): TxInfo =
  ## Check a raw transaction whether it should be accepted at all or
  ## re-jected right away.
  if not xp.checkTxBasic(item):
    return txInfoErrBasicValidatorFailed

  txInfoOk


proc classifyTxPending*(xp: var TxPool; item: TxItemRef): bool =
  ## Check whether a valid transaction is ready to be set `pending`.
  if item.tx.estimatedGasTip(xp.dbHead.baseFee) <= 0:
    return false

  if not xp.checkTxFees(item):
    return false

  #if not item.checkTxBalance(dbHead):
  #  return false

  true

# ------------------------------------------------------------------------------
# Public functionss
# ------------------------------------------------------------------------------
