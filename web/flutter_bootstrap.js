{{flutter_js}}
{{flutter_build_config}}

const rendererParam = new URLSearchParams(window.location.search).get(
  "renderer",
);
const renderer =
  rendererParam === "canvaskit" || rendererParam === "skwasm"
    ? rendererParam
    : null;

const config = renderer ? { renderer } : {};

_flutter.loader.load({ config });
