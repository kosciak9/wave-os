defmodule WaveDashboardWeb.Layouts do
  use WaveDashboardWeb, :html

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en" data-theme={@theme}>
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={get_csrf_token()} />
        <title>Wave</title>
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
end
