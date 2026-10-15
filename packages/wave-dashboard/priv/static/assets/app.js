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

  // A navigation renders its new page outside the patch hooks (into a detached
  // element swapped in later), so the transition spans the whole navigation:
  // it holds the old page from loading start and animates once loading stops.
  // Live updates such as polls and the minute tick do not start a navigation.
  const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
  let finishNavigation = null;

  window.addEventListener("phx:page-loading-start", (event) => {
    if (!["redirect", "patch"].includes(event.detail.kind)) return;
    if (!document.startViewTransition || reducedMotion.matches) return;
    finishNavigation?.();
    // Created up front: a quick navigation can stop before the transition asks for its update.
    const loaded = new Promise((resolve) => (finishNavigation = resolve));
    document.startViewTransition(() => loaded);
  });

  window.addEventListener("phx:page-loading-stop", () => {
    finishNavigation?.();
    finishNavigation = null;
  });

  const csrfToken = document.querySelector("meta[name='csrf-token']").content;
  const liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
    params: { _csrf_token: csrfToken },
  });
  liveSocket.connect();
})();
