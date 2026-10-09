# Cognitive Load

Cognitive load is how much a developer must hold in mind to complete a task. A
person can keep roughly four chunks in working memory; beyond that threshold,
understanding becomes much harder.

- **Intrinsic** load comes from the inherent difficulty of the problem. It
  cannot be removed.
- **Extraneous** load comes from how the solution is presented. It can be
  reduced, and that is the target.

Code is read far more often than it is written, and every clever trick charges
each later reader a learning penalty. Complexity also creeps in incrementally:
with three conditions, a fourth seems harmless; with thirty, one more still
does. Nothing simplifies a codebase except deliberate choices.

Familiarity is not simplicity. Code that feels obvious to its author can still
be hard for someone new. If a newcomer would be confused for a long stretch,
around forty minutes straight, there is room for improvement. Some complexity is
intrinsic to the problem; weigh the trade-off rather than simplifying blindly.

The examples are illustrative Elixir; the same reasoning applies elsewhere.

## Complex conditionals

Every chained condition occupies working memory. Name the intermediate
decisions.

> ```elixir
> # Must track every condition at once
> if val > limit and (admin? or manager?) and (active? and not banned?) do
>
> # Self-documenting intermediate values
> valid? = val > limit
> authorized? = admin? or manager?
> allowed? = active? and not banned?
> if valid? and authorized? and allowed? do
> ```

## Nested control flow

Deep nesting forces the reader to remember every enclosing precondition. Keep
the happy path flat with the language's own tools: guard clauses and early
returns, or in Elixir multi-clause functions, pattern matching, and `with`.

> ```elixir
> # Must track the nesting context
> def process(data) do
>   if valid?(data) do
>     if authorized?(data) do
>       do_work(data)
>     end
>   end
> end
>
> # Each step reads on its own; failures exit early
> def process(data) do
>   with :ok <- validate(data),
>        :ok <- authorize(data) do
>     do_work(data)
>   end
> end
>
> # Or dispatch on the shape of the input
> def process(%{status: :archived}), do: {:error, :archived}
> def process(%{} = data), do: do_work(data)
> ```

## Magic values

Numeric codes and cryptic strings make the reader look up or remember their
meaning. Use self-describing values or named constants.

> ```elixir
> # Requires a lookup
> %{status: 1}
>
> # Self-documenting
> %{status: :pending_review}
> ```

## Deep modules over many shallow ones

A **deep module** offers a simple interface and hides substantial functionality.
A **shallow module** has an interface that is complex relative to the little it
does. Many small modules can be worse than a few deep ones: the reader must keep
each one's responsibility in mind and also all their interactions, and jumping
between shallow pieces is exhausting. Prefer fewer modules with clear public
interfaces over many tiny, interconnected ones.

## Unnecessary layers

Every layer of indirection costs attention. Add one for a concrete, practical
reason, not for architecture's sake. A layer that passes data through without
transforming it adds load without adding value. If understanding an abstraction
still requires understanding all of its parts, it is not helping.

## Mutable state and side effects

With mutable state, the reader must track how values change over time; each
mutation adds to working memory. Pure functions and immutable data let the
reader treat code as a black box: inputs in, outputs out.
