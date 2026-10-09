# Stack

Read this only when starting a project or choosing a new dependency or
framework. In an existing project, its installed stack takes precedence; do not
migrate toward this list as an incidental part of a change.

## Framework selection

Choose by rendering needs:

- **Server-rendered or statically generated apps**: TanStack Start or Next.js.
- **Client-side single-page apps**: TanStack Router with Vite.

With a file- or route-tree router such as TanStack Router, treat routing as a
feature (`features/routing/`) so layouts, guards, and route definitions stay
together.

## Core stack

- PostgreSQL 18+ with UUIDv7 primary keys.
- Drizzle ORM.
- tRPC with `@tanstack/react-query` and superjson.
- better-auth.
- Biome for linting and formatting.
- Zod, date-fns, react-hook-form.
- shadcn with Tailwind CSS.
- `@t3-oss/env-nextjs` or `@t3-oss/env-core` for configuration.

## When needed

- vitest for testing; tests are written only when asked.
- resend for email.
- stripe for payments.
- pg-boss for background jobs, keeping them in PostgreSQL.

Start new projects in TypeScript, not JavaScript.
