import crypto from 'crypto';

function under(path, prefix) {
    prefix = prefix.replace(/\/+$/, '') || '/';
    if (prefix === '/') return path.charAt(0) === '/';
    return path === prefix || path.indexOf(prefix + '/') === 0;
}

function host(value) {
    const name = (value || '').toLowerCase().replace(/\.$/, '');
    return name.length <= 253 && name.split('.').every(label =>
        /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(label)) ? name : '';
}

function event(r) {
    const v = r.variables;
    let path = (v.request_uri || '/').split(/[?#]/, 1)[0];
    let ambiguous = false;
    try { path = decodeURIComponent(path); } catch (_) { ambiguous = true; }
    // Nginx normalizes these before routing; never hash an ambiguous secret-bearing spelling.
    ambiguous = ambiguous || !path.startsWith('/') || /\/\/|(?:^|\/)\.{1,2}(?:\/|$)|[%\\?#\x00-\x20\x7f]/.test(path);
    const gate = v.status === '404' && v.uri === '/_swatter_panel_denied.html' && !v.upstream_status;
    const route = gate ? 'panel' : ambiguous ? 'other' :
        under(path, v.swatter_panel_prefix) ? 'panel' :
        under(path, v.swatter_subs_prefix) ? 'subscription' : 'public';
    const sensitive = path.match(/\/(\.env|\.git\/config|wp-login\.php|xmlrpc\.php)$/);
    // Hash redacted routes: subscription IDs and hidden prefixes are never digest inputs.
    const safe = gate ? '/_panel' : ambiguous ? '/_other' : sensitive ? '/' + sensitive[1] :
        route === 'panel' ? '/_panel' : route === 'subscription' ? '/_subscription' : path;
    const method = (v.request || '').match(/^(GET|HEAD|POST|PUT|PATCH|DELETE|OPTIONS|CONNECT) /);
    const status = /^[1-5][0-9][0-9]$/.test(v.status) ? Number(v.status) : 0;
    return JSON.stringify({schema: 'moskit.http.v1', ts: Number(v.msec),
        peer_ip: v.remote_addr, host: host(v.swatter_host), method: method ? method[1] : 'OTHER',
        uri: route === 'public' && !sensitive ? '/_other' : safe,
        status: status, path_hash: crypto.createHash('sha256').update(safe).digest('hex'),
        route_class: route,
        gate_denied: gate});
}

export default {event};
