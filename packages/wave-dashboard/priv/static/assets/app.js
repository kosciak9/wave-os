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

  const csrfToken = document.querySelector("meta[name='csrf-token']").content;
  const liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
    params: { _csrf_token: csrfToken },
  });
  liveSocket.connect();
})();
