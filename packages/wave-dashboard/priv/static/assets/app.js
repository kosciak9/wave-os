(() => {
  const toggleTheme = () => {
    const root = document.documentElement;
    const theme = root.dataset.theme === "kanagawa-dragon" ? "kanagawa-lotus" : "kanagawa-dragon";
    root.dataset.theme = theme;
    document.cookie = `theme=${theme}; Max-Age=31536000; Path=/; SameSite=Lax; Secure`;
  };

  document.addEventListener("click", (event) => {
    if (event.target.closest("#theme-toggle")) toggleTheme();
  });

  // Only the patch that completes a navigation animates; live updates such as
  // polls and the minute tick apply at once.
  let navigating = false;
  window.addEventListener("phx:page-loading-start", (event) => {
    navigating = ["redirect", "patch"].includes(event.detail.kind);
  });
  window.addEventListener("phx:page-loading-stop", () => {
    navigating = false;
  });

  const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
  const onDocumentPatch = (start) => {
    const animate = navigating && document.startViewTransition && !reducedMotion.matches;
    navigating = false;
    if (animate) document.startViewTransition(start);
    else start();
  };

  const csrfToken = document.querySelector("meta[name='csrf-token']").content;
  const liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
    params: { _csrf_token: csrfToken },
    dom: { onDocumentPatch },
  });
  liveSocket.connect();
})();
