# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Key Queue
## =========
##
## This module provides a keyed fifo or stack data structure similar to
## `DoublyLinkedList` but with efficient random data access for fetching
## and deletion. The underlying data structure is a hash table with data
## lookup and delete assumed to be O(1) in most cases (so long as the
## underlying hash table does not degrade into one-bucket linear mode, or
## some bucket-adjustment algorithm takes over.)
##
## For consistency with  other data types in Nim the queue has value
## semantics, this means that `=` performs a deep copy of the allocated queue
## which is refered to the deep copy semantics of underlying table driver.
##
## Rlp Support
## -----------
## This module supports *RLP* serialisation which needs to be enabled with
## the extra include directive
## ::
##   include keequ/kq_rlp
##
## This `kq_rlp` sub-module expects the RLP drivers configured/available and
## they will be imported from `eth/rlp`.
##
## Note that the underlying RLP driver does not support negative integers
## which causes problems when reading back. So these values should neither
## appear in any of the `K` (for key) or `V` (for value) data types (best
## to avoid `int` altogether if serialisation is needed.)
##

import
  std/[math, tables],
  stew/results

export
  results

type
  KeeQuInfo* = enum ##\
    ## Error messages as returned by `keeQuVerify()`
    keeQuOk = 0
    keeQuVfyFirstInconsistent
    keeQuVfyLastInconsistent
    keeQuVfyNoSuchTabItem
    keeQuVfyNoPrvTabItem
    keeQuVfyNxtPrvExpected
    keeQuVfyLastExpected
    keeQuVfyNoNxtTabItem
    keeQuVfyPrvNxtExpected
    keeQuVfyFirstExpected

  KeeQuItem*[K,V] = object ##\
    ## Data value container as stored in the queue.
    ## There is a special requirements for `KeeQuItem` terminal nodes:
    ## *prv == nxt* so that there is no dangling link. On the flip side,
    ## this requires some extra consideration when deleting the second node
    ## relative to either end.
    data*: V         ## Some data value, can freely be modified.
    kPrv*, kNxt*: K  ## Queue links, read-only.

  KeeQuPair*[K,V] = object ##\
    ## Key-value pair, typically used as return code.
    key: K      ## Sorter key (read-only for consistency with `SLstResult[K,V]`)
    data*: V    ## Some data value, to be modified freely

  KeeQuTab*[K,V] =
    Table[K,KeeQuItem[K,V]]

  KeeQu*[K,V] = object ##\
    ## Data queue descriptor
    tab*: KeeQuTab[K,V]   ## Data table
    kFirst*, kLast*: K    ## Doubly linked item list queue

  BlindValue = ##\
    ## Type name is syntactic sugar, used for key-only queues
    distinct byte

  KeeQuNV*[K] = ##\
    ## Key-only queue, no values
    KeeQu[K,BlindValue]

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc shiftImpl[K,V](rq: var KeeQu[K,V])
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Expects: rq.tab.len != 0

  # Unqueue first item
  let item = rq.tab[rq.kFirst] # yes, crashes if `rq.tab.len == 0`
  rq.tab.del(rq.kFirst)

  if rq.tab.len == 0:
    rq.kFirst.reset
    rq.kLast.reset
  else:
    rq.kFirst = item.kNxt
    if rq.tab.len == 1:
      rq.tab[rq.kFirst].kNxt = rq.kFirst            # node points to itself
    rq.tab[rq.kFirst].kPrv = rq.tab[rq.kFirst].kNxt # term node has: nxt == prv


proc popImpl[K,V](rq: var KeeQu[K,V])
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Expects: rq.tab.len != 0

  # Pop last item
  let item = rq.tab[rq.kLast] # yes, crashes if `rq.tab.len == 0`
  rq.tab.del(rq.kLast)

  if rq.tab.len == 0:
    rq.kFirst.reset
    rq.kLast.reset
  else:
    rq.kLast = item.kPrv
    if rq.tab.len == 1:
      rq.tab[rq.kLast].kPrv = rq.kLast            # single node points to itself
    rq.tab[rq.kLast].kNxt = rq.tab[rq.kLast].kPrv # term node has: nxt == prv


proc deleteImpl[K,V](rq: var KeeQu[K,V]; key: K)
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Expects: rq.tab.hesKey(key)

  if rq.kFirst == key:
    rq.shiftImpl

  elif rq.kLast == key:
    rq.popImpl

  else:
    let item = rq.tab[key] # yes, crashes if `not rq.tab.hasKey(key)`
    rq.tab.del(key)

    # now: 2 < rq.tab.len (otherwise rq.kFirst == key or rq.kLast == key)
    if rq.tab[rq.kFirst].kNxt == key:
      # item was the second one
      rq.tab[rq.kFirst].kPrv = item.kNxt
    if rq.tab[rq.kLast].kPrv == key:
      # item was one before last
      rq.tab[rq.kLast].kNxt = item.kPrv

    rq.tab[item.kPrv].kNxt = item.kNxt
    rq.tab[item.kNxt].kPrv = item.kPrv


proc appendImpl[K,V](rq: var KeeQu[K,V]; key: K; val: V)
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Expects: not rq.tab.hasKey(key)

  # Append queue item
  var item = KeeQuItem[K,V](data: val)

  if rq.tab.len == 0:
    rq.kFirst = key
    item.kPrv = key
  else:
    if rq.kFirst == rq.kLast:
      rq.tab[rq.kFirst].kPrv = key # first terminal node
    rq.tab[rq.kLast].kNxt = key
    item.kPrv = rq.kLast

  rq.kLast = key
  item.kNxt = item.kPrv # terminal node

  rq.tab[key] = item # yes, makes `verify()` fail if `rq.tab.hasKey(key)`


proc prependImpl[K,V](rq: var KeeQu[K,V]; key: K; val: V)
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Expects: not rq.tab.hasKey(key)

  # Prepend queue item
  var item = KeeQuItem[K,V](data: val)

  if rq.tab.len == 0:
    rq.kLast = key
    item.kNxt = key
  else:
    if rq.kFirst == rq.kLast:
      rq.tab[rq.kLast].kNxt = key # first terminal node
    rq.tab[rq.kFirst].kPrv = key
    item.kNxt = rq.kFirst

  rq.kFirst = key
  item.kPrv = item.kNxt # terminal node has: nxt == prv

  rq.tab[key] = item # yes, makes `verify()` fail if `rq.tab.hasKey(key)`

# -----------

proc shiftKeyImpl[K,V](rq: var KeeQu[K,V]): Result[K,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  if 0 < rq.tab.len:
    let key = rq.kFirst
    rq.shiftImpl
    return ok(key)
  err()

proc popKeyImpl[K,V](rq: var KeeQu[K,V]): Result[K,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  if 0 < rq.tab.len:
    let key = rq.kLast
    rq.popImpl
    return ok(key)
  err()

# -----------

proc firstKeyImpl[K,V](rq: var KeeQu[K,V]): Result[K,void] =
  if rq.tab.len == 0:
    return err()
  ok(rq.kFirst)

proc secondKeyImpl[K,V](rq: var KeeQu[K,V]): Result[K,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  if rq.tab.len < 2:
    return err()
  ok(rq.tab[rq.kFirst].kNxt)

proc beforeLastKeyImpl[K,V](rq: var KeeQu[K,V]): Result[K,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  if rq.tab.len < 2:
    return err()
  ok(rq.tab[rq.kLast].kPrv)

proc lastKeyImpl[K,V](rq: var KeeQu[K,V]): Result[K,void] =
  if rq.tab.len == 0:
    return err()
  ok(rq.kLast)

proc nextKeyImpl[K,V](rq: var KeeQu[K,V]; key: K): Result[K,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  if not rq.tab.hasKey(key) or rq.kLast == key:
    return err()
  ok(rq.tab[key].kNxt)

proc prevKeyImpl[K,V](rq: var KeeQu[K,V]; key: K): Result[K,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  if not rq.tab.hasKey(key) or rq.kFirst == key:
    return err()
  ok(rq.tab[key].kPrv)

# ------------------------------------------------------------------------------
# Public functions, constructor
# ------------------------------------------------------------------------------

proc init*[K,V](rq: var KeeQu[K,V]; initSize = 10) =
  ## Optional initaliser for queue setting inital size for underlying
  ## table object.
  rq.tab = initTable[K,KeeQuItem[K,V]](initSize.nextPowerOfTwo)

proc init*[K,V](T: type KeeQu[K,V]; initSize = 10): T =
  ## Initaliser variant.
  result.init(initSize)

proc init*[K](rq: var KeeQuNV[K]; initSize = 10) =
  ## Key only queue
  rq.tab = initTable[K,KeeQuItem[K,BlindValue]](initSize.nextPowerOfTwo)

proc init*[K](T: type KeeQuNV[K]; initSize = 10): T =
  ## Initaliser variant.
  result.init(initSize)

# ------------------------------------------------------------------------------
# Public functions, list operations
# ------------------------------------------------------------------------------

proc append*[K,V](rq: var KeeQu[K,V]; key: K; val: V): bool
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Append new `key`. The function will succeed returning `true` unless the
  ## `key` argument exists in the queue,  already.
  ##
  ## All the items on the queue different from the one just added are
  ## called *previous* or *left hand* items.
  if not rq.tab.hasKey(key):
    rq.appendImpl(key, val)
    return true

template push*[K,V](rq: var KeeQu[K,V]; key: K; val: V): bool =
  ## Same as `append()`
  rq.append(key, val)


proc replace*[K,V](rq: var KeeQu[K,V]; key: K; val: V): bool
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Replace value for entry associated with the key argument `key`. Returns
  ## `true` on success, and `false` otherwise.
  if rq.tab.hasKey(key):
    rq.tab[key].data = val
    return true

proc `[]=`*[K,V](rq: var KeeQu[K,V]; key: K; val: V)
    {.gcsafe,raises: [Defect,KeyError].} =
  ## This function provides a combined append/replace action with table
  ## semantics:
  ## * If the argument `key` is not in the queue yet, append the `(key,val)`
  ##   pair as in `rq.append(key,val)`
  ## * Otherwise replace the value entry of the queue item by the argument
  ##   `val` as in `rq.replace(key,val)`
  if rq.tab.hasKey(key):
    rq.tab[key].data = val
  else:
    rq.appendImpl(key, val)


proc prepend*[K,V](rq: var KeeQu[K,V]; key: K; val: V): bool
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Prepend new `key`. The function will succeed returning `true` unless the
  ## `key` argument exists in the queue, already.
  ##
  ## All the items on the queue different from the item just added are
  ## called *following* or *right hand* items.
  if not rq.tab.hasKey(key):
    rq.prependImpl(key, val)
    return true

template unshift*[K,V](rq: var KeeQu[K,V]; key: K; val: V): bool =
  ## Same as `prepend()`
  rq.prepend(key,val)


proc shift*[K,V](rq: var KeeQu[K,V]): Result[KeeQuPair[K,V],void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Deletes the *first* queue item and returns the key-value item pair just
  ## deleted. For a non-empty queue this function is the same as
  ## `rq.firstKey.value.delele`.
  ##
  ## Using the notation introduced with `rq.append` and `rq.prepend`, the
  ## item returned and deleted is the most *left hand* item.
  if 0 < rq.tab.len:
    let kvp = KeeQuPair[K,V](
      key: rq.kFirst,
      data: rq.tab[rq.kFirst].data)
    rq.shiftImpl
    return ok(KeeQuPair[K,V](kvp))
  err()

proc shiftKey*[K,V](rq: var KeeQu[K,V]): Result[K,void]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  ## Similar to `shift()` but with different return value.
  rq.shiftKeyImpl

proc shiftValue*[K,V](rq: var KeeQu[K,V]):
               Result[V,void] {.gcsafe,raises: [Defect,KeyError].} =
  ## Similar to `shift()` but with different return value.
  if 0 < rq.tab.len:
    let val = rq.tab[rq.kFirst].data
    rq.shiftImpl
    return ok(val)
  err()


proc pop*[K,V](rq: var KeeQu[K,V]): Result[KeeQuPair[K,V],void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Deletes the *last* queue item and returns the  key-value item pair just
  ## deleted. For a non-empty queue this function is the same as
  ## `rq.lastKey.value.delele`.
  ##
  ## Using the notation introduced with `rq.append` and `rq.prepend`, the
  ## item returned and deleted is the most *right hand* item.
  if 0 < rq.tab.len:
    let kvp = KeeQuPair[K,V](
      key: rq.kLast,
      data: rq.tab[rq.kLast].data)
    rq.popImpl
    return ok(KeeQuPair[K,V](kvp))
  err()

proc popKey*[K,V](rq: var KeeQu[K,V]): Result[K,void]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  ## Similar to `pop()` but with different return value.
  rq.popKeyImpl

proc popValue*[K,V](rq: var KeeQu[K,V]):
             Result[V,void] {.gcsafe,raises: [Defect,KeyError].} =
  ## Similar to `pop()` but with different return value.
  if 0 < rq.tab.len:
    let val = rq.tab[rq.kLast].data
    rq.popImpl
    return ok(val)
  err()


proc delete*[K,V](rq: var KeeQu[K,V]; key: K):
           Result[KeeQuPair[K,V],void] {.gcsafe,raises: [Defect,KeyError].} =
  ## Delete the item with key `key` from the queue and returns the key-value
  ## item pair just deleted (if any).
  if rq.tab.hasKey(key):
    let kvp = KeeQuPair[K,V](
      key: key,
      data: rq.tab[key].data)
    rq.deleteImpl(key)
    return ok(kvp)
  err()

proc del*[K,V](rq: var KeeQu[K,V]; key: K)
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Similar to `delete()` but without return code.
  if rq.tab.hasKey(key):
    rq.deleteImpl(key)

# --------

proc append*[K](rq: var KeeQuNV[K]; key: K): bool
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  ## Key-only queue variant
  rq.append(key,BlindValue(0))

template push*[K](rq: var KeeQuNV[K]; key: K): bool =
  ## Key-only queue variant
  rq.append(key)


proc prepend*[K,V](rq: var KeeQu[K,V]; key: K): bool
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  ## Key-only queue variant
  rq.prepend(key,BlindValue(0))

template unshift*[K](rq: var KeeQuNV[K]; key: K): bool =
  ## Key-only queue variant
  rq.prepend(key)


proc shift*[K](rq: var KeeQuNV[K]): Result[K,void]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  ## Key-only queue variant
  rq.shiftKeyImpl

proc shiftKey*[K](rq: var KeeQuNV[K]): Result[K,void]
    {.inline,gcsafe,
      deprecated: "use shift() for key-only queue",
      raises: [Defect,KeyError].} =
  ## Deprecated key-only queue variant (use `shift()`)
  rq.shiftKeyImpl


proc pop*[K](rq: var KeeQuNV[K]): Result[K,void]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  ## Key-only variant of `pop()` (same as `popKey()`)
  rq.popKeyImpl

proc popKey*[K](rq: var KeeQuNV[K]): Result[K,void]
    {.inline,gcsafe,
      deprecated: "use pop() for key-only queue",
      raises: [Defect,KeyError].} =
  ## Deprecated key-only queue variant (use `pop()`)
  rq.popKeyImpl

# ------------------------------------------------------------------------------
# Public functions, fetch
# ------------------------------------------------------------------------------

proc hasKey*[K,V](rq: var KeeQu[K,V]; key: K): bool =
  ## Check whether the argument `key` has been queued, already
  rq.tab.hasKey(key)


proc eq*[K,V](rq: var KeeQu[K,V]; key: K): Result[V,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Retrieve the value data stored with the argument `key` from
  ## the queue if there is any.
  if not rq.tab.hasKey(key):
    return err()
  ok(rq.tab[key].data)

proc `[]`*[K,V](rq: var KeeQu[K,V]; key: K): V
    {.gcsafe,raises: [Defect,KeyError].} =
  ## This function provides a simplified version of the `eq()` function with
  ## table semantics. Note that this finction throws a `KeyError` exception
  ## unless the argument `key` exists in the queue.
  rq.tab[key].data

# ------------------------------------------------------------------------------
# Public functions, LRU mode
# ------------------------------------------------------------------------------

proc lruFetch*[K,V](rq: var KeeQu[K,V]; key: K): Result[V,void]
    {.gcsafe, raises: [Defect,CatchableError].} =
  ## Fetch in *last-recently-used* mode: If the argument `key` exists in the
  ## queue, move the key-value item pair to the right end of the queue and
  ## return the value associated with the key.
  let rc = rq.delete(key)
  if rc.isErr:
    return err()
  # Unlink and re-append item
  rq.appendImpl(key, rc.value.data)
  ok(rc.value.data)

proc lruAppend*[K,V](rq: var KeeQu[K,V]; key: K; val: V; maxItems: int): V
    {.gcsafe, raises: [Defect,CatchableError].} =
  ## Append in *last-recently-used* mode: If the queue has at least `maxItems`
  ## item entries, do `shift()` out the left most one. Then append the key-value
  ## argument pair `(key,val)` to the right end. Together with `lruFetch()` this
  ## function can be used to build a *LRU cache*:
  ## ::
  ##   const queueMax = 10
  ##
  ##   proc expensiveCalculation(key: int): Result[int,void] =
  ##     ...
  ##
  ##   proc lruCache(q: var KeeQu[int,int]; key: int): Result[int,void] =
  ##     block:
  ##       let rc = q.lruFetch(key)
  ##       if rc.isOK:
  ##          return ok(rc.value)
  ##     block:
  ##       let rc = expensiveCalculation(key)
  ##       if rc.isOK:
  ##          return ok(q.lruAppend(key, rc.value, queueMax))
  ##     err()
  ##
  # Limit number of cached items
  if maxItems <= rq.tab.len:
    rq.shiftImpl
  # Append new value
  rq.appendImpl(key, val)
  val

# ------------------------------------------------------------------------------
# Public traversal functions, fetch keys
# ------------------------------------------------------------------------------

proc firstKey*[K,V](rq: var KeeQu[K,V]): Result[K,void] {.inline,gcsafe.} =
  ## Retrieve first key from the queue unless it is empty.
  ##
  ## Using the notation introduced with `rq.append` and `rq.prepend`, the
  ## key returned is the most *left hand* one.
  rq.firstKeyImpl

proc secondKey*[K,V](rq: var KeeQu[K,V]): Result[K,void]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  ## Retrieve the key next after the first key from queue unless it is empty.
  ##
  ## Using the notation introduced with `rq.append` and `rq.prepend`, the
  ## key returned is the one ti the right of the most *left hand* one.
  rq.secondKeyImpl

proc beforeLastKey*[K,V](rq: var KeeQu[K,V]): Result[K,void]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  ## Retrieve the key just before the last one from queue unless it is empty.
  ##
  ## Using the notation introduced with `rq.append` and `rq.prepend`, the
  ## key returned is the one to the left of the most *right hand* one.
  rq.beforeLastKeyImpl

proc lastKey*[K,V](rq: var KeeQu[K,V]): Result[K,void] {.inline,gcsafe.} =
  ## Retrieve last key from queue unless it is empty.
  ##
  ## Using the notation introduced with `rq.append` and `rq.prepend`, the
  ## key returned is the most *right hand* one.
  rq.lastKeyImpl

proc nextKey*[K,V](rq: var KeeQu[K,V]; key: K): Result[K,void]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  ## Retrieve the key following the argument `key` from queue if
  ## there is any.
  ##
  ## Using the notation introduced with `rq.append` and `rq.prepend`, the
  ## key returned is the next one to the *right*.
  rq.nextKeyImpl(key)

proc prevKey*[K,V](rq: var KeeQu[K,V]; key: K): Result[K,void]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  ## Retrieve the key preceeding the argument `key` from queue if
  ## there is any.
  ##
  ## Using the notation introduced with `rq.append` and `rq.prepend`, the
  ## key returned is the next one to the *left*.
  rq.prevKeyImpl(key)

# ----------

proc firstKey*[K](rq: var KeeQuNV[K]): Result[K,void]
  {.inline,gcsafe,
    deprecated: "use first() for key-only queue".} =
  ## Deprecated key-only queue variant (use `first()`)
  rq.firstKeyImpl

proc secondKey*[K](rq: var KeeQuNV[K]): Result[K,void]
  {.inline,gcsafe,
    deprecated: "use second() for key-only queue",
    raises: [Defect,KeyError].} =
  ## Deprecated key-only queue variant (use `second()`)
  rq.secondKeyImpl

proc beforeLastKey*[K](rq: var KeeQuNV[K]): Result[K,void]
  {.inline,gcsafe,
    deprecated: "use beforeLast() for key-only queue",
    raises: [Defect,KeyError].} =
  ## Deprecated key-only queue variant (use `beforeLast()`)
  rq.beforeLastKeyImpl

proc lastKey*[K](rq: var KeeQuNV[K]): Result[K,void]
  {.inline,gcsafe,
    deprecated: "use last() for key-only queue".} =
  ## Deprecated key-only queue variant (use `last()`)
  rq.lastKeyImpl

proc nextKey*[K](rq: var KeeQuNV[K]; key: K): Result[K,void]
  {.inline,gcsafe,
    deprecated: "use next() for key-only queue",
    raises: [Defect,KeyError].} =
  ## Deprecated key-only queue variant (use `next()`)
  rq.nextKeyImpl(key)

proc prevKey*[K](rq: var KeeQuNV[K]; key: K): Result[K,void]
  {.inline,gcsafe,
    deprecated: "use prev() for key-only queue",
    raises: [Defect,KeyError].} =
  ## Deprecated key-only queue variant (use `prev()`)
  rq.nextKeyImpl(key)

# ------------------------------------------------------------------------------
# Public traversal functions, fetch key/value pairs
# ------------------------------------------------------------------------------

proc first*[K,V](rq: var KeeQu[K,V]): Result[KeeQuPair[K,V],void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Similar to `firstKey()` but with key-value item pair return value.
  if rq.tab.len == 0:
    return err()
  let key = rq.kFirst
  ok(KeeQuPair[K,V](key: key, data: rq.tab[key].data))

proc second*[K,V](rq: var KeeQu[K,V]): Result[KeeQuPair[K,V],void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Similar to `secondKey()` but with key-value item pair return value.
  if rq.tab.len < 2:
    return err()
  let key = rq.tab[rq.kFirst].kNxt
  ok(KeeQuPair[K,V](key: key, data: rq.tab[key].data))

proc beforeLast*[K,V](rq: var KeeQu[K,V]): Result[KeeQuPair[K,V],void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Similar to `beforeLastKey()` but with key-value item pair return value.
  if rq.tab.len < 2:
    return err()
  let key = rq.tab[rq.kLast].kPrv
  ok(KeeQuPair[K,V](key: key, data: rq.tab[key].data))

proc last*[K,V](rq: var KeeQu[K,V]): Result[KeeQuPair[K,V],void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Similar to `lastKey()` but with key-value item pair return value.
  if rq.tab.len == 0:
    return err()
  let key = rq.kLast
  ok(KeeQuPair[K,V](key: key, data: rq.tab[key].data))

proc next*[K,V](rq: var KeeQu[K,V]; key: K): Result[KeeQuPair[K,V],void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Similar to `nextKey()` but with key-value item pair return value.
  if not rq.tab.hasKey(key) or rq.kLast == key:
    return err()
  let nKey = rq.tab[key].kNxt
  ok(KeeQuPair[K,V](key: nKey, data: rq.tab[nKey].data))

proc prev*[K,V](rq: var KeeQu[K,V]; key: K): Result[KeeQuPair[K,V],void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Similar to `prevKey()` but with key-value item pair return value.
  if not rq.tab.hasKey(key) or rq.kFirst == key:
    return err()
  let pKey = rq.tab[key].kPrv
  ok(KeeQuPair[K,V](key: pKey, data: rq.tab[pKey].data))

# ------------

proc first*[K](rq: var KeeQuNV[K]): Result[K,void] {.inline,gcsafe.} =
  ## Key-only queue variant
  rq.firstKeyImpl

proc second*[K](rq: var KeeQuNV[K]): Result[K,void]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  ## Key-only queue variant
  rq.secondKeyImpl

proc beforeLast*[K](rq: var KeeQuNV[K]): Result[K,void]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  ## Key-only queue variant
  rq.beforeLastKeyImpl

proc last*[K](rq: var KeeQuNV[K]): Result[K,void] {.inline,gcsafe.} =
  ## Key-only queue variant
  rq.lastKeyImpl

proc next*[K](rq: var KeeQuNV[K]; key: K): Result[K,void]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  ## Key-only queue variant
  rq.nextKeyImpl(key)

proc prev*[K](rq: var KeeQuNV[K]; key: K): Result[K,void]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  ## Key-only queue variant
  rq.nextKeyImpl(key)

# ------------------------------------------------------------------------------
# Public traversal functions, data container items
# ------------------------------------------------------------------------------

proc firstValue*[K,V](rq: var KeeQu[K,V]): Result[V,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Retrieve first value item from the queue unless it is empty.
  ##
  ## Using the notation introduced with `rq.append` and `rq.prepend`, the
  ## value item returned is the most *left hand* one.
  if rq.tab.len == 0:
    return err()
  ok(rq.tab[rq.kFirst].data)

proc secondValue*[K,V](rq: var KeeQu[K,V]): Result[V,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Retrieve the value item next to the first one from the queue unless it
  ## is empty.
  ##
  ## Using the notation introduced with `rq.append` and `rq.prepend`, the
  ## value item returned is the one to the right of the most *left hand* one.
  if rq.tab.len < 2:
    return err()
  ok(rq.tab[rq.tab[rq.kFirst].kNxt].data)

proc beforeLastValue*[K,V](rq: var KeeQu[K,V]): Result[V,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Retrieve the value item just before the last item from the queue
  ## unless it is empty.
  ##
  ## Using the notation introduced with `rq.append` and `rq.prepend`, the
  ## value item returned is the one to the left of the most *right hand* one.
  if rq.tab.len < 2:
    return err()
  ok(rq.tab[rq.tab[rq.kLast].kPrv].data)

proc lastValue*[K,V](rq: var KeeQu[K,V]): Result[V,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Retrieve the last value item from the queue if there is any.
  ##
  ## Using the notation introduced with `rq.append` and `rq.prepend`, the
  ## value item returned is the most *right hand* one.
  if rq.tab.len == 0:
    return err()
  ok(rq.tab[rq.kLast].data)

# ------------------------------------------------------------------------------
# Public functions, miscellaneous
# ------------------------------------------------------------------------------

proc `==`*[K,V](a, b: var KeeQu[K,V]): bool
    {.gcsafe, raises: [Defect,KeyError].} =
  ## Returns `true` if both argument queues contain the same data. Note that
  ## this is a slow operation as all `(key,data)` pairs will to be compared.
  if a.tab.len == b.tab.len and a.kFirst == b.kFirst and a.kLast == b.kLast:
    for (k,av) in a.tab.pairs:
      if not b.tab.hasKey(k):
        return false
      let bv = b.tab[k]
      # bv.data might be a reference, so dive into it explicitely.
      if av.kPrv != bv.kPrv or av.kNxt != bv.kNxt or bv.data != av.data:
        return false
    return true

proc key*[K,V](kqp: KeeQuPair[K,V]): K {.inline.} =
  ## Getter
  kqp.key

proc len*[K,V](rq: var KeeQu[K,V]): int {.inline.} =
  ## Returns the number of items in the queue
  rq.tab.len

proc clear*[K,V](rq: var KeeQu[K,V]) {.inline.} =
  ## Clear the queue
  rq.tab.clear
  rq.kFirst.reset
  rq.kLast.reset

proc toKeeQuResult*[K,V](key: K; data: V): Result[KeeQuPair[K,V],void] =
  ## Helper, chreate `ok()` result
  ok(KeeQuPair[K,V](key: key, data: data))

# ------------------------------------------------------------------------------
# Public iterators
# ------------------------------------------------------------------------------

iterator nextKeys*[K,V](rq: var KeeQu[K,V]): K
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Iterate over all keys in the queue starting with the `rq.firstKey.value`
  ## key (if any). Using the notation introduced with `rq.append` and
  ## `rq.prepend`, the iterator processes *left* to *right*.
  ##
  ## :Note:
  ##    When running in a loop it is *ok* to delete the current item and all
  ##    the items already visited. Items not visited yet must not be deleted
  ##    as the loop would be come unpredictable, then.
  if 0 < rq.tab.len:
    var
      key = rq.kFirst
      loopOK = true
    while loopOK:
      let yKey = key
      loopOK = key != rq.kLast
      key = rq.tab[key].kNxt
      yield yKey

iterator nextValues*[K,V](rq: var KeeQu[K,V]): V
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Iterate over all values in the queue starting with the
  ## `rq.kFirst.value.value` item value (if any). Using the notation introduced
  ## with `rq.append` and `rq.prepend`, the iterator processes *left* to
  ## *right*.
  ##
  ## See the note at the `nextKeys()` function comment about deleting items.
  if 0 < rq.tab.len:
    var
      key = rq.kFirst
      loopOK = true
    while loopOK:
      let item = rq.tab[key]
      loopOK = key != rq.kLast
      key = item.kNxt
      yield item.data

iterator nextPairs*[K,V](rq: var KeeQu[K,V]): KeeQuPair[K,V]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Iterate over all (key,value) pairs in the queue starting with the
  ## `(rq.firstKey.value,rq.first.value.value)` key/item pair (if any). Using
  ## the notation introduced with `rq.append` and `rq.prepend`, the iterator
  ## processes *left* to *right*.
  ##
  ## See the note at the `nextKeys()` function comment about deleting items.
  if 0 < rq.tab.len:
    var
      key = rq.kFirst
      loopOK = true
    while loopOK:
      let
        yKey = key
        item = rq.tab[key]
      loopOK = key != rq.kLast
      key = item.kNxt
      yield KeeQuPair[K,V](key: yKey, data: item.data)

iterator prevKeys*[K,V](rq: var KeeQu[K,V]): K
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Reverse iterate over all keys in the queue starting with the
  ## `rq.lastKey.value` key (if any). Using the notation introduced with
  ## `rq.append` and `rq.prepend`, the iterator processes *right* to *left*.
  ##
  ## See the note at the `nextKeys()` function comment about deleting items.
  if 0 < rq.tab.len:
    var
      key = rq.kLast
      loopOK = true
    while loopOK:
      let yKey = key
      loopOK = key != rq.kFirst
      key = rq.tab[key].kPrv
      yield yKey

iterator prevValues*[K,V](rq: var KeeQu[K,V]): V
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Reverse iterate over all values in the queue starting with the
  ## `rq.kLast.value.value` item value (if any). Using the notation introduced
  ## with `rq.append` and `rq.prepend`, the iterator processes *right* to
  ## *left*.
  ##
  ## See the note at the `nextKeys()` function comment about deleting items.
  if 0 < rq.tab.len:
    var
      key = rq.kLast
      loopOK = true
    while loopOK:
      let item = rq.tab[key]
      loopOK = key != rq.kFirst
      key = item.kPrv
      yield item.data

iterator prevPairs*[K,V](rq: var KeeQu[K,V]): KeeQuPair[K,V]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Reverse iterate over all (key,value) pairs in the queue starting with the
  ## `(rq.lastKey.value,rq.last.value.value)` key/item pair (if any). Using
  ## the notation introduced with `rq.append` and `rq.prepend`, the iterator
  ## processes *right* to *left*.
  ##
  ## See the note at the `nextKeys()` function comment about deleting items.
  if 0 < rq.tab.len:
    var
      key = rq.kLast
      loopOK = true
    while loopOK:
      let
        yKey = key
        item = rq.tab[key]
      loopOK = key != rq.kFirst
      key = item.kPrv
      yield KeeQuPair[K,V](key: yKey, data: item.data)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
