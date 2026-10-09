# Naming

Introducing a name introduces a concept, and concepts tend to stick. Bad names
hurt communication and understanding and slow development; they are also hard to
unwind once spread, so validate each new name and look for a better alternative
before it settles. Prefer names the codebase already uses: introduce a new
concept only for a good reason.

The examples below are illustrative JavaScript; apply the same reasoning in the
project's language and conventions.

## General rules

### Avoid naming when it is unnecessary

Not everything needs a name. Every name adds something to remember; an anonymous
function or an inline expression is fine when it keeps the code more readable.

### English

Name variables and functions in English.

> ```js
> /* Bad */
> const primerNombre = "Gustavo";
> const amigos = ["Kate", "John"];
>
> /* Good */
> const firstName = "Gustavo";
> const friends = ["Kate", "John"];
> ```

### One naming convention

Find the convention the project uses (`camelCase`, `PascalCase`, `snake_case`,
or another) and follow it consistently.

> ```js
> /* Bad */
> const page_count = 5;
> const shouldUpdate = true;
>
> /* Good */
> const pageCount = 5;
> const shouldUpdate = true;
>
> /* Good as well */
> const page_count = 5;
> const should_update = true;
> ```

### S-I-D

A name must be _short_, _intuitive_, and _descriptive_:

- **Short**: quick to type and therefore to remember.
- **Intuitive**: reads naturally, as close to common speech as possible.
- **Descriptive**: reflects what it does or holds in the most efficient way.

> ```js
> /* Bad */
> const a = 5; // "a" could mean anything
> const isPaginatable = a > 10; // "Paginatable" sounds unnatural
> const shouldPaginatize = a > 10; // made-up verb
>
> /* Good */
> const postCount = 5;
> const hasPagination = postCount > 10;
> const shouldPaginate = postCount > 10; // alternatively
> ```

### No contractions

Contractions only reduce readability. Finding a short, descriptive name may be
hard, but that is no excuse for contracting one.

> ```js
> /* Bad */
> const onItmClk = () => {};
>
> /* Good */
> const onItemClick = () => {};
> ```

### No context duplication

A name should not repeat the context in which it is defined. Remove the context
whenever that does not reduce readability.

> ```js
> class MenuItem {
>   /* Duplicates the context ("MenuItem") */
>   handleMenuItemClick = (event) => { ... }
>
>   /* Reads nicely as `MenuItem.handleClick()` */
>   handleClick = (event) => { ... }
> }
> ```

### Reflect the expected result

Name a value after the result its consumer needs, so it can be used without
negation.

> ```jsx
> /* Bad */
> const isEnabled = itemCount > 3;
> return <Button disabled={!isEnabled} />;
>
> /* Good */
> const isDisabled = itemCount <= 3;
> return <Button disabled={isDisabled} />;
> ```

### Singular and plural

Use a singular name for a single value and a plural name for a collection.

> ```js
> /* Bad */
> const friends = "Bob";
> const friend = ["Bob", "Tony", "Tanya"];
>
> /* Good */
> const friend = "Bob";
> const friends = ["Bob", "Tony", "Tanya"];
> ```

## Naming functions: A/HC/LC

A useful pattern for function names:

```text
prefix? + action (A) + high context (HC) + low context? (LC)
```

| Name                   | Prefix   | Action (A) | High context (HC) | Low context (LC) |
| ---------------------- | -------- | ---------- | ----------------- | ---------------- |
| `getUser`              |          | `get`      | `User`            |                  |
| `getUserMessages`      |          | `get`      | `User`            | `Messages`       |
| `handleClickOutside`   |          | `handle`   | `Click`           | `Outside`        |
| `shouldDisplayMessage` | `should` | `Display`  | `Message`         |                  |

The order of context changes the meaning: `shouldUpdateComponent` means _you_
are about to update a component, while `shouldComponentUpdate` means the
_component_ updates itself and you only control _when_. High context emphasizes
the meaning of the name.

## Actions

The verb is the most important part of a function name: it describes what the
function _does_.

### `get`

Accesses data immediately, such as a shorthand getter of internal data. It also
fits asynchronous reads.

> ```js
> function getFruitCount() {
>   return this.fruits.length;
> }
>
> async function getUser(id) {
>   const user = await fetch(`/api/user/${id}`);
>   return user;
> }
> ```

### `set`

Declaratively replaces a value `A` with a value `B`.

> ```js
> let fruits = 0;
>
> function setFruits(nextFruits) {
>   fruits = nextFruits;
> }
>
> setFruits(5);
> console.log(fruits); // 5
> ```

### `reset`

Sets a value back to its initial value or state.

> ```js
> const initialFruits = 5;
> let fruits = initialFruits;
> setFruits(10);
> console.log(fruits); // 10
>
> function resetFruits() {
>   fruits = initialFruits;
> }
>
> resetFruits();
> console.log(fruits); // 5
> ```

### `remove` and `delete`

`remove` takes something _from_ somewhere; the thing itself continues to exist.
Removing one of the selected filters on a search page is `removeFilter`, not
`deleteFilter`, which is also how one would say it naturally.

> ```js
> function removeFilter(filterName, filters) {
>   return filters.filter((name) => name !== filterName);
> }
>
> const selectedFilters = ["price", "availability", "size"];
> removeFilter("price", selectedFilters);
> ```

`delete` erases something from existence. When an editor clicks "Delete post",
the system performs `deletePost`, not `removePost`.

> ```js
> function deletePost(id) {
>   return database.find({ id }).delete();
> }
> ```

When the difference is unclear, look at the opposite actions. `add` needs a
destination; `create` requires none: you add an item _to somewhere_, but you do
not create it to somewhere. Pair `remove` with `add` and `delete` with `create`.

### `compose`

Creates new data from existing data; mostly applies to strings, objects, or
functions. Use `get` for accessing data that already exists.

> ```js
> function composePageUrl(pageName, pageId) {
>   return pageName.toLowerCase() + "-" + pageId;
> }
> ```

### `handle`

Handles an action; commonly names a callback.

> ```js
> function handleLinkClick() {
>   console.log("Clicked a link!");
> }
>
> link.addEventListener("click", handleLinkClick);
> ```

## Context

The context is the domain a function operates on. State the domain, or at least
the expected data type, unless the language makes it obvious.

> ```js
> /* A generic function operating on primitives */
> function filter(list, predicate) {
>   return list.filter(predicate);
> }
>
> /* A function operating specifically on posts */
> function getRecentPosts(posts) {
>   return filter(posts, (post) => post.date === Date.now());
> }
> ```

Language conventions may make the context implicit: in JavaScript, `filter`
conventionally operates on an array, so `filterArray` would be redundant.

## Prefixes

A prefix sharpens the meaning of a value. It is rarely used in function names,
except for predicates such as `should`.

### `is`

A characteristic or state of the current context, usually a boolean.

> ```js
> const color = "blue";
> const isBlue = color === "blue"; // characteristic
> const isPresent = true; // state
> ```

### `has`

Whether the current context possesses a value or state, usually a boolean.

> ```js
> /* Bad */
> const isProductsExist = productsCount > 0;
> const areProductsPresent = productsCount > 0;
>
> /* Good */
> const hasProducts = productsCount > 0;
> ```

### `should`

A positive conditional coupled with an action, usually a boolean.

> ```js
> function shouldUpdateUrl(url, expectedUrl) {
>   return url !== expectedUrl;
> }
> ```

### `min` and `max`

A minimum or maximum value, describing boundaries or limits.

> ```js
> function renderPosts(posts, minPosts, maxPosts) {
>   return posts.slice(0, randomBetween(minPosts, maxPosts));
> }
> ```

### `prev` and `next`

The previous or next state of a value in the current context, describing state
transitions.

> ```js
> async function getPosts() {
>   const prevPosts = this.state.posts;
>
>   const latestPosts = await fetch("...");
>   const nextPosts = concat(prevPosts, latestPosts);
>
>   this.setState({ posts: nextPosts });
> }
> ```
