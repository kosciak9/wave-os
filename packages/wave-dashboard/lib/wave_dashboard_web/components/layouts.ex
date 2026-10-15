defmodule WaveDashboardWeb.Layouts do
  use WaveDashboardWeb, :html

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={get_csrf_token()} />
        <.live_title default="ahri.wave">{assigns[:page_title]}</.live_title>
        <link rel="icon" type="image/png" href={~p"/images/favicon.png"} />
        <link rel="stylesheet" href={~p"/assets/app.css"} />
        <script defer src="/vendor/phoenix.min.js">
        </script>
        <script defer src="/vendor/phoenix_live_view.min.js">
        </script>
        <script defer src={~p"/assets/app.js"}>
        </script>
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end

  @doc "The Wave mark, the same one Herdr shows; it takes the color of the surrounding text."
  def wave_logo(assigns) do
    ~H"""
    <svg
      class="wave-logo"
      viewBox="0 0 108 108"
      fill="none"
      stroke="currentColor"
      stroke-width="9"
      stroke-linecap="round"
      aria-hidden="true"
    >
      <path d="M12 40 C26 26 40 26 54 40 C68 54 82 54 96 40" />
      <path d="M12 68 C26 54 40 54 54 68 C68 82 82 82 96 68" />
    </svg>
    """
  end

  @doc "Fugate's mark: a dial with a wave through it and one hand, a tide clock for the scheduler."
  def fugate_logo(assigns) do
    ~H"""
    <svg
      class="fugate-logo"
      viewBox="0 0 108 108"
      fill="none"
      stroke="currentColor"
      stroke-width="9"
      stroke-linecap="round"
      aria-hidden="true"
    >
      <circle cx="54" cy="54" r="42" />
      <path d="M26 56 C35 45 45 45 54 56 C63 67 73 67 82 56" />
      <path d="M54 52 V27" />
    </svg>
    """
  end
end
