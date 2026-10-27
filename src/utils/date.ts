// Shared date formatting helpers for meal request windows

/**
 * The canonical product timezone. NYU campus time is what every request time
 * means, on every surface, regardless of where the reader's device happens to
 * be. It is an IANA identifier rather than a fixed offset so conversion stays
 * DST-correct on its own.
 *
 * This module is the one place the identifier is written on the backend;
 * `src/requestTiming.ts` re-exports it for the timing contract, and the iOS
 * side carries the matching constant in `NYUCampusTime`.
 */
export const NYU_TIME_ZONE = 'America/New_York';

/**
 * The UTC offset (in ms, negative for zones behind UTC) that `timeZone` was
 * observing at `instant`. DST-aware because it reads the actual wall-clock
 * rendering of `instant` in that zone rather than a fixed offset table.
 */
function timeZoneOffsetMs(instant: Date, timeZone: string): number {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone,
    hourCycle: 'h23',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
  }).formatToParts(instant);
  const get = (type: string) => Number(parts.find((p) => p.type === type)?.value);
  const asUtc = Date.UTC(
    get('year'),
    get('month') - 1,
    get('day'),
    get('hour'),
    get('minute'),
    get('second')
  );
  return asUtc - instant.getTime();
}

/**
 * The instant at which the NYU campus calendar day containing `instant`
 * began — i.e. the most recent local midnight in `America/New_York`.
 *
 * This is the one definition of "start of day" for anything that must reset
 * on the campus calendar (currently the daily request-posting quota in
 * `src/createRequestRoute.ts`). It never reads the host process's local
 * timezone, so the result is identical regardless of where the Node process
 * runs. `America/New_York` switches DST at 2 AM local, not midnight, so
 * every calendar day has an unambiguous midnight instant.
 */
export function startOfCampusDay(instant: Date): Date {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone: NYU_TIME_ZONE,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).formatToParts(instant);
  const get = (type: string) => Number(parts.find((p) => p.type === type)?.value);
  const utcGuess = Date.UTC(get('year'), get('month') - 1, get('day'), 0, 0, 0, 0);
  const offset = timeZoneOffsetMs(new Date(utcGuess), NYU_TIME_ZONE);
  return new Date(utcGuess - offset);
}

/**
 * The instant the NYU campus calendar day containing `instant` ends — the
 * start of the next campus day, i.e. the next local midnight in
 * `America/New_York`. A campus day is 23, 24 or 25 hours long, so the next
 * midnight is found from a point 36 hours into the day (always inside the next
 * day) rather than by adding a fixed 24 hours.
 */
export function endOfCampusDay(instant: Date): Date {
  const start = startOfCampusDay(instant);
  return startOfCampusDay(new Date(start.getTime() + 36 * 60 * 60 * 1000));
}

export function formatMealRequestWindow(start?: string | Date, end?: string | Date, fallback?: string) {
  // If a human-readable fallback was provided (e.g. generated earlier by the app)
  // prefer it when it looks like a formatted window (contains AM/PM or a month name).
  if (fallback && /\b(AM|PM)\b|Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec/i.test(fallback)) {
    return fallback;
  }
  if (!start && !end) return fallback || 'Time window not specified';
  try {
    const s = start ? new Date(start) : null;
    const e = end ? new Date(end) : null;
    const optsDate: Intl.DateTimeFormatOptions = {
      month: 'short',
      day: 'numeric',
      timeZone: NYU_TIME_ZONE,
    };
    const optsTime: Intl.DateTimeFormatOptions = { hour: 'numeric', minute: '2-digit', hour12: true, timeZone: NYU_TIME_ZONE };

    if (s && e) {
      const sameDay = s.toLocaleDateString('en-US', { timeZone: NYU_TIME_ZONE }) === e.toLocaleDateString('en-US', { timeZone: NYU_TIME_ZONE });
      if (sameDay) {
        return `${s.toLocaleDateString('en-US', optsDate)}, ${s.toLocaleTimeString('en-US', optsTime)} – ${e.toLocaleTimeString('en-US', optsTime)}`;
      }
      return `${s.toLocaleString('en-US', { ...optsDate, ...optsTime })} – ${e.toLocaleString('en-US', { ...optsDate, ...optsTime })}`;
    }

    if (s) return `${s.toLocaleDateString('en-US', optsDate)}, ${s.toLocaleTimeString('en-US', optsTime)}`;
    if (e) return `Until ${e.toLocaleString('en-US', { ...optsDate, ...optsTime })}`;
    return fallback || 'Time window not specified';
  } catch {
    // safe fallback: present raw ISO in NY timezone
    if (start) return new Date(start).toLocaleString('en-US', { timeZone: NYU_TIME_ZONE });
    if (end) return new Date(end).toLocaleString('en-US', { timeZone: NYU_TIME_ZONE });
    return fallback || 'Time window not specified';
  }
}
