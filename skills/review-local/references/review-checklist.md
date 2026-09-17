# Local Review Checklist

Use this as an inspection guide, not a report template. Raise a finding only after checking the relevant code and its consumers.

## Correctness and contracts

- Trace missing, empty, zero, false, and boundary inputs. Check language-specific truthiness and default-value expressions.
- Compare the stated contract with every return path, including errors, cancellation, and partial success.
- When a change adds a precondition, removes a default, or deletes a field or method, inspect unchanged consumers.
- For refactors, compare observable behavior before and after the change. Check code moved into or out of conditionals.
- Check ranges, units, encodings, ordering assumptions, and conversions at boundaries. Do not assume IDs represent recency.

## Concurrency and lifecycle

- Identify the owner and lifetime of each mutable resource. A queue inside one object does not coordinate other processes or instances.
- Check the whole read-modify-write interval. Atomic replacement does not prevent lost updates from stale reads.
- Trace late callbacks after cancellation, disposal, restart, or a newer request. Check whether stale results can replace current state.
- Check lock ordering, bounded waits, ownership, release on errors, and recovery after a process crash. Do not equate file existence with a live lock.
- Trace startup, repeated use, shutdown, and restart. Check overlapping requests, duplicate completion, and cleanup of timers, watchers, jobs, and descriptors.

## Errors, retries, and persistence

- Check whether a failure reaches the caller with useful context rather than disappearing or looking like success.
- Check partial writes, failed renames, malformed saved state, missing files, and permission errors. A permission error is not evidence that data is absent.
- Check whether a retry duplicates effects, amplifies load, or repeats an operation whose first attempt already succeeded.
- Distinguish atomicity, durability, and mutual exclusion. State which property the code needs and which it actually provides.
- Check compatibility with existing saved data and older concurrent writers. Inspect upgrade and recovery paths without executing them.

## Security and isolation

- Trace input validation and authorization through the actual server or execution boundary, not only the UI.
- Check tenant, user, project, and session isolation in queries, caches, paths, and background jobs.
- Inspect shell arguments, path construction, SQL parameters, rendered output, and terminal control characters for injection paths.
- Check logs, errors, and serialized state for secrets or private content. Do not reproduce secret values in findings.
- Distinguish a prompt restriction, a tool allowlist, and an operating-system sandbox. Do not describe one as another.

## Data integrity and queries

- Check whether database constraints enforce invariants that application-level checks can race on.
- Inspect query bounds, pagination, sort stability, indexes, and realistic data volume before claiming a performance defect.
- Check ownership before deleting shared resources. Trace dependent records and asynchronous cleanup.
- Inspect schema changes for compatibility with code versions that can overlap during rollout. Do not assume a migration can safely reverse lost data.
- Use the actual database and ORM semantics. For composite indexes, check column order and the query shape rather than assuming every component column is covered.

## Architecture and clarity

- Compare the implementation with established local patterns before recommending a new abstraction.
- Check whether responsibilities and dependencies belong in the current layer. Identify concrete coupling rather than calling a design "unclean."
- Check that names describe behavior, especially methods with side effects or more than one outcome.
- Prefer a focused correction over a speculative framework, broad rewrite, or unrelated cleanup.
- Raise complexity only when it obscures a contract, duplicates consequential logic, or makes a demonstrated failure harder to prevent.

## Tests and evidence

- Read test names, setup, actions, and assertions together. Check that the test exercises the claimed behavior.
- Ask whether the test fails if the target behavior breaks. Watch for mocks of the subject itself and assertions on setup data.
- Inspect coverage of the relevant boundary, failure, cancellation, concurrency, and compatibility cases. Do not infer measured coverage from test counts.
- Check isolation of global state, files, environment variables, clocks, and asynchronous work. A test can pass alone but interfere with another test.
- Do not run the tests during this read-only review. Name the targeted checks the user can run and the behaviors they should establish.

## Performance and large repositories

- Distinguish asynchronous I/O from CPU work that still runs on the main or event-loop thread.
- Look for unbounded searches, recursive directory walks, large retained collections, repeated full-file decoding, and excessive redraws.
- Check whether caches include every input that changes the result and whether invalidation matches the resource lifetime.
- Ground latency and memory concerns in actual call frequency and input size. Report unknown scale rather than inventing measurements.
- Keep the review's own searches bounded to the requested paths and evidence-driven consumers.

## Dependencies and public surfaces

- Inspect changes to public APIs, serialized formats, command behavior, configuration, environment variables, and extension hooks.
- Check compatibility with locally declared runtime and platform support. Do not assume a dependency exists because it exists on the reviewer's machine.
- Check new enum values and fields across producers, serializers, and consumers available in the checkout.
- Use local manifests, lockfiles, documentation, and installed source when available. If an upgrade needs unavailable release notes, record that limitation.
- Do not invent external consumers or deployment state. Identify the exact contract that needs an external check.

## Activation and recovery

- Determine when the changed code starts to affect users and which paths or data it can affect.
- Check available activation controls, error reporting, and recovery paths in the local code.
- Distinguish a confirmed unsafe transition from missing rollout information. Missing information usually calls for a question, not a claimed outage.
- Check whether reverting code also restores the previous data and contract. Name irreversible effects when the code demonstrates them.
- Apply rollout concerns in proportion to the target. Do not demand production rollout machinery for an isolated local utility or documentation change.
