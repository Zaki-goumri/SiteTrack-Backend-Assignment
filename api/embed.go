package apidocs

import _ "embed"

//go:embed openapi.yaml
var Spec []byte

const Page = `<!doctype html>
<html>
<head>
  <title>SiteTrack API</title>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
</head>
<body>
  <script id="api-reference" data-url="/openapi.yaml"></script>
  <script src="https://cdn.jsdelivr.net/npm/@scalar/api-reference"></script>
</body>
</html>`
