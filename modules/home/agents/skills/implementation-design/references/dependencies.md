# Dependencies

Read this when choosing or adding a library.

## Use what is installed first

A dependency the project already has is known, configured, and maintained by
someone else. Prefer it over a new one, even when another library would fit the
task slightly better. Push existing libraries until working within them becomes
genuinely painful, and a little beyond, before adding another. Check the
documentation for the installed version: the capability is often already there.

Do not add a second library for a job an installed one already does. Two date,
validation, or state libraries in one project double what every reader must
know.

## Selection criteria

When a new library is justified, prefer one that aligns with functional
principles:

1. **Pure functions over methods.** A function that takes input and returns
   output without side effects can be understood from its interface alone; the
   implementation can be ignored.
2. **Immutability over mutation.** Nothing to track as state changes over time.
3. **Tree-shakeable.** Independent pure functions are easy for bundlers to drop
   when unused.
4. **Platform standards first.** When a standard exists or is emerging in the
   language or runtime, prefer it to a library. Standards are stable, well
   documented, and will not be abandoned.

Apply the same questions in every domain, whether styling, state management, or
routing: Is it functional? Immutable? Tree-shakeable? Is there a platform
standard?

> For dates and times in JavaScript, prefer in this order:
>
> 1. **Temporal**, where the runtime supports it: platform-native, no
>    dependency.
> 2. **date-fns**: pure, immutable, tree-shakeable; each function stands alone.
> 3. Avoid **moment** and **dayjs**: method chaining hides state and resists
>    tree shaking.
>
> ```typescript
> // date-fns: a pure function, understandable in isolation
> import { addDays, format } from "date-fns";
> const nextWeek = addDays(new Date(), 7);
> const formatted = format(nextWeek, "yyyy-MM-dd");
>
> // Temporal: platform-native, no dependency
> const nextWeekDate = Temporal.Now.plainDateISO().add({ days: 7 });
> const formattedDate = nextWeekDate.toString();
> ```

## Size of the dependency

A little copying is better than a little dependency. Do not import a large
library for one small utility; its unfamiliar internals become debugging cost
when something goes wrong.
