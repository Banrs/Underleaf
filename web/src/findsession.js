export const MAX_FIND_QUERY = 256;
export const MAX_FIND_MATCHES = 5000;

export function normalizeFindQuery(value) {
  return String(value ?? '').trim().slice(0, MAX_FIND_QUERY).toLowerCase();
}

// One monotonically increasing generation makes every asynchronous search
// result conditional on still being the latest request. clear/cancel uses the
// same path, so closing the bar cannot be undone by an older scan completing.
export class FindSession {
  #generation = 0;

  begin(value) {
    const generation = ++this.#generation;
    return { generation, query: normalizeFindQuery(value) };
  }

  cancel() {
    this.#generation++;
  }

  current(generation) {
    return generation === this.#generation;
  }
}

// Map sorted page matches onto sorted text-item spans in one pass. The same
// match object is intentionally shared with the document-wide result list so
// the active match can be identified by identity while painting.
export function indexMatchesBySpan(pageMatches, spans) {
  const out = new Array(spans.length);
  let first = 0;
  for (let i = 0; i < spans.length; i++) {
    const range = spans[i];
    while (first < pageMatches.length && pageMatches[first].end <= range.start) first++;
    for (let at = first; at < pageMatches.length && pageMatches[at].start < range.end; at++) {
      (out[i] ??= []).push(pageMatches[at]);
    }
  }
  return out;
}
