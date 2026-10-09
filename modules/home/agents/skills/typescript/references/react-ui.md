# React UI Implementation

Use existing components, tokens, and interaction conventions. Improve the
requested surface without introducing a new design system or a visual redesign
as incidental cleanup.

## Composition and layout

Keep JSX readable: compute meaningful decisions and transformations in the
component body rather than burying complex business logic in markup. Prefer
composed children and focused components to a universal component with unrelated
configuration flags. Context is for genuinely shared subtree state, not a
default replacement for explicit props.

Many configuration props such as `isLink`, `isButton`, or `hasSearchBar` signal
that a component should be split into smaller parts and composed. Pass shared
values down through a provider for the composed subtree.

> ```tsx
> // Configuration: one monolithic component steered by props
> <Composer
>   isThread={true}
>   channelID={'C12345'}
>   disableAttachments={false}
>   renderSubmit={renderThreadSubmitButton}
>   actions={allActions}
> />
>
> // Composition: the variant is built from smaller parts
> <ThreadComposerProvider channelID={'C12345'}>
>   <ComposerFrame>
>     <ComposerInput />
>     <ComposerFooter>
>       <ComposerCommonActions />
>       <ComposerSubmitButton />
>       <AlsoSendToChannel />
>     </ComposerFooter>
>   </ComposerFrame>
> </ThreadComposerProvider>
> ```

Let containers own spacing between their children. Use flex/grid and `gap` where
appropriate rather than components with outside margins that assume a specific
parent. Reuse the spacing scale. Prefer content-driven layouts to fixed heights,
fragile offsets, and arbitrary stacking values.

> A toolbar container can arrange its actions with `gap`; each button should not
> assume it always has a right-hand neighbor. Avoid a single component with
> `isDialog`, `isPage`, and `hasSidebar` controlling unrelated layouts.

## Semantics and interaction

- Use links for navigation, buttons for actions, and real form controls with
  visible labels. Set button types deliberately inside forms.
- Keep keyboard interaction, visible focus, accessible names, and error
  associations intact. Placeholders are not labels; color is not the sole
  signal.
- Reuse established accessible dialog/menu primitives. Check focus entry/return,
  dismissal, keyboard behavior, and overlay clipping rather than assume a portal
  or ARIA role alone makes a custom control accessible.
- Implement meaningful pending, disabled, error, empty, and recovery states.
  Prevent accidental duplicate submissions and preserve input after failure.
- Inspect narrow screens, zoom, long text, realistic data, reduced motion, and
  target browsers. Do not hide content until an animation happens to execute.
- Keep motion purposeful and respect reduced-motion preferences. Measure slow
  interactions before adding memoization or a virtualization dependency.

## Copy and localization

Use the existing translation system for user-facing text, including validation,
empty states, and accessibility labels. Translate complete phrases with named
interpolation and locale-aware plural rules, not fragments or handwritten
suffixes. Use `Intl` or established locale-aware formatters for quantities,
dates, and money with the project's actual locale and timezone policy. Do not
hardcode a new locale or adopt another project's URL vocabulary.

Verify rendered text expansion and boundary quantities. Preserve canonical route
and query contracts, and centralize parsing/building where the feature already
owns them. Never render server secrets or sensitive internal errors as UI copy.
