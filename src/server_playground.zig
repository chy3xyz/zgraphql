//! Playground HTML payloads for the built-in GraphQL IDE.
//! Split out of server.zig to keep that file focused on request handling.


/// Zero-dependency minimal GraphQL playground. Works offline.
pub const simple_playground_html =
    \\<!DOCTYPE html>
    \\<html lang="en">
    \\<head>
    \\  <meta charset="UTF-8">
    \\  <title>zgraphql Playground</title>
    \\  <style>
    \\    * { box-sizing: border-box; margin: 0; padding: 0; }
    \\    body { display: flex; height: 100vh; background: #1e1e1e; color: #d4d4d4; font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace; }
    \\    .pane { flex: 1; display: flex; flex-direction: column; border-right: 1px solid #333; }
    \\    .pane:last-child { border-right: none; }
    \\    h2 { padding: 8px 12px; background: #252526; font-size: 13px; font-weight: 600; border-bottom: 1px solid #333; }
    \\    textarea, pre { flex: 1; padding: 12px; background: #1e1e1e; color: #d4d4d4; border: none; resize: none; outline: none; font-size: 13px; line-height: 1.5; }
    \\    pre { overflow: auto; white-space: pre-wrap; word-break: break-word; }
    \\    button { margin: 8px 12px; padding: 6px 16px; background: #0e639c; color: #fff; border: none; cursor: pointer; font-size: 13px; border-radius: 3px; }
    \\    button:hover { background: #1177bb; }
    \\    .toolbar { display: flex; gap: 8px; padding: 8px 12px; background: #252526; border-bottom: 1px solid #333; }
    \\    .error { color: #f48771; }
    \\    .success { color: #b5cea8; }
    \\    .status { padding: 4px 12px; font-size: 12px; background: #252526; border-top: 1px solid #333; }
    \\  </style>
    \\</head>
    \\<body>
    \\  <div class="pane">
    \\    <h2>Query</h2>
    \\    <textarea id="query" spellcheck="false" placeholder="Enter GraphQL query...">{ hello }</textarea>
    \\    <h2>Variables (JSON)</h2>
    \\    <textarea id="vars" spellcheck="false" placeholder="{}">{}</textarea>
    \\    <div class="toolbar">
    \\      <button onclick="send()">Execute</button>
    \\      <button onclick="introspect()">Introspect</button>
    \\      <button onclick="prettify()">Prettify</button>
    \\    </div>
    \\    <div class="status" id="status">Ready</div>
    \\  </div>
    \\  <div class="pane">
    \\    <h2>Response</h2>
    \\    <pre id="response"></pre>
    \\  </div>
    \\  <script>
    \\    async function send() {
    \\      const q = document.getElementById('query').value;
    \\      const v = document.getElementById('vars').value;
    \\      const statusEl = document.getElementById('status');
    \\      const respEl = document.getElementById('response');
    \\      statusEl.textContent = 'Loading...';
    \\      try {
    \\        const res = await fetch('/graphql', {
    \\          method: 'POST',
    \\          headers: { 'Content-Type': 'application/json' },
    \\          body: JSON.stringify({ query: q, variables: JSON.parse(v || '{}') })
    \\        });
    \\        const data = await res.json();
    \\        respEl.textContent = JSON.stringify(data, null, 2);
    \\        statusEl.textContent = res.ok ? 'OK ' + res.status : 'Error ' + res.status;
    \\        statusEl.className = res.ok ? 'status success' : 'status error';
    \\      } catch (e) {
    \\        respEl.textContent = String(e);
    \\        statusEl.textContent = 'Network Error';
    \\        statusEl.className = 'status error';
    \\      }
    \\    }
    \\    function introspect() {
    \\      document.getElementById('query').value = '{ __schema { queryType { name } mutationType { name } subscriptionType { name } types { name kind fields { name type { name kind } } } } }';
    \\      send();
    \\    }
    \\    function prettify() {
    \\      const q = document.getElementById('query').value;
    \\      document.getElementById('query').value = JSON.stringify({q:q}).slice(5,-1).replace(/\\n/g,'\n').replace(/\\t/g,'  ');
    \\    }
    \\  </script>
    \\</body>
    \\</html>
;

/// GraphiQL playground via CDN. Requires internet access.
pub const graphiql_html =
    \\<!DOCTYPE html>
    \\<html lang="en">
    \\<head>
    \\  <meta charset="UTF-8">
    \\  <title>GraphiQL</title>
    \\  <link rel="stylesheet" crossorigin href="https://unpkg.com/graphiql@3/graphiql.min.css" />
    \\  <style>body{margin:0;height:100vh;}#root{height:100vh;}</style>
    \\</head>
    \\<body>
    \\  <div id="root"></div>
    \\  <script crossorigin src="https://unpkg.com/react@18/umd/react.production.min.js"></script>
    \\  <script crossorigin src="https://unpkg.com/react-dom@18/umd/react-dom.production.min.js"></script>
    \\  <script crossorigin src="https://unpkg.com/graphiql@3/graphiql.min.js"></script>
    \\  <script>
    \\    const fetcher = GraphiQL.createFetcher({ url: '/graphql' });
    \\    ReactDOM.createRoot(document.getElementById('root')).render(
    \\      React.createElement(GraphiQL, { fetcher: fetcher, defaultEditorToolsVisibility: true })
    \\    );
    \\  </script>
    \\</body>
    \\</html>
;
