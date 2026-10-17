const { ipcRenderer } = require("electron");

if (
  location.protocol === "t3code:" &&
  location.hostname === "app" &&
  window.top === window
) {
  const theme = ipcRenderer.sendSync("wave-os:t3code-theme");
  if (theme) {
    const libraryKey = "t3code:themes:v1";
    const library = JSON.parse(localStorage.getItem(libraryKey) || "[]");
    if (!Array.isArray(library))
      throw new Error("T3 Code's custom theme library is not an array");
    localStorage.setItem(
      libraryKey,
      JSON.stringify([
        ...library.filter((entry) => entry?.id !== theme.id),
        {
          id: theme.id,
          label: theme.name,
          appearance: theme.appearance,
          colors: theme.colors,
        },
      ]),
    );
    localStorage.setItem("t3code:theme", theme.id);
    localStorage.setItem("t3code:theme-appearance-mode", theme.appearance);
    localStorage.removeItem("t3code:theme-halves:v1");
  }
}
