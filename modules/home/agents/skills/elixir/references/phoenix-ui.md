# Phoenix UI Implementation

## HEEx and composition

Keep business decisions and substantial transformations out of templates. Use
meaningful assigns or focused functions for complex decisions, without creating
redundant stored state merely to simplify markup. Reuse the existing component
library and slots rather than add a universal component controlled by many
unrelated flags.

Let layout containers control spacing between children with appropriate
flex/grid and `gap`. Reuse the project's tokens and responsive conventions.
Avoid fixed heights that clip errors or translations, arbitrary stacking values,
and external component margins that assume one parent layout.

## Semantic interactions

Use real links, buttons, and labeled form controls with explicit button types.
Preserve keyboard operation, visible focus, accessible names, and field/error
associations. Guard protected forms and controls for UX, but enforce permissions
again in the domain operation with the real actor and record/input context.

Represent loading, empty, failed, and completed states deliberately. Preserve
user input on errors and protect commands against duplicate submission. Reuse
existing dialog and menu primitives; verify focus management, dismissal,
stacking, and clipping in a real browser when the interaction depends on client
behavior.

> A visible label remains understandable after a value is entered; a placeholder
> does not replace it. A hidden submit button does not prevent a forged event
> from reaching the server.

Inspect narrow viewports, zoom, long text, realistic data, and reduced-motion
behavior. Essential content must not depend on an animation callback to become
visible. Do not assume server-rendered HTML verification covers browser layout
or JavaScript interactions.

## Localization and URLs

Use the project's translation backend and locale policy for all changed
user-facing text, including errors and accessibility text. Translate complete
phrases, preserve named interpolation, and use the established plural mechanism.
Do not assemble phrases from separately translated fragments or hardcode noun
forms and suffix rules.

Format dates, quantities, and money using existing locale-aware helpers. Check
empty and boundary counts, placeholder preservation, and translation expansion.
Do not mandate a particular language, external catalog service, or catalog
publishing workflow globally.

Preserve canonical public pathnames/query vocabulary and existing URL builders
and parsers. Locale changes do not automatically authorize route migration,
compatibility aliases, or a language selector. Keep internal diagnostic details
and credentials out of rendered messages and URLs.
