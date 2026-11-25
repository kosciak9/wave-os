## Previews on wave-os hosts

- Always give a web page's link as its `*.wave.exposed` URL, never `localhost`:
  it is how the owner reaches pages on remote hosts. Serve the page beyond
  loopback and give the URL that
  `wave dashboard add <project> <branch> --port <port>` prints. Running it again
  is harmless.
- For local pages, T3's preview tools and headless browser run on every host.
  Camofox blocks localhost and private addresses except
  `https://*.wave.exposed`.
