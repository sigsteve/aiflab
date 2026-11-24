const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');

const name = process.env.EXTENSION_NAME;
const version = process.env.EXTENSION_VERSION;
const prefix = `/plugin/${ name }-${ version }`;
const contentTypes = {
  '.js': 'text/javascript',
  '.json': 'application/json',
  '.tgz': 'application/gzip',
};

if (!name || !version) {
  throw new Error('EXTENSION_NAME and EXTENSION_VERSION are required');
}

http.createServer((request, response) => {
  const url = new URL(request.url, 'http://localhost');

  if (url.pathname === '/healthz') {
    response.end('ok');
    return;
  }

  let file = url.pathname === `${ prefix }.tgz` ?
    `${ name }-${ version }.tgz` :
    url.pathname.startsWith(`${ prefix }/`) ?
      url.pathname.slice(prefix.length + 1) :
      null;

  if (file?.startsWith('plugin/')) {
    file = file.slice('plugin/'.length);
  }

  if (
    request.method !== 'GET' ||
    !file ||
    file.includes('/') ||
    file.includes('..')
  ) {
    response.writeHead(404);
    response.end();
    return;
  }

  fs.readFile(`/assets/${ file }`, (error, body) => {
    if (error) {
      response.writeHead(404);
      response.end();
      return;
    }

    response.writeHead(200, {
      'Content-Type': contentTypes[path.extname(file)] ??
        'application/octet-stream',
      'X-Content-Type-Options': 'nosniff',
    });
    response.end(body);
  });
}).listen(8080, '0.0.0.0');
