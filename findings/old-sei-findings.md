# Sei Multiversion Store — Vulnerability Research Reports

## Scope and version

- **Project:** Sei Cosmos / multiversion store
- **Analyzed commit:** `d77358290058144f84bf38c27cff87eed8f37f55`
- **Primary file:** `store/multiversion/store.go`
- **Related files:** `store/multiversion/trackediterator.go`
- **Validation method:** local source review and isolated local reproductions using synthetic keys and values

These findings were researched against the commit above. They were not tested against production infrastructure, public validators, or real user funds.

## Finding 1 — Nil and empty values are conflated during read-set validation

**Location:** `store.go`, `checkReadsetAtIndex`

### Summary

The validation logic relies on `bytes.Equal` to compare the value observed by a speculative transaction with the current value. In Go, `bytes.Equal(nil, []byte{})` returns `true`, although the store semantics are different: `nil` represents an absent/deleted key, while an empty byte slice represents an existing key with an empty value.

Relevant validation pattern:

```go
if latestValue == nil {
	parentVal := s.parentStore.Get([]byte(key))
	if !bytes.Equal(parentVal, value) {
		valid = false
	}
} else if !bytes.Equal(latestValue.Value(), value) {
	valid = false
}
```

The problematic equivalence is:

```go
bytes.Equal(nil, []byte{}) == true
```

### Impact

A transaction that read an absent key may remain valid after an earlier transaction creates that key with an empty value. This can allow stale speculative execution to pass validation and produce an incorrect state transition.

### Safe validation

I reproduced the condition locally with a synthetic read-set entry where the original value was `nil`, followed by a preceding write of `[]byte{}` to the same key. The validator treated the two states as equal.

### Recommended remediation

Compare both existence and value, rather than only byte equality. The validation path should distinguish `nil` from an existing empty value consistently with the underlying store's value-validity rules.

## Finding 2 — Iterator validation can accept a replay that encountered an `ESTIMATE`

**Location:** `store.go`, `validateIterator`; related merge/validation iterator logic

### Summary

The replay validator can treat an `ESTIMATE`/nil-like result as a deletion or skip condition during merge iteration. In some execution orders, the estimated key is therefore not checked by the `expectedKeys` membership test, and validation can complete successfully even though the replay encountered a state that should require invalidation or re-execution.

The relevant replay check is:

```go
for ; mergeIterator.Valid(); mergeIterator.Next() {
	key := mergeIterator.Key()
	if _, ok := expectedKeys[string(key)]; !ok {
		returnChan <- false
		return
	}
	foundKeys++
}
```

If merge logic interprets an `ESTIMATE` as a nil/delete value and skips it before this loop observes it, the dependency is not validated deterministically.

### Impact

A speculative transaction may be considered valid despite depending on an unresolved or changed value. This can undermine optimistic-concurrency validation and cause stale iterator results to be accepted.

### Safe validation

I analyzed the merge-iterator flow locally with synthetic parent-store and multiversion-store entries, including an `ESTIMATE` marker positioned before the normal iterator body. The result demonstrated that the marker can be consumed by merge logic without necessarily reaching the `expectedKeys` membership check.

### Recommended remediation

Represent `ESTIMATE` as an explicit validation state rather than an ambiguous nil/delete value. Propagate it through the merge iterator and fail validation deterministically whenever replay encounters an unresolved dependency.

## Finding 3 — `earlyStopKey` is ambiguous and can cause false-negative validation

**Location:** `trackediterator.go`, `Close`; `store.go`, `validateIterator` around the expected/found-key check

### Summary

`trackedIterator.Close()` records the current iterator key as `earlyStopKey`. After `Next()`, that key may be the first unconsumed key rather than the last key consumed by the transaction. However, `validateIterator` assumes that `earlyStopKey` is already part of `expectedKeys`.

The validator checks whether all expected keys have been found before checking whether the current key is `earlyStopKey`. Consequently, a valid replay can be rejected when the next key is exactly the recorded stop key.

The stop key is recorded here:

```go
func (ti *trackedIterator) Close() error {
	if ti.Iterator.Valid() {
		ti.iterateset.SetEarlyStopKey(ti.Iterator.Key())
	}
	return ti.Iterator.Close()
}
```

The validation order then creates the false negative:

```go
for ; mergeIterator.Valid(); mergeIterator.Next() {
	if len(expectedKeys)-foundKeys == 0 {
		returnChan <- false
		return
	}

	key := mergeIterator.Key()
	if bytes.Equal(key, iterationTracker.earlyStopKey) {
		returnChan <- true
		return
	}
}
```

### Reproduction

Given an original iterator sequence `[keyA, keyB, keyC]`:

```text
Transaction consumes keyA
Next() advances to keyB
Close() records earlyStopKey = keyB
expectedKeys = {keyA}
Replay = [keyA, keyB, keyC]
```

After replaying `keyA`, `foundKeys == len(expectedKeys)`. The current implementation returns `false` before checking that the next key, `keyB`, is the expected stop position.

### Impact

This is a false negative: a legitimate transaction can be invalidated and unnecessarily re-executed. Under repeated contention, this can create avoidable work and reduce throughput.

### Recommended remediation

Model the stop semantics explicitly, for example as `stopAfterKey` versus `stopBeforeKey`. As a minimal correction, evaluate the current key against `earlyStopKey` before treating all expected keys as exhausted. The explicit stop-kind model is safer and less ambiguous.

## Finding 4 — `trackedIterator.Valid()` is not recorded as an observation

**Location:** `trackediterator.go`

### Summary

The wrapper records observations made through methods such as `Key`, `Value`, and `Next`, but does not track the result of `Valid()`. A transaction can therefore make a control-flow decision based on whether a range is empty without that observation being represented in `iterationTracker`.

Example of an untracked observation:

```go
iter := store.Iterator(start, end)
nonEmpty := iter.Valid()
iter.Close()
```

If `Valid()` is not wrapped by `trackedIterator`, the tracker may contain no consumed keys even though the transaction observed whether the range was empty.

### Impact

A change from a non-empty range to an empty range, or vice versa, may be missed during validation. The speculative transaction can then be accepted even though the condition it observed has changed.

### Safe validation

I reproduced this locally with a transaction that calls `Valid()` and immediately closes the iterator without calling `Key()` or `Value()`. The tracker can remain empty even though the transaction observed whether the range contained a key.

### Recommended remediation

Track `Valid()` observations explicitly, while distinguishing a genuinely observed iterator from one that was merely created and closed. The replay validator should compare the observed validity state as part of iterator validation.

## Finding 5 — `ClearIterateset` deletes the read-set map instead of the iterator set

**Location:** `store.go`, `ClearIterateset`

### Summary

The cleanup function named `ClearIterateset` deletes from `txReadSets` instead of `txIterateSets`:

```go
func (s *Store) ClearIterateset(index int) {
	// Current behavior
	s.txReadSets.Delete(index)
}
```

The corresponding cleanup calls make the mismatch visible:

```go
s.ClearReadset(index)
s.ClearIterateset(index)
```

Both calls can therefore target `txReadSets`, leaving `txIterateSets` untouched.

The intended operation appears to be:

```go
s.txIterateSets.Delete(index)
```

### Impact

Iterator tracking state can survive transaction invalidation, while the read set may be cleared redundantly. Stale iterator state can affect later validation and create incorrect or nondeterministic behavior across transaction incarnations.

### Safe validation

I verified the mismatch by tracing the invalidation cleanup flow locally: `ClearReadset(index)` already removes the read set, while `ClearIterateset(index)` removes the same map again instead of clearing iterator state.

### Recommended remediation

Change `ClearIterateset` to delete from `txIterateSets` and add a regression test that invalidates a transaction, confirms both tracking structures are cleared, and then validates a new transaction incarnation.

## Responsible disclosure statement

The research was performed against a local checkout and synthetic test cases only. No production endpoint, validator, public network, user account, or real asset was targeted. The findings should be privately reported to the maintainers with the affected commit, exact locations, minimal reproductions, and proposed fixes before public disclosure.
