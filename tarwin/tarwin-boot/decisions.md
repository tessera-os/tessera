# Proposed decisions for the train ledger

* A.1: encode the first block revision as 1. Only revision 1 is parsed; producers in the current train's 52-entry compatibility window must still pass the train check. Memory descriptors are sorted by physical base before handoff; overlapping footprints, arithmetic wraparound and nonzero reserved bytes reject the entire immutable map. No RAM is released while validating it.
* §6.5: select recovery when both slots have exhausted their attempts or protected selection metadata is malformed. A confirmed slot does not consume attempts. Persist the slot switch and decrement together before jumping.
