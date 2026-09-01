// Serialize saves without swallowing a caller-visible failure or poisoning the
// queue. Each run waits for the previous attempt to settle, then gets its own
// resolving or rejecting promise.
export function createSaveQueue() {
  let tail = Promise.resolve();
  return {
    run(task) {
      const current = tail.catch(() => {}).then(task);
      tail = current;
      return current;
    },
  };
}

// Persist snapshots until one completes without another edit arriving. This is
// the primitive destructive transitions use: saving once is insufficient when
// the user can keep typing while the disk write is in flight.
export async function flushUntilStable({ isCurrent, isDirty, save }) {
  if (!isCurrent()) return false;
  // Always queue one save. When another write is already running, even a no-op
  // task waits behind it and turns apparent cleanliness into durable cleanliness.
  await save();
  while (isCurrent() && isDirty()) await save();
  return isCurrent() && !isDirty();
}
